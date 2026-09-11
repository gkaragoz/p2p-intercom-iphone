import AVFoundation
import Foundation
import os.log

enum AudioEngineError: LocalizedError {
    case noInputAvailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return String(localized: "No microphone input is available.")
        case .converterUnavailable:
            return String(localized: "The audio format could not be converted.")
        }
    }
}

/// Runs the `AVAudioEngine` graph:
///
///     inputNode ──tap──▶ AVAudioConverter ──▶ 20 ms Int16 frames ──▶ onCapturedFrame
///     JitterBuffer ──▶ AVAudioSourceNode ──▶ mainMixerNode ──▶ outputNode (AirPods / speaker)
///
/// All graph mutations happen on `engineQueue`. Converted samples are re-blocked into frames and
/// delivered on `callbackQueue`. The render block runs on the audio thread and only touches the
/// jitter buffer (a short critical section, no allocation on the steady-state path) and a
/// preallocated scratch buffer.
///
/// Recovery: a one-second health check on `engineQueue` restarts the engine whenever it is found
/// stopped while it should be running (transient failures during a Bluetooth hand-off, an
/// interruption whose `.ended` notification never arrives, ...). `suspend()` pauses that check for
/// the duration of an audio interruption.
final class AudioEngineController {
    typealias FrameHandler = @Sendable (_ samples: [Int16], _ levelDB: Float) -> Void

    let jitterBuffer: JitterBuffer

    /// Called for every captured 20 ms frame, on a private serial queue.
    var onCapturedFrame: FrameHandler?
    /// Called on the private queue whenever the graph was rebuilt (route / configuration change).
    var onEngineRestart: (@Sendable () -> Void)?
    /// Called on the private queue when the engine could not be restarted after a configuration change.
    var onEngineFailure: (@Sendable (Error) -> Void)?
    /// Called on `engineQueue` right before every (re)start; use it to make sure the audio session is active.
    var prepareSession: (@Sendable () throws -> Void)?

    private var engine = AVAudioEngine()
    private let wireFormat: AVAudioFormat
    private let playbackFormat: AVAudioFormat
    private var sourceNode: AVAudioSourceNode?
    private var chunker = FrameChunker(frameSize: IntercomProtocol.frameSamples)
    private let callbackQueue = DispatchQueue(label: "intercom.audio.capture", qos: .userInteractive)
    private let engineQueue = DispatchQueue(label: "intercom.audio.engine", qos: .userInitiated)
    private var wantsRunning = false
    private var isSuspended = false
    private var hasReportedFailure = false
    private var healthTimer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private let renderScratch: UnsafeMutableBufferPointer<Int16>
    private let levelLock = NSLock()
    private var latestOutputLevelDB: Float = -100
    private var latestInputDescription = ""
    private var desiredOutputVolume: Float = 1
    private static let log = OSLog(subsystem: "intercom", category: "audio")

