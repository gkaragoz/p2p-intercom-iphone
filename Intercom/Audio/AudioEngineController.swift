import AVFoundation
import Foundation
import os
import Synchronization

enum AudioEngineError: LocalizedError {
    case noInputAvailable
    case converterUnavailable
    /// The input format cannot feed an `AVAudioSinkNode` directly (it does not convert formats).
    case sinkFormatUnsupported

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return String(localized: "No microphone input is available.")
        case .converterUnavailable, .sinkFormatUnsupported:
            return String(localized: "The audio format could not be converted.")
        }
    }
}

/// Runs the `AVAudioEngine` graph and keeps it alive:
///
///     inputNode ──▶ AVAudioSinkNode (real-time: copy into CaptureRing)      ─┐
///     inputNode ──tap──▶ CaptureRing (compatible mode / automatic fallback) ─┴▶ CaptureWorker
///         CaptureWorker (thread, polls 5 ms): AVAudioConverter ──▶ 20 ms Int16 frames ──▶ onCapturedFrame
///     JitterBuffer + cues ──▶ PlaybackRenderer ──▶ AVAudioSourceNode ──▶ mainMixerNode ──▶ outputNode
///
/// Capture: the sink node delivers one hardware I/O buffer per callback on the real-time thread.
/// A tap is not real-time and iOS may hand it 100 ms (or bigger) chunks, which adds that much delay
/// and sends frames in bursts, so the tap is only used in compatible mode, when the sink graph cannot
/// be started, or when the sink stays silent for a second after starting.
///
/// Threads: every graph mutation and all state below happen on `engineQueue`. The render and sink
/// callbacks touch only `PlaybackRenderer`/`CaptureRing` (preallocated memory, atomics, try-lock).
///
/// Recovery is decided by `AudioRecoveryMachine` (Core): interruptions, failed activations with
/// classified error codes and background-aware retry, media services resets, configuration changes
/// and a capture/render watchdog (the engine can claim to run while no callbacks arrive).
/// Interruptions are marked synchronously on the notification thread (`interruptedFlag`) before the
/// hop to `engineQueue`, so a configuration-change or watchdog rebuild already queued can't activate
/// the session mid-interruption, and a generation counter lets a delayed `.began` notice that audio
/// has been recovered since and must not be stopped.
///
/// INVARIANT: while the intercom runs, audio I/O never stops for push-to-talk idle, mute or "no
/// peer". Mute and the gate only decide what is sent; capture and playback keep running. Running
/// audio I/O is what keeps the app alive in the background (the `audio` background mode), and an app
/// in the background is not allowed to start audio again. Only an interruption stops the engine.
final class AudioEngineController: @unchecked Sendable {
    typealias FrameHandler = CaptureWorker.FrameHandler
    typealias State = AudioRecoveryMachine.State

    struct Configuration: Equatable, Sendable {
        var captureMode: CaptureMode = .lowLatency
        var voiceProcessing = true
    }

    let jitterBuffer: JitterBuffer

    /// Called for every captured 20 ms frame, on the capture worker thread.
    var onCapturedFrame: FrameHandler? {
        get { worker.onFrame }
        set { worker.onFrame = newValue }
    }
    /// Called on the engine queue after the graph was rebuilt and restarted (route or configuration
    /// change, recovery); not for the initial start.
    var onEngineRestart: (@Sendable () -> Void)?
    /// Called on the engine queue whenever the audio state changes.
    var onStateChange: (@Sendable (State) -> Void)?

    private let session: AudioSessionController
    /// Wraps recovery attempts so a rebuild that starts while audio is down is not cut short by suspension.
    private let backgroundActivity: BackgroundActivity?
    private let counters = AudioMetricsCounters()
    private let renderer: PlaybackRenderer
    private let worker: CaptureWorker
    private let wireFormat: AVAudioFormat
    private let playbackFormat: AVAudioFormat
    private let engineQueue = DispatchQueue(label: "intercom.audio.engine", qos: .userInitiated)

    // Cross-thread flags.
    private let isAppActive = Atomic<Bool>(true)
    private let interruptedFlag = Atomic<Bool>(false)
    /// Bumped by every interruption `.began` and every successful recovery.
    private let generation = Atomic<Int>(0)

