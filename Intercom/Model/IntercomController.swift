import AVFoundation
import Combine
import Foundation
import os
import UIKit

/// Orchestrates the audio session, the audio engine and the peer-to-peer transport, and exposes
/// everything the UI, the Live Activity and the intents need as published state. Lives on the main
/// actor; one instance per process, created eagerly by `IntercomApp` and registered in `IntercomRuntime`.
///
/// Background behaviour: while the intercom runs, audio I/O never stops (see `AudioEngineController`),
/// which keeps the process alive with the screen locked. In the background the 20 Hz meter timer is
/// paused, a 1 Hz state timer keeps remote-talking, grace periods and the health log going, the
/// transport slows its heartbeats, and link or audio trouble is announced with silent local
/// notifications and audio cues (`SessionStatusMachine` decides when).
@MainActor
final class IntercomController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case starting
        case searching
        case connected
        case failed(String)
    }

    struct PeerInfo: Identifiable, Equatable {
        enum State: Equatable {
            case discovered
            case connecting
            case connected
        }

        let id: PeerID
        var name: String
        var state: State
        var appVersion: String?
        var compatibility: PeerCompatibility = .compatible
        /// Connected, but nothing heard from the peer for a moment; audio may be interrupted.
        var isSuspect = false
        var path: LinkPath = .unknown
        /// Connection attempt since the link was last up (1 for the first).
        var connectAttempt = 0
        /// Kept in the list after discovery loses it: the transport keeps reconnecting to it.
        var hasBeenConnected = false
        /// Why the last link to this peer ended; `nil` once it is up again.
        var lastDisconnectReason: DisconnectReason?
        /// `IntercomProtocol.Network.Capability` bits the peer claimed; 0 for a legacy peer.
        var capabilities: UInt32 = 0

        /// The peer decodes every wire rate, not only the standard 16 kHz.
        var supportsMultiRateAudio: Bool {
            capabilities & IntercomProtocol.Network.Capability.multiRateAudio != 0
        }

        /// The last link was lost without anyone asking for it, so the transport is redialling.
        /// Mirrors what `SessionStatusMachine` treats as an unexpected loss.
        var isAwaitingReconnect: Bool {
            switch lastDisconnectReason {
            case .timeout?, .transportError?:
                return true
            case .remoteBye(let reason)?:
                switch reason {
                case .userDisconnect, .authenticationFailed, .incompatibleVersion: return false
                case .stopped, .duplicate, .replaced, .other: return true
                }
            case .userRequested?, .stopped?, nil:
                return false
            }
        }

        /// The last link was ended with Disconnect, here or on the other phone: only Connect brings it back.
        var isDeliberatelyDisconnected: Bool {
            switch lastDisconnectReason {
            case .userRequested?, .remoteBye(.userDisconnect)?: return true
            default: return false
            }
        }
    }

    /// The "hear yourself" test: a few seconds of the own microphone are recorded exactly as they
    /// are sent, then played back through the local receive path.
    enum TestLoopbackState: Equatable {
        case idle
        /// Recording; `remainingSeconds` counts down from `testRecordingSeconds`.
        case recording(remainingSeconds: Int)
        /// Playing the recording back; `remainingSeconds` counts down to the end of the audio.
        case playing(remainingSeconds: Int)
    }

    /// A latched push-to-talk transmission ends by itself after this long, so a latch set from the
    /// Lock Screen and forgotten cannot leave the microphone open indefinitely.
    static let talkLatchTimeout: TimeInterval = 60
    /// Length of a test recording. Long enough for a sentence, short enough that the peer's audio
    /// (dropped while the recording plays back) is not missed for long.
    static let testRecordingSeconds = 5

    @Published private(set) var phase: Phase = .idle
    /// Overall link state: idle, searching, disconnected, connecting, connected, reconnecting or audio
    /// interrupted.
    @Published private(set) var linkState: SessionLinkStatus = .idle
    /// Name of the peer of the most recent link; survives losing it (the Live Activity shows it).
    @Published private(set) var lastPeerName: String?
    /// Path of the current link, `nil` while no link is up.
    @Published private(set) var linkPath: LinkPath?
    /// Something about the setup the user can fix (permission, pairing code, version, Wi-Fi).
    @Published private(set) var warning: SessionWarning?
    /// iOS notification permission is denied, so background notices never appear whatever the
    /// app's own setting says. Refreshed on every activation (it can change in the Settings app).
    @Published private(set) var notificationPermissionDenied = false
    @Published private(set) var peers: [PeerInfo] = []
    @Published private(set) var isSending = false
    @Published private(set) var isVoiceDetected = false
    /// The in-app talk button is held down (push-to-talk).
    @Published private(set) var isTalkButtonHeld = false
    /// Push-to-talk is latched on (Lock Screen / Live Activity), independent of the button hold.
    @Published private(set) var isTalkLatched = false
    @Published private(set) var remoteTalking = false
    @Published private(set) var remoteMuted = false
    /// The peer's audio is interrupted (phone call, Siri): it can neither hear nor speak right now.
    @Published private(set) var remoteAudioPaused = false
    @Published private(set) var isMuted = false {
        didSet {
            guard oldValue != isMuted else { return }
            pipeline.gate.setMuted(isMuted)
            engine.setSidetoneMuted(isMuted)
            // A change that came from the system (AirPods stem press) must not be echoed back.
            if !isApplyingSystemMute {
                inputMute.setSystemMuted(isMuted)
            }
            if isMuted {
                setTalkLatched(false, reason: "muted")
            }
            sendTalkState()
        }
    }
    @Published private(set) var inputMeter: Float = 0
    @Published private(set) var outputMeter: Float = 0
    @Published private(set) var route: AudioSessionController.Route = .unknown
    @Published private(set) var roundTripMs: Double? {
        didSet { engine.networkRoundTripMs = roundTripMs }
    }
    @Published private(set) var statistics = JitterBuffer.Statistics()
    @Published private(set) var framesSent = 0
    @Published private(set) var inputDescription = ""
    @Published private(set) var lastError: String?
    /// Audio engine health: running, interrupted, recovering or waiting for the foreground.
    @Published private(set) var audioState: AudioEngineController.State = .stopped
    /// Latency diagnostics, refreshed once per second while running.
    @Published private(set) var latency = AudioLatencySnapshot()
    /// The wire rate actually in use: the setting, unless a connected peer cannot decode other
    /// rates, in which case the standard rate until that peer is gone.
    @Published private(set) var effectiveWireRate: WireRate
    /// The user asked for a rate a connected legacy peer cannot take, so the standard rate is used.
    @Published private(set) var isWireRateLimitedByPeer = false
    /// Sample rate of the peer's most recent audio packet, `nil` until one arrived; it may differ
    /// from `effectiveWireRate`, since each side picks its own rate.
    @Published private(set) var incomingSampleRate: Int?
    /// Phase of the "hear yourself" test; `.idle` almost always.
    @Published private(set) var testLoopback: TestLoopbackState = .idle
    /// A test recording is kept in memory and can be played again (`playTestRecording`). Dropped
    /// when the wire rate changes, since it is stored at the rate it was captured at.
    @Published private(set) var hasTestRecording = false

    let settings: AppSettings
    let pipeline: AudioPipeline

    /// The rate the setting asks for; `effectiveWireRate` follows it unless a legacy peer is connected.
    private var wantedWireRate: WireRate

    /// Whether the app is in the foreground (scene active, or inactive on its way back).
    private(set) var isAppActive = true

    private let jitterBuffer: JitterBuffer
    private let audioSession: AudioSessionController
    private let engine: AudioEngineController
    private let inputMute = InputMuteController()
    private let notifier = LocalNotifier()
    private let backgroundActivity = BackgroundActivity.shared
    private var isApplyingSystemMute = false
    private var transport: PeerTransport?
    /// What `transport` was started with; `nil` while there is none.
    private var activeTransportConfiguration: TransportConfiguration?
    private var wifiMonitor: WiFiAvailabilityMonitor?
    private let deviceConditions = DeviceConditionsMonitor()
    private var sessionStatus = SessionStatusMachine()
    private var outputSmoother = LevelSmoother()
    private var remoteTalkFlag = false
    /// The audio session is interrupted; the peer is told so it can explain the silence.
    private var isAudioPaused = false
    private var talkLatchDeadline: MonotonicTime?
    /// The first foreground activation starts the intercom automatically, once per launch.
    private var hasAutoStarted = false
    /// The scene went inactive from the foreground (Control Center, Siri, an alert) and has not been
    /// to the background since, so the engine still believes the app is active.
    private var isCoveredWhileActive = false
    /// Bumped whenever the background give-up check for a recovering engine is rescheduled or moot.
    private var audioBudgetGeneration = 0
    private var stateTicks = 0
    /// Consecutive state ticks with a link in trouble.
    private var troubleTicks = 0
    /// Health lines go to the journal every second for this many seconds of trouble, then every 5 s.
    private static let troubleHealthSeconds = 30
    private static let log = Logger(subsystem: "intercom", category: "controller")
    private static let healthLog = Logger(subsystem: "intercom", category: "health")
    /// The on-device event journal (see `LinkJournal`): the story of every link, readable without a Mac.
    private let linkJournal = LinkJournal.shared
    /// A health line is logged every this many state ticks (seconds).
    private static let healthLogInterval = 5
    private static let audioWindow = "audio.interruption"
    /// How long the audio window stays open when audio goes down, unless a background recovery
    /// stretches it over the background time iOS still grants.
    private static let audioWindowDuration: TimeInterval = 10
    /// Background time left unused when stretching the audio window, so the window ends well before
    /// iOS's own expiration.
    private static let backgroundTimeReserve: TimeInterval = 5
    /// A background recovery gives up this long before the stretched window ends, leaving time for
    /// the "needs foreground" status, notice and Live Activity update to get out.
    private static let backgroundGiveUpLead: TimeInterval = 3
    /// `backgroundTimeRemaining` above this means iOS is not counting (it reports DBL_MAX then).
    private static let uncountedBackgroundTime: TimeInterval = 3_600
    private var settingsObservers = Set<AnyCancellable>()
    private var lifecycleObservers = Set<AnyCancellable>()
    private var meterTimer: AnyCancellable?
    private var stateTimer: AnyCancellable?
    /// The last test recording, at the rate it was captured at; only playable at that rate.
    private var lastTestRecording: (samples: [Int16], rate: WireRate)?
    /// 1 Hz countdown of the test's `remainingSeconds`, in both phases.
    private var testCountdown: AnyCancellable?
    /// Seconds the recording phase has been running, for the countdown and its safety net.
    private var testRecordingTicks = 0
    /// Paces the recording into the jitter buffer while `testLoopback` is `.playing`.
    private var loopbackPlayer: LoopbackPlayer?
    /// Serial queue the loopback pacing timer fires on. Not the main queue: a timer behind UI work
    /// would deliver packets in bursts, which the jitter buffer would read as network jitter.
    private let loopbackQueue = DispatchQueue(label: "intercom.loopback", qos: .userInitiated)
    /// Tail left in the jitter buffer after the last loopback packet, on top of its playout target.
    private static let loopbackDrainMs = 250

    convenience init() {
        self.init(settings: AppSettings())
    }

    init(settings: AppSettings) {
        self.settings = settings
        wantedWireRate = settings.wireRate
        effectiveWireRate = settings.wireRate
        // The jitter configuration already carries the wanted rate; no peer is connected yet.
        let jitter = JitterBuffer(configuration: settings.jitterConfiguration)
        jitterBuffer = jitter
        let session = AudioSessionController()
        audioSession = session
        engine = AudioEngineController(jitterBuffer: jitter, session: session,
                                       configuration: settings.audioEngineConfiguration,
                                       backgroundActivity: BackgroundActivity.shared)
        let gate = TransmitGate(
            mode: settings.transmitMode,
            detector: VoiceActivityDetector(thresholdDB: Float(settings.voxThresholdDB))
        )
        pipeline = AudioPipeline(gate: gate, jitterBuffer: jitter, wireRate: settings.wireRate)
        if settings.playbackEQ != .off {
            // The renderer starts flat; a remembered listening EQ is only pushed when there is one.
            engine.setPlaybackEQ(settings.playbackEQ)
        }
        wireCallbacks()
        observeSettings()
        observeLifecycle()
    }

    // MARK: - Derived state

    var isRunning: Bool {
        switch phase {
        case .searching, .connected:
            return true
        default:
            return false
        }
    }

    var connectedPeers: [PeerInfo] {
        peers.filter { $0.state == .connected }
    }

    var localDisplayName: String {
        DisplayName.sanitized(settings.displayName)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: - Lifecycle

    /// Requests microphone access, activates audio and starts looking for peers. Does nothing while
    /// already running or starting. Only works from the foreground: iOS does not let an app start
    /// recording in the background.
    func start() async {
        switch phase {
        case .idle, .permissionDenied, .failed:
            break
        default:
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            Self.log.notice("start ignored: the app is in the background")
            return
        }

        Self.log.notice("starting intercom")
        linkJournal.record("app", "starting intercom")
        phase = .requestingPermission
        let granted = await MicrophonePermission.request()
        guard granted else {
            Self.log.error("microphone permission denied")
            phase = .permissionDenied
            return
        }

        phase = .starting
        lastError = nil
        do {
            audioSession.startObserving()
            engine.outputVolume = Float(settings.outputVolume)
            engine.sidetoneLevel = Float(settings.sidetoneLevel)
            engine.setSidetoneMuted(isMuted)
            engine.setAppActive(isAppActive)
            pipeline.gate.open()
            applyTalkGate()
            // Activates the session on the engine's queue (activation blocks) and starts audio I/O.
            try await engine.start()
            route = audioSession.currentRoute
            inputDescription = engine.inputDescription
            inputMute.start()
            phase = .searching
            updateSessionStatus(.started(appActive: isAppActive))
            startWiFiMonitor()
            deviceConditions.start()
            startTransport()
            startStateTimer()
            if isAppActive {
                startMeterTimer()
            }
            reconcileInputMute()
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
            if settings.notificationsEnabled, isAppActive {
                notifier.requestAuthorizationIfNeeded { [weak self] in
                    self?.refreshNotificationPermission()
                }
            }
            Self.log.notice("intercom running")
            linkJournal.record("app", "intercom running")
        } catch {
            Self.log.error("intercom start failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
            tearDown()
        }
    }

    /// Stops everything. Idempotent. Ignored while a start is still in progress (the permission prompt
    /// or audio activation is pending); the UI offers Stop only once running.
    func stop() {
        switch phase {
        case .idle:
            return
        case .requestingPermission, .starting:
            Self.log.notice("stop ignored: start still in progress")
            return
        case .permissionDenied, .failed, .searching, .connected:
            break
        }
        Self.log.notice("stopping intercom")
        linkJournal.record("app", "stopping intercom")
        tearDown()
        lastError = nil
        phase = .idle
    }

    /// Manually connects to a discovered peer (auto-connect normally does this).
    func connect(to peer: PeerInfo) {
        Self.log.notice("connect to \(peer.id.rawValue, privacy: .public) requested")
        linkJournal.record("app", "connect to \(peer.id.rawValue) requested")
        transport?.connect(to: peer.id)
    }

    func disconnect() {
        Self.log.notice("disconnect requested")
        linkJournal.record("app", "disconnect requested")
        setTalkLatched(false, reason: "disconnect")
        transport?.disconnectAll()
    }

    // MARK: - Idempotent controls (UI, Live Activity intents)
    //
    // Explicit target values, never toggles: a stale Lock Screen button or a double tap must not
    // invert the state.

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        Self.log.notice("mute \(muted, privacy: .public)")
        isMuted = muted
    }

    func setMode(_ mode: TransmitMode) {
        guard settings.transmitMode != mode else { return }
        Self.log.notice("transmit mode \(mode.rawValue, privacy: .public)")
        // The settings observer releases the hold, clears the latch and updates the gate and the peer.
        settings.transmitMode = mode
    }

    /// Latches push-to-talk on or off. Latching only works while running, in push-to-talk mode, unmuted
    /// and with audio up; it ends by itself after `talkLatchTimeout`, and on mode change, mute,
    /// disconnect, audio interruption and stop. Returns whether the latch now has the requested value.
    @discardableResult
    func setTalkLatched(_ latched: Bool) -> Bool {
        setTalkLatched(latched, reason: "requested")
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func pressTalkButton() {
        guard settings.transmitMode == .pushToTalk, !isTalkButtonHeld else { return }
        isTalkButtonHeld = true
        applyTalkGate()
    }

    func releaseTalkButton() {
        guard isTalkButtonHeld else { return }
        isTalkButtonHeld = false
        applyTalkGate()
    }

    /// Tries to bring paused audio back right away (the status card's "Resume audio"). iOS still says
    /// no while a call or another app holds the audio hardware; the engine then keeps retrying.
    func resumeAudio() {
        guard isRunning else { return }
        Self.log.notice("resume audio requested (audio \(self.audioState.description, privacy: .public))")
        engine.resumeAudio()
    }

    /// Re-reads whether iOS denies notifications (Settings shows a way to fix it).
    func refreshNotificationPermission() {
        Task { [weak self] in
            guard let self else { return }
            let denied = await self.notifier.isAuthorizationDenied()
            if self.notificationPermissionDenied != denied {
                Self.log.notice("notification permission denied: \(denied, privacy: .public)")
                self.notificationPermissionDenied = denied
            }
        }
    }

    /// Plays a notification cue into the intercom's own output (no-op unless audio is running).
    func playCue(_ cue: CueTone) {
        guard isRunning, audioState == .running else { return }
        engine.playCue(cue)
    }

    // MARK: - Test recording ("hear yourself")
    //
    // Records `testRecordingSeconds` of the own microphone as the peer would receive it (after the
    // transmit effect, at the wire rate; the transmit gate does not matter, so the talk button need
    // not be held and transmission goes on as usual), then plays it back through the local jitter
    // buffer, renderer and listening EQ. While it plays, the peer's packets are dropped. Nothing
    // touches disk. The Live Activity, the transmit gate and the peer are not involved.

    /// Starts a test recording; playback follows by itself when it is full. Ignored unless the
    /// intercom runs with audio up and no test is in progress.
    func startTestRecording() {
        guard isRunning, audioState == .running, testLoopback == .idle else {
            Self.log.notice("test recording refused: running \(self.isRunning, privacy: .public), audio \(self.audioState.description, privacy: .public), test \(String(describing: self.testLoopback), privacy: .public)")
            return
        }
        let rate = effectiveWireRate
        pipeline.startTestRecording(capacity: Self.testRecordingSeconds * rate.sampleRate)
        testRecordingTicks = 0
        testLoopback = .recording(remainingSeconds: Self.testRecordingSeconds)
        startTestCountdown()
        Self.log.notice("test recording started: \(Self.testRecordingSeconds, privacy: .public) s at \(rate.sampleRate, privacy: .public) Hz")
    }

    /// Plays the last test recording (again). Ignored unless the intercom runs with audio up, no
    /// test is in progress and there is a recording at the current wire rate.
    func playTestRecording() {
        guard isRunning, audioState == .running, testLoopback == .idle, let recording = lastTestRecording else { return }
        guard recording.rate == effectiveWireRate else {
            // Only reachable if the rate changed since `reconcileWireRate` last looked; the pipeline
            // would drop every packet of the wrong codec anyway.
            Self.log.notice("test recording dropped: captured at \(recording.rate.sampleRate, privacy: .public) Hz, wire rate is \(self.effectiveWireRate.sampleRate, privacy: .public) Hz")
            discardTestRecording()
            return
        }
        let packetizer = LoopbackPacketizer(samples: recording.samples, codec: recording.rate.codec)
        guard packetizer.packetCount > 0 else {
            discardTestRecording()
            return
        }
        let player = LoopbackPlayer(packetizer: packetizer)
        loopbackPlayer = player
        pipeline.beginLoopback()
        testLoopback = .playing(remainingSeconds: Self.seconds(coveringMilliseconds: player.durationMs))
        startTestCountdown()
        let pipeline = self.pipeline
        player.start(on: loopbackQueue, push: { packet in
            pipeline.pushLoopback(packet)
        }, finished: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.loopbackPacketsExhausted(player) }
            }
        })
        Self.log.notice("test recording playing: \(player.packetCount, privacy: .public) packets, \(player.durationMs, privacy: .public) ms at \(recording.rate.sampleRate, privacy: .public) Hz")
    }

    /// Ends whichever phase of the test is running. A recording in progress is discarded; a
    /// playback stops and the peer's audio flows again. The last completed recording is kept.
    func cancelTestLoopback() {
        switch testLoopback {
        case .idle:
            return
        case .recording:
            _ = pipeline.stopTestRecording()
            Self.log.notice("test recording cancelled")
        case .playing:
            stopLoopbackPlayback()
            Self.log.notice("test playback cancelled")
        }
        testCountdown = nil
        testLoopback = .idle
    }

    /// The pipeline's recorder reached its capacity (capture thread, hopped to main).
    private func testRecordingDidFill() {
        guard case .recording = testLoopback else { return }
        finishTestRecording()
    }

    /// Takes the recording out of the pipeline and, unless it is empty, keeps it and plays it.
    /// The rate is the one in effect now: a rate change during the recording cancels the test.
    private func finishTestRecording() {
        let samples = pipeline.stopTestRecording()
        testCountdown = nil
        testLoopback = .idle
        let rate = effectiveWireRate
        guard !samples.isEmpty else {
            Self.log.notice("test recording ended empty: capture delivered nothing")
            return
        }
        lastTestRecording = (samples, rate)
        hasTestRecording = true
        Self.log.notice("test recording done: \(samples.count, privacy: .public) samples (\(samples.count * 1_000 / rate.sampleRate, privacy: .public) ms) at \(rate.sampleRate, privacy: .public) Hz")
        playTestRecording()
    }

    private func discardTestRecording() {
        lastTestRecording = nil
        if hasTestRecording {
            hasTestRecording = false
        }
    }

    private func startTestCountdown() {
        testCountdown = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickTestCountdown() }
    }

    private func tickTestCountdown() {
        switch testLoopback {
        case .recording:
            testRecordingTicks += 1
            let remaining = Self.testRecordingSeconds - testRecordingTicks
            if remaining < 0 {
                // The pipeline reports "full" from the capture thread; a second past the end with
                // no report means capture stopped delivering. Keep what there is.
                Self.log.notice("test recording did not fill in time (\(self.pipeline.snapshot().testRecordedSamples, privacy: .public) samples); finishing with what was captured")
                finishTestRecording()
            } else {
                testLoopback = .recording(remainingSeconds: remaining)
            }
        case .playing:
            guard let player = loopbackPlayer else { return }
            let packetMs = 1_000 / IntercomProtocol.framesPerSecond
            // Never 0 while still playing: the tail drains after the last packet went in.
            let remaining = max(1, Self.seconds(coveringMilliseconds: player.remainingPackets * packetMs))
            if testLoopback != .playing(remainingSeconds: remaining) {
                testLoopback = .playing(remainingSeconds: remaining)
            }
        case .idle:
            testCountdown = nil
        }
    }

    /// The pacer pushed the last packet; the buffer still holds its playout target of audio.
    /// Wait for that plus a margin before handing the buffer back to the peer's stream.
    private func loopbackPacketsExhausted(_ player: LoopbackPlayer) {
        guard loopbackPlayer === player else { return }
        let drainMs = jitterBuffer.statistics.targetDelayMs + Self.loopbackDrainMs
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(drainMs)) { [weak self] in
            MainActor.assumeIsolated { self?.loopbackDidDrain(player) }
        }
    }

    private func loopbackDidDrain(_ player: LoopbackPlayer) {
        guard loopbackPlayer === player else { return }
        stopLoopbackPlayback()
        testCountdown = nil
        testLoopback = .idle
        Self.log.notice("test playback done")
    }

    /// Stops pacing, waits for a tick in flight, then gives the buffer back to the peer's stream,
    /// so no loopback packet lands after the reset.
    private func stopLoopbackPlayback() {
        loopbackPlayer?.cancel()
        loopbackPlayer = nil
        loopbackQueue.sync {}
        pipeline.endLoopback()
    }

    /// Whole seconds that cover `milliseconds` (rounded up).
    private static func seconds(coveringMilliseconds milliseconds: Int) -> Int {
        (max(0, milliseconds) + 999) / 1_000
    }

    // MARK: - Scene phase

    /// The app is active. An interruption that ended while the app was suspended may never have
    /// delivered `.ended`, and a background '!int' failure waits for exactly this moment. The same
    /// goes for an interruption that began while something only covered the app (Siri, Control
    /// Center, an alert): audio that is down is retried at once either way.
    func sceneDidBecomeActive() {
        Self.log.notice("scene phase: active")
        linkJournal.record("app", "scene phase: active")
        let wasCovered = isCoveredWhileActive
        isCoveredWhileActive = false
        enterForeground()
        refreshNotificationPermission()
        if wasCovered, isRunning {
            // Active → inactive → active: the engine never heard that the app left, so
            // `setAppActive(true)` changed nothing there.
            engine.sceneBecameActive()
        }
    }

    /// In the foreground but not active: launching, coming back from the background, or Control
    /// Center, a system alert or the app switcher covers the app. A held button can no longer be
    /// released by the finger; the latch is separate and stays.
    func sceneDidBecomeInactive() {
        Self.log.notice("scene phase: inactive (from \(self.isAppActive ? "foreground" : "background", privacy: .public))")
        linkJournal.record("app", "scene phase: inactive (from \(isAppActive ? "foreground" : "background"))")
        releaseTalkButton()
        if isAppActive {
            isCoveredWhileActive = true
            autoStartIfNeeded()
        } else {
            // Background → inactive only happens on the way back to the foreground. A system alert
            // (a permission prompt, say) can hold the app there; it is visible and may start audio.
            enterForeground()
        }
    }

    /// The app moved to the background: meters pause, the transport slows its heartbeats down, and
    /// audio failures that only the foreground can fix stop being retried.
    func sceneDidEnterBackground() {
        Self.log.notice("scene phase: background")
        linkJournal.record("app", "scene phase: background")
        isCoveredWhileActive = false
        releaseTalkButton()
        engine.setAppActive(false)
        stopMeterTimer()
        guard isAppActive else { return }
        isAppActive = false
        transport?.setAppActive(false)
        updateSessionStatus(.appActiveChanged(false))
        if isRunning, case .recovering = audioState {
            // Audio is down and still being retried: keep the process awake for the retries.
            extendAudioWindowForBackgroundRecovery()
        }
    }

    private func enterForeground() {
        let wasActive = isAppActive
        isAppActive = true
        // No background give-up is due any more.
        audioBudgetGeneration += 1
        // Coming back from the background, this retries audio at once if it is down (the only way out
        // of "needs foreground"), otherwise runs the capture watchdog. After the app was only covered,
        // the engine sees no change here; `sceneDidBecomeActive` retries then.
        engine.setAppActive(true)
        if !wasActive {
            // Fast heartbeats again, a fresh backoff and an immediate discovery kick.
            transport?.setAppActive(true)
            updateSessionStatus(.appActiveChanged(true))
        }
        guard !autoStartIfNeeded(), isRunning else { return }
        startMeterTimer()
        reconcileInputMute()
    }

    /// Starts the intercom the first time the app is in the foreground after launch (active, or inactive
    /// behind a system alert). A launch straight into the background (e.g. by a Live Activity intent)
    /// does not start audio: iOS would refuse to start recording there anyway.
    @discardableResult
    private func autoStartIfNeeded() -> Bool {
        guard !hasAutoStarted else { return false }
        hasAutoStarted = true
        Self.log.notice("first foreground activation: starting automatically")
        Task {
            // `start()` checks the same before its first suspension point, so nothing changes in between.
            guard UIApplication.shared.applicationState != .background else {
                // The scene reached the background before the start ran; try again on the next
                // foreground phase instead of using up this launch's automatic start.
                Self.log.notice("auto-start deferred: the app reached the background first")
                hasAutoStarted = false
                return
            }
            await start()
        }
        return true
    }

    // MARK: - Private: setup

    private func wireCallbacks() {
        let pipeline = self.pipeline
        let audioSession = self.audioSession
        engine.onCapturedFrame = { samples, levelDB in
            pipeline.handleCapturedFrame(samples, levelDB: levelDB)
        }
        // `DispatchQueue.main` keeps restart and state notifications in the order the engine sent them.
        engine.onEngineRestart = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleEngineRestart() }
            }
        }
        engine.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.audioStateDidChange(state) }
            }
        }
        inputMute.onSystemMuteChange = { [weak self] muted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.systemMuteDidChange(muted) }
            }
        }
        pipeline.onSendingChanged = { [weak self] sending in
            Task { @MainActor in self?.sendingDidChange(sending) }
        }
        pipeline.onTestRecordingFull = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.testRecordingDidFill() }
            }
        }
        let engine = self.engine
        audioSession.onRouteChange = { [weak self] route, _ in
            // Straight to the engine: the sidetone must fall silent the moment the headset is
            // unplugged, not after a hop to the main actor.
            engine.updateSidetoneRoute(route)
            LinkJournal.shared.record("audio", "route: output \(route.outputPortType.rawValue), input \(route.inputName.isEmpty ? "none" : "present")")
            Task { @MainActor in self?.route = route }
        }
    }

    private func observeSettings() {
        settings.$transmitMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self else { return }
                self.releaseTalkButton()
                self.setTalkLatched(false, reason: "mode change")
                self.pipeline.gate.setMode(mode)
                // `@Published` emits before the property changes, so pass the new mode along.
                self.sendTalkState(mode: mode)
            }
            .store(in: &settingsObservers)

        settings.$voxThresholdDB
            .dropFirst()
            .sink { [weak self] threshold in
                self?.pipeline.gate.setVoiceThreshold(dB: Float(threshold))
            }
            .store(in: &settingsObservers)

        // `@Published` emits before the property changes, so every sink below builds from the
        // emitted values and never reads `settings.x` for the value that is changing.
        settings.$wireRate
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] rate in
                guard let self else { return }
                self.wantedWireRate = rate
                self.reconcileWireRate(reason: "setting")
            }
            .store(in: &settingsObservers)

        settings.$jitterTargetMs
            .combineLatest(settings.$playoutAuto, settings.$latencyProfile)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] targetMs, adaptive, profile in
                self?.applyJitterConfiguration(targetMs: targetMs, adaptive: adaptive, profile: profile)
            }
            .store(in: &settingsObservers)

        settings.$captureMode
            .combineLatest(settings.$voiceProcessingEnabled, settings.$latencyProfile)
            .combineLatest(settings.$transmitEffect, settings.$transmitEQ, settings.$sidetone)
            .compactMap { [weak self] capture, effect, eq, sidetone -> AudioEngineController.Configuration? in
                guard let self else { return nil }
                let (mode, voiceProcessing, profile) = capture
                // The effective rate, not the setting: a legacy peer may be pinning it.
                return AudioEngineController.Configuration(captureMode: mode,
                                                           voiceProcessing: voiceProcessing,
                                                           wireRate: self.effectiveWireRate,
                                                           ioBufferDuration: profile.ioBufferDuration,
                                                           transmitEffect: effect,
                                                           transmitEQ: eq,
                                                           sidetone: sidetone)
            }
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] configuration in
                // Stored even while stopped; a running engine rebuilds or swaps the effect.
                self?.engine.setConfiguration(configuration)
            }
            .store(in: &settingsObservers)

        settings.$transmitEffect
            .combineLatest(settings.$transmitEQ)
            .dropFirst()
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                // The effect chain adds or removes a few milliseconds of delay; let the receiver
                // re-anchor its delay estimate around the step instead of reading it as jitter.
                self.pipeline.markCaptureDiscontinuity()
            }
            .store(in: &settingsObservers)

        settings.$playbackEQ
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] preset in
                self?.engine.setPlaybackEQ(preset)
            }
            .store(in: &settingsObservers)

        settings.$outputVolume
            .dropFirst()
            .sink { [weak self] volume in
                guard let self, self.isRunning else { return }
                self.engine.outputVolume = Float(volume)
            }
            .store(in: &settingsObservers)

        settings.$sidetoneLevel
            .dropFirst()
            .sink { [weak self] level in
                // Stored by the engine whether running or not; `start()` sets it again anyway.
                self?.engine.sidetoneLevel = Float(level)
            }
            .store(in: &settingsObservers)

        settings.$keepScreenAwake
            .dropFirst()
            .sink { [weak self] keepAwake in
                guard let self, self.isRunning else { return }
                UIApplication.shared.isIdleTimerDisabled = keepAwake
            }
            .store(in: &settingsObservers)

        settings.$notificationsEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                Self.log.notice("notifications \(enabled ? "enabled" : "disabled", privacy: .public)")
                if enabled {
                    if self.isAppActive {
                        self.notifier.requestAuthorizationIfNeeded { [weak self] in
                            self?.refreshNotificationPermission()
                        }
                    }
                } else {
                    self.notifier.removeAll()
                }
            }
            .store(in: &settingsObservers)

        settings.$displayName
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning,
                      self.transportNeedsRestart(for: self.settings.transportKind, change: "display name") else { return }
                Self.log.notice("display name changed: restarting the transport")
                self.restartTransport()
            }
            .store(in: &settingsObservers)

        settings.$transportKind
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] kind in
                // `@Published` emits before the property changes, so the new kind is passed along.
                guard let self, self.isRunning,
                      self.transportNeedsRestart(for: kind, change: "connection engine") else { return }
                Self.log.notice("connection engine changed to \(kind.rawValue, privacy: .public): restarting the transport")
                self.restartTransport(kind: kind)
            }
            .store(in: &settingsObservers)

        settings.$pairingCode
            .dropFirst()
            .map(PairingKey.normalized)
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning,
                      self.transportNeedsRestart(for: self.settings.transportKind, change: "pairing code") else { return }
                Self.log.notice("pairing code changed: restarting the transport")
                self.restartTransport()
            }
            .store(in: &settingsObservers)
    }

    private func observeLifecycle() {
        // Posted on the main thread, and the process exits right after the observers return, so this
        // must run synchronously (no hop).
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationWillTerminate() }
            }
            .store(in: &lifecycleObservers)
        // Session state lives in memory only: whatever a previous process left in Notification Center
        // ("reconnecting", "open Intercom to resume") is stale by definition, including after a
        // force-quit, jetsam kill or crash that never reached `applicationWillTerminate`.
        notifier.removeAll()
    }

    /// Best effort: tell the peer we are gone so it shows "reconnecting" at once instead of waiting
    /// for its liveness timeout, and take down notices that would claim a dead app is still trying.
    /// A force-quit or jetsam kill gets no such chance (the next launch clears the notices).
    private func applicationWillTerminate() {
        Self.log.notice("app will terminate (running \(self.isRunning, privacy: .public))")
        linkJournal.record("app", "app will terminate (running \(isRunning))")
        notifier.removeAll()
        guard isRunning, let transport else { return }
        transport.stop()
        // The goodbye is sent from the transport's queue; give it a moment to reach the network.
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Private: transport

    /// What a transport was started with. Settings change one at a time (the name and the pairing code
    /// are committed together, but debounced separately); the first restart already picks up both, so
    /// a later one that would change nothing is skipped instead of dropping the link again.
    private struct TransportConfiguration: Equatable {
        var kind: TransportKind
        var name: String
        /// Empty for Multipeer, which does not use a pairing code.
        var pairingCode: String
    }

    private func transportConfiguration(kind: TransportKind) -> TransportConfiguration {
        TransportConfiguration(kind: kind, name: localDisplayName,
                               pairingCode: kind == .network ? PairingKey.normalized(settings.pairingCode) : "")
    }

    private func transportNeedsRestart(for kind: TransportKind, change: String) -> Bool {
        guard transportConfiguration(kind: kind) != activeTransportConfiguration else {
            Self.log.notice("\(change, privacy: .public) changed: the transport already uses the current settings, no restart")
            return false
        }
        return true
    }

    private func startTransport(kind: TransportKind? = nil) {
        let kind = kind ?? settings.transportKind
        activeTransportConfiguration = transportConfiguration(kind: kind)
        let name = localDisplayName
        let transport: PeerTransport
        switch kind {
        case .network:
            transport = NetworkTransport(localPeerID: InstallIdentity.peerID(), displayName: name,
                                         appVersion: Self.appVersion, pairingCode: settings.pairingCode)
        case .multipeer:
            transport = MultipeerTransport(installID: InstallIdentity.installID(), displayName: name)
        }
        transport.onEvent = { [weak self, weak transport] event in
            // `DispatchQueue.main` preserves the order of events (connecting → connected → suspect);
            // separate `Task`s are not guaranteed to run in the order they were created.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Ignore events from a transport that has since been replaced.
                    guard let self, let transport, self.transport === transport else { return }
                    self.handleTransportEvent(event)
                }
            }
        }
        let pipeline = self.pipeline
        transport.onAudio = { packet, _ in
            pipeline.receive(packet)
        }
        transport.setAppActive(isAppActive)
        transport.updateLocalStatus(localStatus())
        pipeline.setTransport(transport)
        self.transport = transport
        Self.log.notice("starting \(kind.rawValue, privacy: .public) transport")
        linkJournal.record("app", "starting \(kind.rawValue) transport")
        transport.start()
    }

    private func stopTransport() {
        activeTransportConfiguration = nil
        pipeline.setTransport(nil)
        transport?.onEvent = nil
        transport?.onAudio = nil
        transport?.stop()
        transport = nil
        peers.removeAll()
        // No peer left to limit the rate.
        reconcileWireRate(reason: "transport stopped")
        remoteTalkFlag = false
        remoteTalking = false
        remoteMuted = false
        remoteAudioPaused = false
        roundTripMs = nil
        jitterBuffer.reset()
    }

    private func restartTransport(kind: TransportKind? = nil) {
        // The old transport says goodbye on its queue while the new one starts; keep the app awake for
        // that even if audio happens to be down right now.
        backgroundActivity.begin("transport.restart", maxDuration: 5)
        setTalkLatched(false, reason: "transport restart")
        stopTransport()
        updateSessionStatus(.transportRestarted)
        startTransport(kind: kind)
        if phase == .connected {
            phase = .searching
        }
    }

    private func handleTransportEvent(_ event: TransportEvent) {
        switch event {
        case .peerDiscovered(let advert):
            upsertPeer(advert)
        case .peerLost(let peerID):
            // Peers that were connected stay listed: the transport keeps reconnecting to them.
            if let index = peers.firstIndex(where: { $0.id == peerID }),
               peers[index].state == .discovered, !peers[index].hasBeenConnected {
                peers.remove(at: index)
            }
        case .linkStateChanged(let peerID, let state):
            linkStateChanged(peerID, state)
        case .control(let message, let peerID):
            handleControl(message, from: peerID)
        case .remoteStatus(let status, _):
            remoteTalkFlag = status.isTalking
            if remoteMuted != status.isMuted {
                remoteMuted = status.isMuted
            }
            if remoteAudioPaused != status.isAudioPaused {
                Self.log.notice("peer audio paused: \(status.isAudioPaused, privacy: .public)")
                remoteAudioPaused = status.isAudioPaused
            }
            refreshRemoteTalking(secondsSinceAudio: pipeline.snapshot().secondsSinceRemoteAudio)
        case .roundTrip(_, let ms):
            roundTripMs = ms
        case .warning(let warning):
            updateSessionStatus(.transportWarning(warning))
        case .warningCleared(let warning):
            updateSessionStatus(.transportWarningCleared(warning))
        }
    }

    private func upsertPeer(_ advert: PeerAdvert) {
        if let index = peers.firstIndex(where: { $0.id == advert.id }) {
            peers[index].name = advert.displayName
            peers[index].compatibility = advert.compatibility
            peers[index].capabilities = advert.capabilities
        } else {
            peers.append(PeerInfo(id: advert.id, name: advert.displayName, state: .discovered,
                                  appVersion: nil, compatibility: advert.compatibility,
                                  capabilities: advert.capabilities))
        }
        // The transport re-announces a peer when its handshake reveals its capabilities.
        reconcileWireRate(reason: "peer advertised")
        updateSessionStatus(.peerNamed(advert.id, advert.displayName))
    }

    private func peerIndex(_ peerID: PeerID) -> Int {
        if let index = peers.firstIndex(where: { $0.id == peerID }) {
            return index
        }
        peers.append(PeerInfo(id: peerID, name: DisplayName.fallback, state: .discovered, appVersion: nil))
        return peers.count - 1
    }

    private func linkStateChanged(_ peerID: PeerID, _ state: LinkState) {
        let index = peerIndex(peerID)
        let wasConnected = peers[index].state == .connected
        switch state {
        case .discovered:
            if !wasConnected {
                peers[index].state = .discovered
            }
        case .connecting(let attempt):
            peers[index].state = .connecting
            peers[index].connectAttempt = attempt
            peers[index].isSuspect = false
        case .connected(let path, let isResumption):
            peers[index].state = .connected
            peers[index].isSuspect = false
            peers[index].path = path
            peers[index].hasBeenConnected = true
            peers[index].lastDisconnectReason = nil
            // A stalled link keeps the peer "connected" here, so a restarted peer (a new instance, not a
            // resumption) that takes it over must still be introduced.
            if !wasConnected || !isResumption {
                peerDidConnect(peerID, isResumption: isResumption)
            }
            reconcileWireRate(reason: "peer connected")
        case .suspect, .stalled:
            // A stalled link is kept and replaced or revived by the transport; to the peer list it is
            // a very weak connection. The session status says when it is announced as lost.
            peers[index].isSuspect = true
        case .disconnected(let reason):
            peers[index].state = .discovered
            peers[index].isSuspect = false
            peers[index].lastDisconnectReason = reason
            peerDidDisconnect(peerID, reason: reason, wasConnected: wasConnected)
            reconcileWireRate(reason: "peer disconnected")
        }
        updateSessionStatus(.linkStateChanged(peerID, state))
    }

    /// Picks the wire rate both directions run at: the setting, unless a connected peer cannot
    /// decode anything but the standard rate. Applies a change in a fixed order:
    ///
    /// 1. the pipeline, so its packetizer stamps the new codec and, until the engine has rebuilt,
    ///    drops the frames of the old size the capture worker still delivers;
    /// 2. the jitter buffer, which re-buffers at the new frame size and rate (the inbound adapter
    ///    already converts to it after step 1);
    /// 3. the engine, whose rebuild happens asynchronously on its own queue and is what makes the
    ///    capture worker deliver frames of the new size.
    ///
    /// Doing the engine first would let old-size frames through a packetizer already stamping the
    /// new codec; doing the jitter buffer last would push new-size packets into a buffer of the old size.
    private func reconcileWireRate(reason: String) {
        let legacyPeer = connectedPeers.contains { !$0.supportsMultiRateAudio }
        let effective: WireRate = legacyPeer ? .standard : wantedWireRate
        let limited = legacyPeer && wantedWireRate != .standard
        if isWireRateLimitedByPeer != limited {
            isWireRateLimitedByPeer = limited
        }
        guard effective != effectiveWireRate else { return }
        Self.log.notice("wire rate \(self.effectiveWireRate.sampleRate, privacy: .public) -> \(effective.sampleRate, privacy: .public) Hz (\(reason, privacy: .public), wanted \(self.wantedWireRate.sampleRate, privacy: .public), legacy peer \(legacyPeer, privacy: .public))")
        // A test recording is bound to its rate: one in progress would mix frame sizes, and a kept
        // one can no longer be played.
        cancelTestLoopback()
        if lastTestRecording?.rate != effective {
            discardTestRecording()
        }
        effectiveWireRate = effective
        pipeline.setWireRate(effective)
        jitterBuffer.configuration = AppSettings.jitterConfiguration(targetMs: settings.jitterTargetMs,
                                                                     adaptive: settings.playoutAuto,
                                                                     wireRate: effective,
                                                                     profile: settings.latencyProfile)
        engine.setConfiguration(settings.audioEngineConfiguration(wireRate: effective))
    }

    /// The playout settings changed; the buffer keeps the rate in effect.
    private func applyJitterConfiguration(targetMs: Double, adaptive: Bool, profile: LatencyProfile) {
        jitterBuffer.configuration = AppSettings.jitterConfiguration(targetMs: targetMs, adaptive: adaptive,
                                                                     wireRate: effectiveWireRate,
                                                                     profile: profile)
    }

    private func peerDidConnect(_ peerID: PeerID, isResumption: Bool) {
        phase = .connected
        lastError = nil
        if !isResumption {
            // A new peer instance: its audio clock, delay history and round-trip time are unrelated to
            // anything buffered so far. A resumption (same instance, micro-reconnect) keeps all of it.
            // A test playing through the buffer ends with it rather than fighting the new stream.
            cancelTestLoopback()
            jitterBuffer.reset()
            roundTripMs = nil
            remoteTalkFlag = false
            remoteTalking = false
            remoteMuted = false
            remoteAudioPaused = false
            transport?.sendControl(.hello(.init(displayName: localDisplayName,
                                                appVersion: Self.appVersion,
                                                protocolVersion: IntercomProtocol.version)))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        sendTalkState()
    }

    private func peerDidDisconnect(_ peerID: PeerID, reason: DisconnectReason, wasConnected: Bool) {
        if connectedPeers.isEmpty {
            if isRunning { phase = .searching }
            // The jitter buffer is kept: if the same peer instance comes back within moments, its
            // delay estimate still applies; a different instance resets it on connect.
            remoteTalkFlag = false
            remoteTalking = false
            remoteMuted = false
            remoteAudioPaused = false
            roundTripMs = nil
            if wasConnected {
                // Nobody hears a latched transmission any more; do not resume it on reconnect.
                setTalkLatched(false, reason: "link lost")
            }
        }
        if wasConnected {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func handleControl(_ message: ControlMessage, from peerID: PeerID) {
        switch message {
        case .hello(let hello):
            if let index = peers.firstIndex(where: { $0.id == peerID }) {
                let name = DisplayName.sanitized(hello.displayName)
                peers[index].name = name
                peers[index].appVersion = hello.appVersion
                updateSessionStatus(.peerNamed(peerID, name))
            }
            // The handshake that carried this hello also settled the peer's capabilities.
            reconcileWireRate(reason: "hello")
        case .talkState(let state):
            remoteTalkFlag = state.isTalking
            remoteMuted = state.isMuted
            refreshRemoteTalking(secondsSinceAudio: pipeline.snapshot().secondsSinceRemoteAudio)
        case .ping, .pong:
            // Round-trip time is measured inside the transports now (heartbeat echo / ping frames).
            break
        case .bye:
            remoteTalkFlag = false
            refreshRemoteTalking(secondsSinceAudio: .infinity)
        }
    }

    private func localStatus(mode: TransmitMode? = nil) -> RemoteStatus {
        RemoteStatus(isTalking: isSending, isMuted: isMuted, mode: mode ?? settings.transmitMode,
                     isAudioPaused: isAudioPaused)
    }

    /// Publishes the local talk/mute/mode/paused state. Transports send only actual changes.
    private func sendTalkState(mode: TransmitMode? = nil) {
        transport?.updateLocalStatus(localStatus(mode: mode))
    }

    private func sendingDidChange(_ sending: Bool) {
        // A frame that was already queued when the intercom stopped must not flip the UI back on.
        guard isRunning, sending != isSending else { return }
        isSending = sending
        sendTalkState()
    }

    // MARK: - Private: session status, cues and notifications

    private func updateSessionStatus(_ input: SessionStatusMachine.Input) {
        let effects = sessionStatus.handle(input, now: .now(), date: Date())
        for effect in effects {
            switch effect {
            case .playCue(let cue):
                guard settings.audioCuesEnabled else { break }
                Self.log.notice("cue \(String(describing: cue), privacy: .public)")
                linkJournal.record("state", "cue \(String(describing: cue))")
                playCue(cue)
            case .postNotice(let notice):
                if notice.slot == .audio, audioState == .interrupted || audioState == .needsForeground {
                    // What the interruption window was kept open for is done once this is out. A
                    // background recovery keeps it: its retry timer needs the process awake.
                    backgroundActivity.end(Self.audioWindow, after: 2)
                }
                guard settings.notificationsEnabled else { break }
                notifier.post(notice)
            case .removeNotice(let slot):
                notifier.remove(slot)
            case .log(let message):
                Self.log.notice("\(message, privacy: .public)")
                linkJournal.record("state", message)
            }
        }
        publishSessionStatus()
    }

    private func publishSessionStatus() {
        if linkState != sessionStatus.status {
            Self.log.notice("link state \(self.linkState.description, privacy: .public) -> \(self.sessionStatus.status.description, privacy: .public)")
            linkJournal.record("state", "session \(linkState.description) -> \(sessionStatus.status.description)")
            linkState = sessionStatus.status
        }
        if lastPeerName != sessionStatus.lastPeerName {
            lastPeerName = sessionStatus.lastPeerName
        }
        if linkPath != sessionStatus.linkPath {
            linkPath = sessionStatus.linkPath
        }
        if warning != sessionStatus.warning {
            Self.log.notice("warning: \(self.sessionStatus.warning.map { String(describing: $0) } ?? "none", privacy: .public)")
            linkJournal.record("state", "warning: \(sessionStatus.warning.map { String(describing: $0) } ?? "none")")
            warning = sessionStatus.warning
        }
    }

    private func startWiFiMonitor() {
        wifiMonitor?.stop()
        let monitor = WiFiAvailabilityMonitor()
        monitor.onChange = { [weak self, weak monitor] available in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let monitor, self.wifiMonitor === monitor else { return }
                    self.updateSessionStatus(.wifiAvailabilityChanged(available))
                }
            }
        }
        wifiMonitor = monitor
        monitor.start()
    }

    // MARK: - Private: talk gate

    private func applyTalkGate() {
        pipeline.gate.setButtonHeld(isTalkButtonHeld || isTalkLatched)
    }

    @discardableResult
    private func setTalkLatched(_ latched: Bool, reason: String) -> Bool {
        guard latched else {
            guard isTalkLatched else { return true }
            Self.log.notice("talk latch released: \(reason, privacy: .public)")
            isTalkLatched = false
            talkLatchDeadline = nil
            applyTalkGate()
            return true
        }
        guard isRunning, settings.transmitMode == .pushToTalk, !isMuted, !isAudioPaused else {
            Self.log.notice("talk latch refused: running \(self.isRunning, privacy: .public), mode \(self.settings.transmitMode.rawValue, privacy: .public), muted \(self.isMuted, privacy: .public), audio paused \(self.isAudioPaused, privacy: .public)")
            return false
        }
        // Asking again restarts the safety timeout.
        talkLatchDeadline = .now() + Self.talkLatchTimeout
        guard !isTalkLatched else { return true }
        Self.log.notice("talk latch on (\(reason, privacy: .public))")
        isTalkLatched = true
        applyTalkGate()
        return true
    }

    // MARK: - Private: audio events

    private func handleEngineRestart() {
        guard isRunning else { return }
        // The rebuild paused capture and playback for a moment; a test would have a hole in it.
        cancelTestLoopback()
        route = audioSession.currentRoute
        inputDescription = engine.inputDescription
        // Capture paused while the engine restarted; let the peer re-anchor its delay estimate.
        pipeline.markCaptureDiscontinuity()
        pipeline.gate.open()
        applyTalkGate()
        lastError = nil
        if isAudioPaused {
            isAudioPaused = false
            sendTalkState()
        }
    }

    /// The engine handles interruptions, retries and resets itself; this keeps the transmit side,
    /// the peer, the session status and the background window in step.
    private func audioStateDidChange(_ state: AudioEngineController.State) {
        guard audioState != state else { return }
        let previous = audioState
        Self.log.notice("audio state \(previous.description, privacy: .public) -> \(state.description, privacy: .public) (app active \(self.isAppActive, privacy: .public))")
        linkJournal.record("audio", "audio state \(previous.description) -> \(state.description) (app active \(isAppActive))")
        audioState = state
        if state != .running {
            // No capture to record, no output to play back.
            cancelTestLoopback()
        }
        switch state {
        case .interrupted, .recovering, .needsForeground:
            if isRunning, case .recovering = state, !isAppActive {
                // Every background retry stretches the window over the time iOS still grants; an
                // interruption does not (it waits for `.ended`, however long the call lasts).
                extendAudioWindowForBackgroundRecovery()
            } else if isRunning, previous == .running {
                // Audio I/O stopped, so nothing keeps a backgrounded app awake: make sure the peer
                // hears about it and the notification gets out before suspension.
                backgroundActivity.begin(Self.audioWindow, maxDuration: Self.audioWindowDuration)
            }
            if state == .needsForeground {
                backgroundActivity.end(Self.audioWindow, after: 2)
            }
            if isRunning, !isAudioPaused {
                releaseTalkButton()
                setTalkLatched(false, reason: "audio paused")
                if pipeline.gate.close() {
                    sendingDidChange(false)
                }
                // Capture stopped; let the peer re-anchor its delay estimate when it resumes.
                pipeline.markCaptureDiscontinuity()
                isAudioPaused = true
                sendTalkState()
            }
        case .running, .stopped:
            // Resuming is handled by `handleEngineRestart`, which runs right before `.running`.
            backgroundActivity.end(Self.audioWindow)
        }
        updateSessionStatus(.audioStateChanged(state))
    }

    /// While the engine retries in the background, only the audio window keeps the process, and so
    /// its retry timer, alive. Stretches the window over the background time iOS still grants and,
    /// shortly before that runs out, lets the engine give up with `needsForeground`, which tells the
    /// user to open the app instead of retrying silently in a suspended process.
    private func extendAudioWindowForBackgroundRecovery() {
        audioBudgetGeneration += 1
        // Opens the window if needed first, so the time iOS reports is the budget of a running task.
        backgroundActivity.begin(Self.audioWindow, maxDuration: Self.audioWindowDuration)
        let remaining = UIApplication.shared.backgroundTimeRemaining
        // Not counting yet: the fixed window stands, and the next retry looks again.
        guard remaining < Self.uncountedBackgroundTime else { return }
        let budget = max(0, remaining - Self.backgroundTimeReserve)
        backgroundActivity.begin(Self.audioWindow, maxDuration: budget)
        let generation = audioBudgetGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, budget - Self.backgroundGiveUpLead)) { [weak self] in
            MainActor.assumeIsolated { self?.backgroundRecoveryBudgetDue(generation) }
        }
    }

    private func backgroundRecoveryBudgetDue(_ generation: Int) {
        guard generation == audioBudgetGeneration, isRunning, !isAppActive, case .recovering = audioState else { return }
        Self.log.notice("background time nearly used up (\(String(format: "%.1f", UIApplication.shared.backgroundTimeRemaining), privacy: .public) s left) while audio is \(self.audioState.description, privacy: .public)")
        linkJournal.record("app", "background time nearly used up (\(String(format: "%.1f", UIApplication.shared.backgroundTimeRemaining)) s left) while audio is \(audioState.description)")
        // A no-op if the engine got audio back meanwhile (the state seen here lags its queue).
        engine.backgroundTimeExhausted()
    }

    /// The system input mute changed (AirPods stem press, Control Center): follow it without
    /// echoing it back to the system.
    private func systemMuteDidChange(_ muted: Bool) {
        guard isRunning, muted != isMuted else { return }
        Self.log.notice("following system input mute: \(muted, privacy: .public)")
        isApplyingSystemMute = true
        isMuted = muted
        isApplyingSystemMute = false
    }

    /// The system input mute persists across activations and may have changed while no record session
    /// was active (no notification then), so adopt it when audio (re)starts or the app comes back.
    private func reconcileInputMute() {
        systemMuteDidChange(inputMute.isSystemMuted)
    }

    // MARK: - Private: timers

    /// 20 Hz meters: only while the app is in the foreground (nobody sees them in the background).
    private func startMeterTimer() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickMeters() }
    }

    private func stopMeterTimer() {
        meterTimer = nil
    }

    /// 1 Hz state timer: runs in the background too (remote talking, grace periods, latch timeout,
    /// latency snapshot, health log).
    private func startStateTimer() {
        stateTicks = 0
        stateTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickState() }
    }

    private func tickState() {
        stateTicks += 1
        let snapshot = engine.latency
        if snapshot != latency {
            latency = snapshot
        }
        if meterTimer == nil {
            let pipelineSnapshot = pipeline.snapshot()
            refreshRemoteTalking(secondsSinceAudio: pipelineSnapshot.secondsSinceRemoteAudio)
            publishIncomingSampleRate(pipelineSnapshot.incomingSampleRate)
        }
        if let deadline = talkLatchDeadline, MonotonicTime.now() >= deadline {
            setTalkLatched(false, reason: "timeout after \(Int(Self.talkLatchTimeout)) s")
        }
        updateSessionStatus(.tick)
        if stateTicks % Self.healthLogInterval == 0 {
            logHealth(toSystemLog: true)
        } else if isLinkInTrouble, troubleTicks <= Self.troubleHealthSeconds {
            // One journal line a second while a link is weak or being replaced: that is when the
            // seconds matter. The system log keeps its calmer rhythm.
            logHealth(toSystemLog: false)
        }
        // A peer that stays out of range for hours must not push the story of the ride out of the journal.
        troubleTicks = isLinkInTrouble ? troubleTicks + 1 : 0
    }

    /// A link is weak, stalled or being redialled.
    private var isLinkInTrouble: Bool {
        if peers.contains(where: { $0.isSuspect }) { return true }
        if case .reconnecting = linkState { return true }
        return false
    }

    private func tickMeters() {
        let snapshot = pipeline.snapshot()
        if inputMeter != snapshot.inputMeter {
            inputMeter = snapshot.inputMeter
        }
        let output = outputSmoother.process(AudioLevel.meterValue(dB: engine.outputLevelDB))
        if outputMeter != output {
            outputMeter = output
        }
        if isVoiceDetected != snapshot.isVoiceDetected {
            isVoiceDetected = snapshot.isVoiceDetected
        }
        if framesSent != snapshot.framesSent {
            framesSent = snapshot.framesSent
        }
        let stats = jitterBuffer.statistics
        if stats != statistics {
            statistics = stats
        }
        publishIncomingSampleRate(snapshot.incomingSampleRate)
        refreshRemoteTalking(secondsSinceAudio: snapshot.secondsSinceRemoteAudio)
    }

    private func publishIncomingSampleRate(_ rate: Int?) {
        if incomingSampleRate != rate {
            incomingSampleRate = rate
        }
    }

    private func refreshRemoteTalking(secondsSinceAudio: TimeInterval) {
        if remoteTalkFlag, secondsSinceAudio > 2 {
            // The peer said it was talking but nothing has arrived for a while; trust the audio.
            remoteTalkFlag = false
        }
        let talking = remoteTalkFlag || secondsSinceAudio < 0.4
        if talking != remoteTalking {
            remoteTalking = talking
        }
    }

    /// One line every few seconds that tells the whole story at a glance in the device log.
    private func logHealth(toSystemLog: Bool) {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let stats = jitterBuffer.statistics
        let rtt = roundTripMs.map { String(format: "%.0fms", $0) } ?? "-"
        let path = linkPath?.rawValue ?? "-"
        let peerSummary = peers.map { "\($0.name)=\($0.state)\($0.isSuspect ? "(suspect)" : "")" }.joined(separator: ",")
        let line = "phase=\(phase) link=\(linkState) path=\(path) audio=\(audioState) app=\(appState)"
            + " rtt=\(rtt) mode=\(settings.transmitMode.rawValue) muted=\(isMuted) latched=\(isTalkLatched)"
            + " sending=\(isSending) remoteTalking=\(remoteTalking) remotePaused=\(remoteAudioPaused)"
            + " jitter target=\(stats.targetDelayMs)ms depth=\(stats.depthMs)ms received=\(stats.received)"
            + " underruns=\(stats.underruns) concealed=\(stats.concealed) late=\(stats.lateDropped)"
            + " trimmed=\(stats.trimmed) lockMisses=\(stats.renderLockMisses)"
            + " wire=\(effectiveWireRate.sampleRate) in=\(incomingSampleRate.map(String.init) ?? "-")"
            + " warning=\(warning.map { String(describing: $0) } ?? "none")"
            + " \(DeviceConditionsMonitor.summary())"
        if toSystemLog {
            Self.healthLog.notice("\(line, privacy: .public) peers=[\(peerSummary, privacy: .private)]")
        }
        // The journal stays on the phone and is shared only by the user, so it keeps the peer states too.
        linkJournal.record("health", "\(line) peers=[\(peerSummary)]")
    }

    /// Puts a marker in the link journal, so a drop noticed on the road can be found afterwards.
    func markJournal() {
        linkJournal.record("marker", "user marker (link \(linkState.description), app \(isAppActive ? "active" : "background"))")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Private: teardown

    private func tearDown() {
        stateTimer = nil
        stopMeterTimer()
        cancelTestLoopback()
        wifiMonitor?.stop()
        wifiMonitor = nil
        deviceConditions.stop()
        setTalkLatched(false, reason: "stop")
        stopTransport()
        releaseTalkButton()
        // Stop the engine first: it waits for in-flight capture callbacks, so nothing can reach
        // the gate after it is closed below.
        engine.stop()
        pipeline.gate.close()
        inputMute.stop()
        audioSession.stopObserving()
        audioSession.deactivate()
        pipeline.resetMeters()
        outputSmoother.reset()
        isSending = false
        inputMeter = 0
        outputMeter = 0
        isVoiceDetected = false
        statistics = JitterBuffer.Statistics()
        framesSent = 0
        route = .unknown
        inputDescription = ""
        roundTripMs = nil
        incomingSampleRate = nil
        isAudioPaused = false
        audioState = .stopped
        latency = AudioLatencySnapshot()
        backgroundActivity.end(Self.audioWindow)
        updateSessionStatus(.stopped)
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

/// Feeds one test recording into the local jitter buffer at the cadence a peer's packets arrive
/// at: one every 20 ms from a `DispatchSourceTimer` on the controller's loopback queue, with a
/// tight leeway so the buffer sees a steady stream and not timer jitter. The packetizer is
/// mutated on that queue and its progress read from the main actor, hence the lock. `finished`
/// fires once, on the queue, after the last packet; the timer cancels itself then. Not main-actor
/// isolated: the timer handler runs off the main thread.
private final class LoopbackPlayer: @unchecked Sendable {
    let packetCount: Int
    let durationMs: Int

    private let lock = NSLock()
    /// Guarded by `lock`.
    private var packetizer: LoopbackPacketizer
    /// Guarded by `lock`.
    private var timer: DispatchSourceTimer?

    init(packetizer: LoopbackPacketizer) {
        self.packetizer = packetizer
        packetCount = packetizer.packetCount
        durationMs = packetizer.durationMs
    }

    deinit {
        timer?.cancel()
    }

    var remainingPackets: Int {
        lock.withLock { packetizer.remainingPackets }
    }

    /// Starts pacing on `queue`. `push` runs there for every packet; `finished` once after the last.
    func start(on queue: DispatchQueue, push: @escaping @Sendable (AudioPacket) -> Void,
               finished: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1_000 / IntercomProtocol.framesPerSecond),
                       leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let packet = self.lock.withLock { self.packetizer.next() }
            guard let packet else {
                self.cancel()
                finished()
                return
            }
            push(packet)
        }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    /// Stops pacing; a tick already running on the queue completes. Safe to call more than once.
    func cancel() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let current = self.timer
            self.timer = nil
            return current
        }
        timer?.cancel()
    }
}
