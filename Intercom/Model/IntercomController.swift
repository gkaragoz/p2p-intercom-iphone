import AVFoundation
import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// Orchestrates the audio session, the audio engine and the peer-to-peer transport, and exposes
/// everything the UI needs as published state. Lives on the main actor.
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

        let id: MCPeerID
        var name: String
        var state: State
        var appVersion: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peers: [PeerInfo] = []
    @Published private(set) var isSending = false
    @Published private(set) var isVoiceDetected = false
    @Published private(set) var isTalkButtonHeld = false
    @Published private(set) var remoteTalking = false
    @Published private(set) var remoteMuted = false
    @Published private(set) var inputMeter: Float = 0
    @Published private(set) var outputMeter: Float = 0
    @Published private(set) var route: AudioSessionController.Route = .unknown
    @Published private(set) var roundTripMs: Double?
    @Published private(set) var statistics = JitterBuffer.Statistics()
    @Published private(set) var framesSent = 0
    @Published private(set) var inputDescription = ""
    @Published private(set) var lastError: String?
    @Published var isMuted = false {
        didSet {
            guard oldValue != isMuted else { return }
            pipeline.gate.setMuted(isMuted)
            sendTalkState()
        }
    }

    let settings: AppSettings
    let pipeline: AudioPipeline

    private let jitterBuffer: JitterBuffer
    private let audioSession = AudioSessionController()
    private let engine: AudioEngineController
    private var transport: MultipeerTransport?
    private var rtt = RoundTripEstimator()
    private var outputSmoother = LevelSmoother()
    private var remoteTalkFlag = false
    private var settingsObservers = Set<AnyCancellable>()
    private var timers = Set<AnyCancellable>()

    convenience init() {
        self.init(settings: AppSettings())
    }

    init(settings: AppSettings) {
        self.settings = settings
        let jitter = JitterBuffer(configuration: settings.jitterConfiguration)
        jitterBuffer = jitter
        engine = AudioEngineController(jitterBuffer: jitter)
        let gate = TransmitGate(
            mode: settings.transmitMode,
            detector: VoiceActivityDetector(thresholdDB: Float(settings.voxThresholdDB))
        )
        pipeline = AudioPipeline(gate: gate, jitterBuffer: jitter)
        wireCallbacks()
        observeSettings()
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

    /// Requests microphone access, activates audio and starts looking for peers.
    func start() async {
        switch phase {
        case .idle, .permissionDenied, .failed:
            break
        default:
            return
        }

        phase = .requestingPermission
        let granted = await MicrophonePermission.request()
        guard granted else {
            phase = .permissionDenied
            return
        }

        phase = .starting
        lastError = nil
        do {
            audioSession.startObserving()
            try audioSession.activate()
            route = audioSession.currentRoute
            try engine.start()
            engine.outputVolume = Float(settings.outputVolume)
            inputDescription = engine.inputDescription
            startTransport()
            startTimers()
            phase = .searching
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
        } catch {
            lastError = error.localizedDescription
            phase = .failed(error.localizedDescription)
            tearDown()
        }
    }

    func stop() {
        tearDown()
        phase = .idle
    }

    /// Manually invites a discovered peer (auto-connect normally does this).
    func connect(to peer: PeerInfo) {
        transport?.invite(peer.id)
    }

    func disconnect() {
        transport?.disconnectAll()
    }

    // MARK: - Talk controls

    func pressTalkButton() {
        guard settings.transmitMode == .pushToTalk, !isTalkButtonHeld else { return }
        isTalkButtonHeld = true
        pipeline.gate.setButtonHeld(true)
    }

    func releaseTalkButton() {
        guard isTalkButtonHeld else { return }
        isTalkButtonHeld = false
        pipeline.gate.setButtonHeld(false)
    }

    func toggleMute() {
        isMuted.toggle()
    }

    // MARK: - Private: setup

    private func wireCallbacks() {
        let pipeline = self.pipeline
        engine.onCapturedFrame = { samples, levelDB in
            pipeline.handleCapturedFrame(samples, levelDB: levelDB)
        }
        engine.onEngineRestart = { [weak self] in
            Task { @MainActor in self?.handleEngineRestart() }
        }
        engine.onEngineFailure = { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
        pipeline.onSendingChanged = { [weak self] sending in
            Task { @MainActor in self?.sendingDidChange(sending) }
        }
        audioSession.onRouteChange = { [weak self] route, _ in
            Task { @MainActor in self?.route = route }
        }
        audioSession.onInterruption = { [weak self] interruption in
            Task { @MainActor in self?.handleInterruption(interruption) }
        }
        audioSession.onMediaServicesReset = { [weak self] in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    private func observeSettings() {
        settings.$transmitMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self else { return }
                self.releaseTalkButton()
                self.pipeline.gate.setMode(mode)
            }
            .store(in: &settingsObservers)

        settings.$voxThresholdDB
            .dropFirst()
            .sink { [weak self] threshold in
                self?.pipeline.gate.setVoiceThreshold(dB: Float(threshold))
            }
            .store(in: &settingsObservers)

        settings.$jitterTargetMs
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] targetMs in
                self?.jitterBuffer.configuration = AppSettings.jitterConfiguration(targetMs: targetMs)
            }
            .store(in: &settingsObservers)

        settings.$outputVolume
            .dropFirst()
            .sink { [weak self] volume in
                guard let self, self.isRunning else { return }
                self.engine.outputVolume = Float(volume)
            }
            .store(in: &settingsObservers)

        settings.$keepScreenAwake
            .dropFirst()
            .sink { [weak self] keepAwake in
                guard let self, self.isRunning else { return }
                UIApplication.shared.isIdleTimerDisabled = keepAwake
            }
            .store(in: &settingsObservers)

        settings.$displayName
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.restartTransport()
            }
            .store(in: &settingsObservers)
    }

    // MARK: - Private: transport

    private func startTransport() {
        let name = localDisplayName
        let peerID = PeerIdentity.peerID(displayName: name)
        let transport = MultipeerTransport(peerID: peerID, displayName: name)
        transport.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleTransportEvent(event) }
        }
        let pipeline = self.pipeline
        transport.onAudio = { packet, _ in
            pipeline.receive(packet)
        }
        pipeline.setTransport(transport)
        self.transport = transport
        transport.start()
    }

    private func stopTransport() {
        pipeline.setTransport(nil)
        transport?.onEvent = nil
        transport?.onAudio = nil
        transport?.stop()
        transport = nil
        peers.removeAll()
        remoteTalkFlag = false
        remoteTalking = false
        remoteMuted = false
        roundTripMs = nil
        rtt.reset()
        jitterBuffer.reset()
    }

    private func restartTransport() {
        stopTransport()
        startTransport()
        if phase == .connected {
            phase = .searching
        }
    }

    private func handleTransportEvent(_ event: MultipeerTransport.Event) {
        switch event {
        case .discovered(let peer):
            upsertPeer(peer.peerID, state: .discovered)
        case .lost(let peerID):
            if let index = peers.firstIndex(where: { $0.id == peerID }), peers[index].state != .connected {
                peers.remove(at: index)
            }
        case .stateChanged(let peerID, let state):
            switch state {
            case .connecting:
                upsertPeer(peerID, state: .connecting)
            case .connected:
                peerDidConnect(peerID)
            case .notConnected:
                peerDidDisconnect(peerID)
            @unknown default:
                break
            }
        case .control(let message, let peerID):
            handleControl(message, from: peerID)
        case .failure(let description):
            lastError = description
        }
    }

    private func upsertPeer(_ peerID: MCPeerID, state: PeerInfo.State) {
        if let index = peers.firstIndex(where: { $0.id == peerID }) {
            // Never downgrade a live connection because of a stale discovery callback.
            if peers[index].state == .connected, state != .connected { return }
            peers[index].state = state
        } else {
            peers.append(PeerInfo(id: peerID, name: peerID.displayName, state: state, appVersion: nil))
        }
    }

    private func peerDidConnect(_ peerID: MCPeerID) {
        if let index = peers.firstIndex(where: { $0.id == peerID }) {
            peers[index].state = .connected
        } else {
            peers.append(PeerInfo(id: peerID, name: peerID.displayName, state: .connected, appVersion: nil))
        }
        phase = .connected
        lastError = nil
        jitterBuffer.reset()
        rtt.reset()
        roundTripMs = nil
        remoteTalkFlag = false
        remoteTalking = false
        remoteMuted = false
        transport?.sendControl(.hello(.init(displayName: localDisplayName,
                                            appVersion: Self.appVersion,
                                            protocolVersion: IntercomProtocol.version)))
        sendTalkState()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func peerDidDisconnect(_ peerID: MCPeerID) {
        let wasConnected = peers.first(where: { $0.id == peerID })?.state == .connected
        peers.removeAll { $0.id == peerID }
        if connectedPeers.isEmpty {
            if isRunning { phase = .searching }
            remoteTalkFlag = false
            remoteTalking = false
            remoteMuted = false
            roundTripMs = nil
            rtt.reset()
            jitterBuffer.reset()
        }
        if wasConnected {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    private func handleControl(_ message: ControlMessage, from peerID: MCPeerID) {
        switch message {
        case .hello(let hello):
            if let index = peers.firstIndex(where: { $0.id == peerID }) {
                peers[index].name = DisplayName.sanitized(hello.displayName)
                peers[index].appVersion = hello.appVersion
            }
        case .talkState(let state):
            remoteTalkFlag = state.isTalking
            remoteMuted = state.isMuted
            refreshRemoteTalking(secondsSinceAudio: pipeline.snapshot().secondsSinceRemoteAudio)
        case .ping(let ping):
            transport?.sendControl(.pong(ping))
        case .pong(let ping):
            if rtt.receivePong(ping, nowMs: Self.nowMs) != nil {
                roundTripMs = rtt.smoothedRTTMs
            }
        case .bye:
            remoteTalkFlag = false
            refreshRemoteTalking(secondsSinceAudio: .infinity)
        }
    }

    private func sendTalkState() {
        transport?.sendControl(.talkState(.init(isTalking: isSending, isMuted: isMuted)))
    }

    private func sendingDidChange(_ sending: Bool) {
        guard sending != isSending else { return }
        isSending = sending
        sendTalkState()
    }

    // MARK: - Private: audio events

    private func handleEngineRestart() {
        route = audioSession.currentRoute
        inputDescription = engine.inputDescription
        engine.outputVolume = Float(settings.outputVolume)
    }

    private func handleInterruption(_ interruption: AudioSessionController.Interruption) {
        switch interruption {
        case .began:
            releaseTalkButton()
            if pipeline.gate.close() {
                sendingDidChange(false)
            }
        case .ended:
            // Even when iOS does not suggest resuming, an intercom should come back on its own.
            guard isRunning else { return }
            do {
                try audioSession.reactivate()
            } catch {
                lastError = error.localizedDescription
            }
            engine.restart()
        }
    }

    private func handleMediaServicesReset() {
        guard isRunning else { return }
        do {
            try audioSession.activate()
        } catch {
            lastError = error.localizedDescription
        }
        engine.recreateEngine()
    }

    // MARK: - Private: timers

    private func startTimers() {
        timers.removeAll()
        Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickMeters() }
            .store(in: &timers)
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickPing() }
            .store(in: &timers)
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
        refreshRemoteTalking(secondsSinceAudio: snapshot.secondsSinceRemoteAudio)
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

    private func tickPing() {
        guard let transport, !connectedPeers.isEmpty else { return }
        transport.sendControl(.ping(rtt.makePing(nowMs: Self.nowMs)))
    }

    private static var nowMs: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Private: teardown

    private func tearDown() {
        timers.removeAll()
        stopTransport()
        releaseTalkButton()
        pipeline.gate.close()
        engine.stop()
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
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