    init(jitterBuffer: JitterBuffer) {
        guard let wire = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: IntercomProtocol.sampleRate,
                                       channels: AVAudioChannelCount(IntercomProtocol.channelCount),
                                       interleaved: true),
              let playback = AVAudioFormat(standardFormatWithSampleRate: IntercomProtocol.sampleRate,
                                           channels: AVAudioChannelCount(IntercomProtocol.channelCount)) else {
            fatalError("The intercom wire format is not representable by AVAudioFormat")
        }
        self.jitterBuffer = jitterBuffer
        wireFormat = wire
        playbackFormat = playback
        renderScratch = UnsafeMutableBufferPointer<Int16>.allocate(capacity: 16_384)
        renderScratch.initialize(repeating: 0)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        healthTimer?.cancel()
        renderScratch.deallocate()
    }

    // MARK: - Public API

    /// Playback gain applied to the peer's voice (0...1). Applied asynchronously on the engine
    /// queue and re-applied after every graph rebuild, so the caller never blocks.
    var outputVolume: Float {
        get {
            levelLock.lock()
            defer { levelLock.unlock() }
            return desiredOutputVolume
        }
        set {
            levelLock.lock()
            desiredOutputVolume = newValue
            levelLock.unlock()
            engineQueue.async { [self] in
                engine.mainMixerNode.outputVolume = newValue
            }
        }
    }

    /// Most recent peak level of the audio being played, in dBFS.
    var outputLevelDB: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestOutputLevelDB
    }

    /// e.g. "48000 Hz, 1 ch" – whatever the current input route delivers.
    var inputDescription: String {
        levelLock.lock()
        defer { levelLock.unlock() }
        return latestInputDescription
    }

    /// Builds the graph and starts the engine. Runs on the engine queue; the caller is not blocked.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                do {
                    wantsRunning = true
                    isSuspended = false
                    hasReportedFailure = false
                    try buildGraphAndStart()
                    installObserverIfNeeded()
                    startHealthTimer()
                    continuation.resume()
                } catch {
                    wantsRunning = false
                    stopHealthTimer()
                    engine.stop()
                    tearDownGraph()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the engine and waits for any capture callback still in flight, so no frame reaches
    /// the transmit gate after this returns.
    func stop() {
        engineQueue.sync {
            wantsRunning = false
            isSuspended = false
            stopHealthTimer()
            engine.stop()
            tearDownGraph()
            jitterBuffer.reset()
        }
        callbackQueue.sync {}
    }

    /// The system stopped the engine for an audio interruption (phone call, Siri, ...).
    /// Pauses automatic recovery until `resume(endingSuspension:)` succeeds.
    func suspend() {
        engineQueue.async { [self] in
            isSuspended = true
            engine.stop()
        }
    }

    /// Brings the engine back if it is not running.
    ///
    /// - Parameter endingSuspension: `true` when the interruption is known to be over (the
    ///   `.ended` notification arrived): the suspension is lifted even if this attempt fails so the
    ///   health check keeps retrying. `false` for best-effort attempts (the app became active):
    ///   the suspension is only lifted once a rebuild actually succeeds, because the interruption
    ///   may still be in progress.
    func resume(endingSuspension: Bool) {
        engineQueue.async { [self] in
            guard wantsRunning else { return }
            if endingSuspension {
                isSuspended = false
            }
            if engine.isRunning {
                isSuspended = false
                return
            }
            do {
                try buildGraphAndStart()
                isSuspended = false
                hasReportedFailure = false
                callbackQueue.async { [weak self] in self?.onEngineRestart?() }
            } catch {
                os_log("Engine resume failed: %{public}@", log: Self.log, type: .info, String(describing: error))
            }
        }
    }

    /// Throws away the engine instance entirely; required after `mediaServicesWereReset`.
    func recreateEngine() {
        engineQueue.async { [self] in
            isSuspended = false
            engine.stop()
            tearDownGraph()
            engine = AVAudioEngine()
            rebuildIfWanted()
        }
    }

    // MARK: - Graph management (engineQueue only)

    private func buildGraphAndStart() throws {
        try prepareSession?()
        tearDownGraph()
        try buildGraph()
        engine.prepare()
        try engine.start()
    }

    private func rebuildIfWanted() {
        guard wantsRunning, !isSuspended else { return }
        do {
            try buildGraphAndStart()
            hasReportedFailure = false
            callbackQueue.async { [weak self] in self?.onEngineRestart?() }
        } catch {
            os_log("Engine restart failed: %{public}@", log: Self.log, type: .error, String(describing: error))
            // The health check keeps retrying every second; report only the first failure of a streak.
            if !hasReportedFailure {
                hasReportedFailure = true
                callbackQueue.async { [weak self] in self?.onEngineFailure?(error) }
            }
        }
    }

    private func startHealthTimer() {
        stopHealthTimer()
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.healthCheck() }
        timer.resume()
        healthTimer = timer
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func healthCheck() {
        guard wantsRunning, !isSuspended, !engine.isRunning else { return }
        os_log("Engine is not running; attempting recovery", log: Self.log, type: .info)
        rebuildIfWanted()
    }

    private func buildGraph() throws {
        let input = engine.inputNode

        // Voice processing gives us echo cancellation and automatic gain control, which matters
        // when the phone plays through its loudspeaker instead of AirPods. It must be enabled
        // before the engine starts and before the input format is read.
        if !input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                os_log("Voice processing unavailable: %{public}@", log: Self.log, type: .info, String(describing: error))
            }
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioEngineError.noInputAvailable
        }
        guard let converter = AVAudioConverter(from: hardwareFormat, to: wireFormat) else {
            throw AudioEngineError.converterUnavailable
        }
        callbackQueue.async { [weak self] in self?.chunker.reset() }
        levelLock.lock()
        latestInputDescription = String(format: "%.0f Hz, %d ch", hardwareFormat.sampleRate, Int(hardwareFormat.channelCount))
        levelLock.unlock()

        // The converter is bound to the tap that feeds it, so a callback still in flight for an old
        // hardware format can never meet a converter built for a new one.
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer, using: converter)
        }

        let source = AVAudioSourceNode(format: playbackFormat) { [weak self] isSilence, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            return self.render(isSilence: isSilence, frameCount: frameCount, audioBufferList: audioBufferList)
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: playbackFormat)
        engine.mainMixerNode.outputVolume = outputVolume
        sourceNode = source
    }

    private func tearDownGraph() {
        engine.inputNode.removeTap(onBus: 0)
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Hop to the engine queue first; `engine` is only safe to read there.
            guard let self, let changed = notification.object as? AVAudioEngine else { return }
            self.engineQueue.async {
                guard changed === self.engine else { return }
                self.rebuildIfWanted()
            }
        }
    }

    // MARK: - Capture (tap thread)

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        guard buffer.frameLength > 0 else { return }
        let ratio = wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }

        var consumedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0, let channel = converted.int16ChannelData else {
            if let conversionError {
                os_log("Conversion failed: %{public}@", log: Self.log, type: .error, conversionError.localizedDescription)
            }
            return
        }

        // Copy out of the engine-owned buffer; chunking and delivery happen on the callback queue,
        // which is the only place `chunker` is touched.
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
        callbackQueue.async { [weak self] in
            guard let self else { return }
            let frames = self.chunker.append(samples)
            guard !frames.isEmpty, let handler = self.onCapturedFrame else { return }
            for frame in frames {
                let level = AudioLevel.decibels(fromLinear: AudioLevel.rms(frame))
                handler(frame, level)
            }
        }
    }

    // MARK: - Render (audio thread)

    private func render(isSilence: UnsafeMutablePointer<ObjCBool>,
                        frameCount: AVAudioFrameCount,
                        audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let count = Int(frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard count > 0, count <= renderScratch.count, let first = buffers.first, let rawOutput = first.mData else {
            return noErr
        }
        guard Int(first.mDataByteSize) >= count * MemoryLayout<Float>.size else {
            return noErr
        }

        let scratch = UnsafeMutableBufferPointer(rebasing: renderScratch[0..<count])
        let realSamples = jitterBuffer.pull(into: scratch)

        let output = rawOutput.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for index in 0..<count {
            let value = Float(scratch[index]) / 32_768
            output[index] = value
            peak = max(peak, abs(value))
        }
        // Mono only; blank any extra channels defensively.
        if buffers.count > 1 {
            for extra in buffers.dropFirst() {
                if let data = extra.mData {
                    memset(data, 0, Int(extra.mDataByteSize))
                }
            }
        }
        isSilence.pointee = ObjCBool(realSamples == 0)

        let level = AudioLevel.decibels(fromLinear: peak)
        if levelLock.`try`() {
            latestOutputLevelDB = level
            levelLock.unlock()
        }
        return noErr
    }
}