    // engineQueue only.
    private var engine = AVAudioEngine()
    private var machine = AudioRecoveryMachine()
    private var configuration: Configuration
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?
    private var isTapInstalled = false
    private var capturePath: CapturePath = .none
    /// The sink path failed during this run; use the tap until the capture mode changes or the next start.
    private var sinkUnavailable = false
    private var buildCount = 0
    private var inputSampleRate: Double = 0
    private var inputChannels = 0
    private var isVoiceProcessingActive = false
    private var healthTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?
    private var configurationObserver: NSObjectProtocol?
    private var watchdog = Watchdog()
    private var sampler = AudioLatencySampler()
    private var healthTicks = 0

    // Guarded by `lock`: read from other threads.
    private let lock = NSLock()
    private var desiredOutputVolume: Float = 1
    private var latestInputDescription = ""
    private var latestLatency = AudioLatencySnapshot()
    private var latestRoundTripMs: Double?

    private static let log = Logger(subsystem: "intercom", category: "audio")
    private static let latencyLog = Logger(subsystem: "intercom", category: "latency")
    /// A latency line is logged every this many health ticks (seconds).
    private static let latencyLogInterval = 5

    init(jitterBuffer: JitterBuffer, session: AudioSessionController, configuration: Configuration = Configuration(),
         backgroundActivity: BackgroundActivity? = nil) {
        guard let wire = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: IntercomProtocol.sampleRate,
                                       channels: AVAudioChannelCount(IntercomProtocol.channelCount),
                                       interleaved: true),
              let playback = AVAudioFormat(standardFormatWithSampleRate: IntercomProtocol.sampleRate,
                                           channels: AVAudioChannelCount(IntercomProtocol.channelCount)) else {
            fatalError("The intercom wire format is not representable by AVAudioFormat")
        }
        self.jitterBuffer = jitterBuffer
        self.session = session
        self.configuration = configuration
        self.backgroundActivity = backgroundActivity
        wireFormat = wire
        playbackFormat = playback
        renderer = PlaybackRenderer(jitterBuffer: jitterBuffer, counters: counters)
        worker = CaptureWorker(counters: counters)
        // Resolve the timebase now; its lazy initialisation must never happen on an audio thread.
        _ = HostTime.nanoseconds(fromTicks: 1)

        session.onInterruption = { [weak self] interruption in
            self?.handleInterruptionNotification(interruption)
        }
        session.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            self.engineQueue.async { self.handle(.mediaServicesReset) }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        healthTimer?.cancel()
        retryTimer?.cancel()
        worker.stop()
    }

    // MARK: - Public API

    /// Playback gain applied to the peer's voice and the cues (0...1). Applied asynchronously on the
    /// engine queue and re-applied after every graph rebuild, so the caller never blocks.
    var outputVolume: Float {
        get { lock.withLock { desiredOutputVolume } }
        set {
            lock.withLock { desiredOutputVolume = newValue }
            engineQueue.async { [self] in
                engine.mainMixerNode.outputVolume = newValue
            }
        }
    }

    /// Most recent peak level of the peer's voice, in dBFS.
    var outputLevelDB: Float {
        AudioLevel.decibels(fromLinear: renderer.outputPeak)
    }

    /// e.g. "48000 Hz, 1 ch" – whatever the current input route delivers.
    var inputDescription: String {
        lock.withLock { latestInputDescription }
    }

    /// Latency picture of the last second; refreshed once per second while the engine runs.
    var latency: AudioLatencySnapshot {
        lock.withLock { latestLatency }
    }

    /// Latest network round-trip time, for the mouth-to-ear estimate.
    var networkRoundTripMs: Double? {
        get { lock.withLock { latestRoundTripMs } }
        set { lock.withLock { latestRoundTripMs = newValue } }
    }

    /// Plays a notification cue into the output. Any thread. The request is only picked up by the
    /// next render cycle, so callers should check that audio is running (a best-effort check: the
    /// state they see lags the engine queue). A request still pending, or a cue cut off, when audio
    /// goes down is discarded by the attempt that brings it back (see `performAttempt`), so it
    /// never plays out of context later.
    func playCue(_ cue: CueTone) {
        renderer.play(cue)
    }

    /// Activates the session, builds the graph and starts the engine on the engine queue.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                do {
                    try startOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the engine and waits for the capture worker to deliver its last frame, so no frame
    /// reaches the transmit gate after this returns.
    func stop() {
        engineQueue.sync {
            guard machine.state != .stopped || healthTimer != nil else { return }
            Self.log.notice("stopping audio engine")
            stopHealthTimer()
            engine.stop()
            tearDownGraph()
            handle(.stopped)
            renderer.cancelCue()
            jitterBuffer.reset()
            worker.stop()
            interruptedFlag.store(false, ordering: .relaxed)
            sampler.reset()
            lock.withLock { latestLatency = AudioLatencySnapshot() }
        }
    }

    /// The scene became active or went to the background. Coming back retries audio at once when it
    /// is down (and is the only way out of `needsForeground`), or runs the watchdog when it is up.
    func setAppActive(_ active: Bool) {
        isAppActive.store(active, ordering: .relaxed)
        engineQueue.async { [self] in
            handle(.appActiveChanged(active))
        }
    }

    /// The user asked to bring paused audio back. Tries at once with a fresh backoff while audio is
    /// interrupted, recovering or waiting for the foreground; does nothing otherwise.
    func resumeAudio() {
        engineQueue.async { [self] in
            handle(.resumeRequested)
        }
    }

    /// The scene became active again after only being covered (Control Center, Siri, an alert), so
    /// `setAppActive(true)` changes nothing. Tries at once while audio is down, like `resumeAudio`.
    func sceneBecameActive() {
        engineQueue.async { [self] in
            handle(.sceneReactivated)
        }
    }

    /// The background task that keeps the app awake while audio is down is about to run out. A
    /// background recovery stops retrying and waits for the foreground; nothing happens otherwise.
    func backgroundTimeExhausted() {
        engineQueue.async { [self] in
            handle(.backgroundTimeExhausted)
        }
    }

    /// Capture mode or voice processing changed. Rebuilds a running engine; a voice-processing
    /// change uses a fresh `AVAudioEngine`, since toggling it on an engine that already ran is unreliable.
    func setConfiguration(_ newConfiguration: Configuration) {
        engineQueue.async { [self] in
            guard newConfiguration != configuration else { return }
            let recreate = newConfiguration.voiceProcessing != configuration.voiceProcessing
            if newConfiguration.captureMode != configuration.captureMode {
                sinkUnavailable = false
            }
            Self.log.notice("audio configuration: capture \(newConfiguration.captureMode.rawValue, privacy: .public), voice processing \(newConfiguration.voiceProcessing, privacy: .public)")
            configuration = newConfiguration
            handle(.reconfigure(recreateEngine: recreate))
        }
    }

    // MARK: - Start (engineQueue)

    private func startOnQueue() throws {
        guard machine.state == .stopped else { return }
        Self.log.notice("starting audio engine: capture \(self.configuration.captureMode.rawValue, privacy: .public), voice processing \(self.configuration.voiceProcessing, privacy: .public), app active \(self.isAppActive.load(ordering: .relaxed), privacy: .public)")
        // Bump, then clear: the order is load-bearing (see `handleInterruptionNotification`).
        generation.add(1, ordering: .relaxed)
        interruptedFlag.store(false, ordering: .relaxed)
        sinkUnavailable = false
        // A fresh engine per run: nothing stale survives a stop, a media services reset or a
        // voice-processing change made while stopped.
        replaceEngine()
        worker.start()
        do {
            try session.activate()
            try buildGraphAndStart()
        } catch {
            Self.log.error("audio engine start failed: \(Self.describe(error), privacy: .public)")
            engine.stop()
            tearDownGraph()
            worker.stop()
            throw error
        }
        installConfigurationObserverIfNeeded()
        handle(.started(appActive: isAppActive.load(ordering: .relaxed)))
        sampler.reset()
        startHealthTimer()
    }

    // MARK: - Recovery machine glue (engineQueue)

    private func handle(_ input: AudioRecoveryMachine.Input) {
        var pending = machine.handle(input)
        var index = 0
        while index < pending.count {
            let effect = pending[index]
            index += 1
            switch effect {
            case .stopEngine:
                engine.stop()
                renderer.cancelCue()
            case .attempt(let trigger, let recreate):
                let result: AudioRecoveryMachine.Input
                if let backgroundActivity {
                    result = backgroundActivity.perform("audio.attempt.\(trigger.rawValue)") {
                        performAttempt(trigger: trigger, recreateEngine: recreate)
                    }
                } else {
                    result = performAttempt(trigger: trigger, recreateEngine: recreate)
                }
                pending += machine.handle(result)
            case .scheduleRetry(let delay):
                scheduleRetry(after: delay)
            case .cancelRetry:
                cancelRetry()
            case .checkHealth:
                if let stall = checkWatchdog(now: .now()) {
                    pending += machine.handle(stall)
                }
            case .stateChanged(let state):
                Self.log.notice("audio state: \(state.description, privacy: .public)")
                onStateChange?(state)
            case .log(let message):
                Self.log.notice("\(message, privacy: .public)")
            }
        }
    }

    private func performAttempt(trigger: AudioRecoveryMachine.Trigger, recreateEngine: Bool) -> AudioRecoveryMachine.Input {
        Self.log.notice("audio attempt: trigger \(trigger.rawValue, privacy: .public), recreate engine \(recreateEngine, privacy: .public), app active \(self.isAppActive.load(ordering: .relaxed), privacy: .public)")
        engine.stop()
        tearDownGraph()
        if recreateEngine {
            replaceEngine()
        }
        if machine.state != .running {
            // Audio was down (interrupted, recovering, waiting for the foreground). A cue requested
            // just before it went down (the caller's state lags) or cut off by it is out of context
            // by now; the first render after the start drops both. Rebuilds while running keep theirs.
            renderer.cancelCue()
        }
        if trigger.reprobesSinkCapture, sinkUnavailable {
            // The route, the session or the engine is new: an earlier sink failure says nothing about it.
            Self.log.notice("sink node capture: trying again after \(trigger.rawValue, privacy: .public)")
            sinkUnavailable = false
        }
        do {
            try session.activate()
        } catch {
            Self.log.error("session activation failed: \(Self.describe(error), privacy: .public)")
            return .attemptFailed(Self.failureKind(error))
        }
        do {
            try buildGraphAndStart()
        } catch {
            Self.log.error("engine restart failed: \(Self.describe(error), privacy: .public)")
            engine.stop()
            tearDownGraph()
            return .attemptFailed(Self.failureKind(error))
        }
        // Bump, then clear: the order is load-bearing (see `handleInterruptionNotification`).
        generation.add(1, ordering: .relaxed)
        interruptedFlag.store(false, ordering: .relaxed)
        onEngineRestart?()
        return .attemptSucceeded
    }

    private func scheduleRetry(after delay: TimeInterval) {
        cancelRetry()
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.handle(.retryTimerFired)
        }
        timer.resume()
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    // MARK: - Interruptions and configuration changes

    /// Runs on the thread that posted the notification.
    private func handleInterruptionNotification(_ interruption: AudioSessionController.Interruption) {
        switch interruption {
        case .began:
            // Mark first, hop second: anything already queued on the engine queue sees the flag.
            // The order of the two writes is load-bearing. Here the flag is set before the
            // generation is bumped; the code that clears it (`startOnQueue`, `performAttempt`)
            // bumps before clearing. So if this `.began` turns out stale (a clearer's bump came
            // after ours), that clearer's `store(false)` also came after our `store(true)` and the
            // flag cannot be left set while running. In the opposite case the block below runs
            // with the flag already cleared and moves the machine to `.interrupted`, which is safe:
            // the configuration-change, sink-check and watchdog paths all require `.running`.
            interruptedFlag.store(true, ordering: .relaxed)
            let began = generation.add(1, ordering: .relaxed).newValue
            engineQueue.async { [self] in
                guard generation.load(ordering: .relaxed) == began else {
                    Self.log.notice("stale interruption began ignored: audio was recovered since")
                    return
                }
                handle(.interruptionBegan)
            }
        case .ended(let shouldResume):
            interruptedFlag.store(false, ordering: .relaxed)
            engineQueue.async { [self] in
                handle(.interruptionEnded(shouldResume: shouldResume))
            }
        }
    }

    private func installConfigurationObserverIfNeeded() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let changed = notification.object as? AVAudioEngine else { return }
            guard !self.interruptedFlag.load(ordering: .relaxed) else {
                Self.log.notice("configuration change ignored: interrupted")
                return
            }
            self.engineQueue.async {
                // `engine` is only safe to read here.
                guard changed === self.engine else { return }
                guard !self.interruptedFlag.load(ordering: .relaxed) else { return }
                // The engine stops itself when it posts this; running again means a rebuild that
                // already picked up the new format ran after the notification was posted.
                guard !self.engine.isRunning else {
                    Self.log.notice("configuration change: engine already restarted")
                    return
                }
                Self.log.notice("configuration change: hardware format or route changed")
                self.handle(.configurationChanged)
            }
        }
    }

    // MARK: - Health: watchdog and metrics (engineQueue)

    /// Tracks capture and render callback progress. An engine can report `isRunning` while no
    /// callbacks arrive (seen after phone-call interruptions), which only a rebuild fixes.
    private struct Watchdog {
        var captureCount = 0
        var renderCount = 0
        var captureProgress = MonotonicTime.zero
        var renderProgress = MonotonicTime.zero
        /// Capture callback count when the graph was last started.
        var captureCountAtStart = 0
        /// Render callback count when the graph was last started.
        var renderCountAtStart = 0
        /// Time the first capture callback after a start may take (longer while a Bluetooth
        /// hands-free link settles).
        var firstCaptureGrace: TimeInterval = 1
        /// Stall rebuilds since callbacks last flowed; the patience doubles with each (1, 2, 4, 8 s).
        var streak = 0

        var patience: TimeInterval {
            TimeInterval(1 << min(streak, 3))
        }

        /// Patience for capture: the first callback after a start gets at least `firstCaptureGrace`.
        var capturePatience: TimeInterval {
            captureCount == captureCountAtStart ? max(patience, firstCaptureGrace) : patience
        }

        mutating func rebase(captureCount: Int, renderCount: Int, now: MonotonicTime) {
            self.captureCount = captureCount
            captureCountAtStart = captureCount
            self.renderCount = renderCount
            renderCountAtStart = renderCount
            captureProgress = now
            renderProgress = now
        }
    }

    private func startHealthTimer() {
        stopHealthTimer()
        healthTicks = 0
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.healthTick() }
        timer.resume()
        healthTimer = timer
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func healthTick() {
        healthTicks += 1
        sampleLatency(log: healthTicks % Self.latencyLogInterval == 0)
        if let stall = checkWatchdog(now: .now()) {
            handle(stall)
        }
    }

    private func checkWatchdog(now: MonotonicTime) -> AudioRecoveryMachine.Input? {
        let captureCount = counters.captureCallbacks.load(ordering: .relaxed)
        let renderCount = counters.renderCallbacks.load(ordering: .relaxed)
        guard machine.state == .running, !interruptedFlag.load(ordering: .relaxed) else {
            watchdog.rebase(captureCount: captureCount, renderCount: renderCount, now: now)
            return nil
        }
        let captureMoved = captureCount != watchdog.captureCount
        let renderMoved = renderCount != watchdog.renderCount
        if captureMoved {
            watchdog.captureCount = captureCount
            watchdog.captureProgress = now
        }
        if renderMoved {
            watchdog.renderCount = renderCount
            watchdog.renderProgress = now
        }
        if captureMoved, renderMoved, watchdog.streak > 0 {
            Self.log.notice("audio callbacks flowing again after \(self.watchdog.streak, privacy: .public) watchdog rebuild(s)")
            watchdog.streak = 0
        }

        // An engine that stopped by itself delivers no callbacks either, so the same patience applies.
        let running = engine.isRunning ? "" : " (engine not running)"
        let reason: String
        if now - watchdog.captureProgress > watchdog.capturePatience {
            reason = String(format: "no capture callback for %.1f s", now - watchdog.captureProgress) + running
            if capturePath == .sinkNode, engine.isRunning, watchdog.captureCount == watchdog.captureCountAtStart,
               watchdog.renderCount != watchdog.renderCountAtStart {
                // Output ran but the sink never delivered anything since it was started: use the tap
                // until the route or the session changes (`Trigger.reprobesSinkCapture`). When render
                // is stuck too, or the engine stopped, the stall is engine-wide and not the sink's
                // fault: the rebuild fixes it whatever the capture path.
                sinkUnavailable = true
            }
        } else if now - watchdog.renderProgress > watchdog.patience {
            reason = String(format: "no render callback for %.1f s", now - watchdog.renderProgress) + running
        } else {
            return nil
        }
        watchdog.streak += 1
        // Keep a stubborn failure from rebuilding in place forever: from the second consecutive
        // stall on, start over with a fresh engine instance.
        let recreate = watchdog.streak >= 2
        Self.log.error("audio watchdog: \(reason, privacy: .public) (path \(self.capturePath.rawValue, privacy: .public), streak \(self.watchdog.streak, privacy: .public)); rebuilding")
        return .captureStalled(recreateEngine: recreate)
    }

    /// The sink node must deliver audio within `firstCaptureGrace` (1 s, 3 s on Bluetooth hands-free)
    /// of starting while output is running; otherwise capture falls back to the tap until the route
    /// or the session changes. Output stuck as well is an engine-wide stall, left to the watchdog.
    private func scheduleSinkCheck() {
        let build = buildCount
        let baseline = counters.captureCallbacks.load(ordering: .relaxed)
        let renderBaseline = counters.renderCallbacks.load(ordering: .relaxed)
        let delay = watchdog.firstCaptureGrace
        engineQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.buildCount == build, self.capturePath == .sinkNode,
                  self.machine.state == .running, !self.interruptedFlag.load(ordering: .relaxed),
                  self.engine.isRunning else { return }
            guard self.counters.captureCallbacks.load(ordering: .relaxed) == baseline,
                  self.counters.renderCallbacks.load(ordering: .relaxed) != renderBaseline else { return }
            Self.log.error("sink node delivered no audio within \(delay, format: .fixed(precision: 0), privacy: .public) s; falling back to the input tap")
            self.sinkUnavailable = true
            self.handle(.captureStalled(recreateEngine: false))
        }
    }

    private func sampleLatency(log: Bool) {
        var context = AudioLatencySampler.Context()
        context.capturePath = capturePath
        context.voiceProcessing = isVoiceProcessingActive
        context.inputSampleRate = inputSampleRate
        context.inputChannels = inputChannels
        context.session = session.metrics
        context.roundTripMs = networkRoundTripMs
        let snapshot = sampler.sample(reading: counters.read(), jitter: jitterBuffer.statistics,
                                      context: context, now: .now())
        lock.withLock { latestLatency = snapshot }
        if log {
            Self.latencyLog.notice("\(snapshot.logLine, privacy: .public) state=\(self.machine.state.description, privacy: .public)")
        }
    }

    // MARK: - Graph management (engineQueue)

    private func replaceEngine() {
        engine.stop()
        tearDownGraph()
        engine = AVAudioEngine()
    }

    private func buildGraphAndStart() throws {
        if configuration.captureMode == .lowLatency, !sinkUnavailable {
            do {
                try buildGraph(capture: .sinkNode)
                engine.prepare()
                try engine.start()
                didStart(capture: .sinkNode)
                scheduleSinkCheck()
                return
            } catch let error where Self.allowsTapFallback(error) {
                Self.log.error("sink node capture failed (\(Self.describe(error), privacy: .public)); falling back to the input tap")
                engine.stop()
                tearDownGraph()
                sinkUnavailable = true
            }
        }
        try buildGraph(capture: .tap)
        engine.prepare()
        try engine.start()
        didStart(capture: .tap)
    }

    private func didStart(capture: CapturePath) {
        capturePath = capture
        buildCount += 1
        // The first input callbacks of a Bluetooth hands-free route can take over a second while
        // the SCO link settles; that is not a stall and must not cost the sink.
        watchdog.firstCaptureGrace = session.currentRoute.isHandsFreeProfile ? 3 : 1
        watchdog.rebase(captureCount: counters.captureCallbacks.load(ordering: .relaxed),
                        renderCount: counters.renderCallbacks.load(ordering: .relaxed), now: .now())
        let metrics = session.metrics
        Self.log.notice("audio engine running: capture \(capture.rawValue, privacy: .public), input \(Int(self.inputSampleRate), privacy: .public) Hz \(self.inputChannels, privacy: .public) ch, voice processing \(self.isVoiceProcessingActive, privacy: .public), session \(Int(metrics.sampleRate), privacy: .public) Hz, IO \(metrics.ioBufferDuration * 1000, format: .fixed(precision: 1), privacy: .public) ms (preferred \(metrics.preferredIOBufferDuration * 1000, format: .fixed(precision: 1), privacy: .public)), latency in \(metrics.inputLatency * 1000, format: .fixed(precision: 1), privacy: .public) out \(metrics.outputLatency * 1000, format: .fixed(precision: 1), privacy: .public) ms")
    }

    private func buildGraph(capture: CapturePath) throws {
        // Playback first: the voice-processing I/O unit takes the rendered output as its echo
        // reference, and enabling voice processing before the playback graph is attached has been
        // reported to leave echo cancellation silently ineffective.
        let renderer = self.renderer
        let source = AVAudioSourceNode(format: playbackFormat) { isSilence, timestamp, frameCount, bufferList -> OSStatus in
            renderer.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, bufferList: bufferList)
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: playbackFormat)
        engine.mainMixerNode.outputVolume = outputVolume
        sourceNode = source

        // Voice processing (echo cancellation, gain control) must be set while the engine is
        // stopped and before the input format is read.
        let input = engine.inputNode
        if input.isVoiceProcessingEnabled != configuration.voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(configuration.voiceProcessing)
            } catch {
                Self.log.error("voice processing \(self.configuration.voiceProcessing ? "enable" : "disable", privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            }
        }
        isVoiceProcessingActive = input.isVoiceProcessingEnabled

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioEngineError.noInputAvailable
        }
        inputSampleRate = hardwareFormat.sampleRate
        inputChannels = Int(hardwareFormat.channelCount)
        lock.withLock {
            latestInputDescription = String(format: "%.0f Hz, %d ch", hardwareFormat.sampleRate, Int(hardwareFormat.channelCount))
        }

        // Channel 0 is captured whatever the channel count; the worker converts from mono Float32 at
        // the hardware rate (16, 24, 44.1, 48 kHz, ...) to the 16 kHz wire format.
        let captureSource = try CaptureSource(sampleRate: hardwareFormat.sampleRate, wireFormat: wireFormat, counters: counters)
        let ring = captureSource.ring

        switch capture {
        case .sinkNode:
            // The sink node does not convert, so it receives the input node's own format (`nil`
            // below), which must be Float32 for the ring.
            guard hardwareFormat.commonFormat == .pcmFormatFloat32 else {
                throw AudioEngineError.sinkFormatUnsupported
            }
            let sink = AVAudioSinkNode { timestamp, frameCount, bufferList -> OSStatus in
                let hostTime = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : 0
                ring.write(bufferList, frameCount: Int(frameCount), hostTime: hostTime)
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: sink, format: nil)
            sinkNode = sink
        case .tap:
            guard let tapFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate,
                                                channels: hardwareFormat.channelCount) else {
                throw AudioEngineError.converterUnavailable
            }
            // The size is a request; iOS may deliver much larger buffers (see the type comment).
            let bufferSize = AVAudioFrameCount(max(256, (hardwareFormat.sampleRate * IntercomProtocol.frameDuration).rounded()))
            input.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { buffer, when in
                ring.write(buffer.audioBufferList, frameCount: Int(buffer.frameLength),
                           hostTime: when.isHostTimeValid ? when.hostTime : 0)
            }
            isTapInstalled = true
        case .none:
            break
        }
        worker.setSource(captureSource)
    }

    private func tearDownGraph() {
        worker.setSource(nil)
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if let sinkNode {
            engine.disconnectNodeInput(sinkNode)
            engine.detach(sinkNode)
            self.sinkNode = nil
        }
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        capturePath = .none
    }

    // MARK: - Errors

    private static func failureKind(_ error: Error) -> AudioFailureKind {
        if error is AudioEngineError {
            return .other(-1)
        }
        return AudioFailureKind(code: (error as NSError).code)
    }

    /// Falling back helps with graph problems, not with a session the system refuses to activate.
    private static func allowsTapFallback(_ error: Error) -> Bool {
        if let engineError = error as? AudioEngineError {
            return engineError == .sinkFormatUnsupported
        }
        return !failureKind(error).isSessionFailure
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if error is AudioEngineError {
            return String(describing: error)
        }
        return "\(nsError.domain) \(AudioFailureKind(code: nsError.code))"
    }
}
