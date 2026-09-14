import Foundation

/// Which microphone capture implementation the user prefers (Settings > Audio > Capture).
enum CaptureMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// `AVAudioSinkNode` on the real-time I/O thread: one I/O buffer of capture delay. Falls back to
    /// the tap automatically when the sink graph cannot be built or stays silent.
    case lowLatency
    /// `installTap`: works everywhere, but iOS may deliver 100 ms (or larger) chunks.
    case compatible

    var id: String { rawValue }
}

/// The capture implementation actually in use.
enum CapturePath: String, Equatable, Sendable {
    case none
    case sinkNode = "sink"
    case tap
}

/// Values read back from `AVAudioSession` after activation; the preferences are only hints.
struct AudioSessionMetrics: Equatable, Sendable {
    var sampleRate: Double = 0
    var ioBufferDuration: TimeInterval = 0
    var preferredIOBufferDuration: TimeInterval = 0
    var inputLatency: TimeInterval = 0
    var outputLatency: TimeInterval = 0
}

/// One read of the audio engine's lock-free counters.
///
/// Cumulative values only ever grow; the `window` values cover the time since the previous reading
/// (the reader resets them as it reads) and are `nil` when nothing happened in that window.
struct AudioCounterReading: Equatable, Sendable {
    var captureCallbacks = 0
    var captureFrames = 0
    var captureOverrunSamples = 0
    var deliveredFrames = 0
    var deliveryLagSumNs = 0
    var deliveryLagCount = 0
    var renderCallbacks = 0
    var renderEarlyReturns = 0

    var windowCaptureFramesMin: Int?
    var windowCaptureFramesMax: Int?
    var windowCaptureMaxIntervalNs: Int?
    var windowDeliveryLagMaxNs: Int?
    var windowRenderFramesMin: Int?
    var windowRenderFramesMax: Int?
    var windowRenderMaxIntervalNs: Int?
}

/// Latency picture of the audio path over the last sampling interval (about one second), for the
/// diagnostics screen and the "latency" log.
struct AudioLatencySnapshot: Equatable, Sendable {
    var capturePath: CapturePath = .none
    var voiceProcessing = false
    var inputSampleRate: Double = 0
    var inputChannels = 0
    var session = AudioSessionMetrics()

    var captureCallbacksPerSecond: Double = 0
    var captureFramesPerCallbackMin = 0
    var captureFramesPerCallbackAverage: Double = 0
    var captureFramesPerCallbackMax = 0
    var maxCaptureIntervalMs: Double = 0
    /// From the moment the first sample of a capture callback was recorded to the capture worker
    /// picking it up: the capture buffer (one I/O buffer for the sink node, possibly 100 ms or more
    /// for a tap) plus the worker's poll delay.
    var deliveryLagAverageMs: Double = 0
    var deliveryLagMaxMs: Double = 0
    var captureOverrunSamplesPerSecond: Double = 0
    var framesDeliveredPerSecond: Double = 0

    var renderCallbacksPerSecond: Double = 0
    var renderFramesMin = 0
    var renderFramesMax = 0
    var maxRenderIntervalMs: Double = 0
    var renderEarlyReturnsPerSecond: Double = 0

    var jitterTargetMs = 0
    var jitterDepthMs = 0
    var jitterMs = 0
    var underrunsPerSecond: Double = 0
    var concealedPerSecond: Double = 0
    var latePerSecond: Double = 0
    var trimmedPerSecond: Double = 0
    var lockMissesPerSecond: Double = 0

    var roundTripMs: Double?

    /// Rough one-way delay from the peer's mouth to this phone's ear, assuming the peer's capture side
    /// behaves like this phone's (it runs the same build):
    ///
    ///     sender:   input latency + capture delivery lag (includes the capture buffer) + 20 ms frame
    ///     network:  round-trip time / 2
    ///     receiver: playout target − 20 ms (a frame arriving on time waits that long) + I/O buffer
    ///               + output latency
    ///
    /// The frame duration cancels out. Voice processing and Bluetooth codec delays are not visible
    /// to the app and are not included. `nil` until audio has actually been flowing.
    var estimatedMouthToEarMs: Double? {
        guard capturePath != .none, session.ioBufferDuration > 0, jitterTargetMs > 0 else { return nil }
        let io = session.ioBufferDuration * 1000
        return session.inputLatency * 1000 + deliveryLagAverageMs
            + (roundTripMs ?? 0) / 2
            + Double(jitterTargetMs) + io + session.outputLatency * 1000
    }

    /// One compact line for the "latency" log category.
    var logLine: String {
        func f(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
        let rate = inputSampleRate > 0 ? "\(Int(inputSampleRate))Hz/\(inputChannels)ch" : "-"
        let m2e = estimatedMouthToEarMs.map { "\(Int($0.rounded()))ms" } ?? "-"
        let rtt = roundTripMs.map { "\(Int($0.rounded()))ms" } ?? "-"
        return "capture=\(capturePath.rawValue) in=\(rate) vp=\(voiceProcessing ? "on" : "off")"
            + " io=\(f(session.ioBufferDuration * 1000))ms(pref \(f(session.preferredIOBufferDuration * 1000))) sr=\(Int(session.sampleRate))"
            + " lat in=\(f(session.inputLatency * 1000)) out=\(f(session.outputLatency * 1000))"
            + " | cb=\(f(captureCallbacksPerSecond))/s frames=\(captureFramesPerCallbackMin)/\(f(captureFramesPerCallbackAverage))/\(captureFramesPerCallbackMax)"
            + " gap=\(f(maxCaptureIntervalMs))ms lag=\(f(deliveryLagAverageMs))/\(f(deliveryLagMaxMs))ms ovr=\(f(captureOverrunSamplesPerSecond, 0))"
            + " captured=\(f(framesDeliveredPerSecond))/s"
            + " | render=\(renderFramesMin)-\(renderFramesMax) gap=\(f(maxRenderIntervalMs))ms early=\(f(renderEarlyReturnsPerSecond, 0))"
            + " | jb target=\(jitterTargetMs) depth=\(jitterDepthMs) jitter=\(jitterMs)"
            + " und=\(f(underrunsPerSecond)) conc=\(f(concealedPerSecond)) late=\(f(latePerSecond)) trim=\(f(trimmedPerSecond)) miss=\(f(lockMissesPerSecond))"
            + " | rtt=\(rtt) m2e=\(m2e)"
    }
}

/// Turns successive counter readings into per-second rates and a snapshot. Pure; the audio engine
/// feeds it once per second.
struct AudioLatencySampler {
    private var previousReading: AudioCounterReading?
    private var previousJitter: JitterBuffer.Statistics?
    private var previousTime: MonotonicTime?

    mutating func reset() {
        previousReading = nil
        previousJitter = nil
        previousTime = nil
    }

    struct Context: Equatable, Sendable {
        var capturePath: CapturePath = .none
        var voiceProcessing = false
        var inputSampleRate: Double = 0
        var inputChannels = 0
        var session = AudioSessionMetrics()
        var roundTripMs: Double?
    }

    mutating func sample(reading: AudioCounterReading, jitter: JitterBuffer.Statistics, context: Context,
                         now: MonotonicTime) -> AudioLatencySnapshot {
        var snapshot = AudioLatencySnapshot()
        snapshot.capturePath = context.capturePath
        snapshot.voiceProcessing = context.voiceProcessing
        snapshot.inputSampleRate = context.inputSampleRate
        snapshot.inputChannels = context.inputChannels
        snapshot.session = context.session
        snapshot.roundTripMs = context.roundTripMs
        snapshot.jitterTargetMs = jitter.targetDelayMs
        snapshot.jitterDepthMs = jitter.depthMs
        snapshot.jitterMs = jitter.jitterMs
        snapshot.captureFramesPerCallbackMin = reading.windowCaptureFramesMin ?? 0
        snapshot.captureFramesPerCallbackMax = reading.windowCaptureFramesMax ?? 0
        snapshot.maxCaptureIntervalMs = Self.ms(reading.windowCaptureMaxIntervalNs)
        snapshot.deliveryLagMaxMs = Self.ms(reading.windowDeliveryLagMaxNs)
        snapshot.renderFramesMin = reading.windowRenderFramesMin ?? 0
        snapshot.renderFramesMax = reading.windowRenderFramesMax ?? 0
        snapshot.maxRenderIntervalMs = Self.ms(reading.windowRenderMaxIntervalNs)

        defer {
            previousReading = reading
            previousJitter = jitter
            previousTime = now
        }
        guard let before = previousReading, let jitterBefore = previousJitter, let then = previousTime else {
            return snapshot
        }
        let seconds = now - then
        guard seconds > 0 else { return snapshot }
        // A counter that went backwards (statistics reset, engine recreated) counts as a fresh start.
        func rate(_ new: Int, _ old: Int) -> Double { Double(new >= old ? new - old : new) / seconds }

        let callbacks = reading.captureCallbacks >= before.captureCallbacks
            ? reading.captureCallbacks - before.captureCallbacks : reading.captureCallbacks
        let frames = reading.captureFrames >= before.captureFrames
            ? reading.captureFrames - before.captureFrames : reading.captureFrames
        snapshot.captureCallbacksPerSecond = rate(reading.captureCallbacks, before.captureCallbacks)
        snapshot.captureFramesPerCallbackAverage = callbacks > 0 ? Double(frames) / Double(callbacks) : 0
        snapshot.captureOverrunSamplesPerSecond = rate(reading.captureOverrunSamples, before.captureOverrunSamples)
        snapshot.framesDeliveredPerSecond = rate(reading.deliveredFrames, before.deliveredFrames)
        let lagCount = reading.deliveryLagCount >= before.deliveryLagCount
            ? reading.deliveryLagCount - before.deliveryLagCount : reading.deliveryLagCount
        let lagSum = reading.deliveryLagSumNs >= before.deliveryLagSumNs
            ? reading.deliveryLagSumNs - before.deliveryLagSumNs : reading.deliveryLagSumNs
        snapshot.deliveryLagAverageMs = lagCount > 0 ? Double(lagSum) / Double(lagCount) / 1_000_000 : 0
        snapshot.renderCallbacksPerSecond = rate(reading.renderCallbacks, before.renderCallbacks)
        snapshot.renderEarlyReturnsPerSecond = rate(reading.renderEarlyReturns, before.renderEarlyReturns)

        snapshot.underrunsPerSecond = rate(jitter.underruns, jitterBefore.underruns)
        snapshot.concealedPerSecond = rate(jitter.concealed, jitterBefore.concealed)
        snapshot.latePerSecond = rate(jitter.lateDropped + jitter.overflowDropped,
                                      jitterBefore.lateDropped + jitterBefore.overflowDropped)
        snapshot.trimmedPerSecond = rate(jitter.trimmed, jitterBefore.trimmed)
        snapshot.lockMissesPerSecond = rate(jitter.renderLockMisses, jitterBefore.renderLockMisses)
        return snapshot
    }

    private static func ms(_ nanoseconds: Int?) -> Double {
        Double(nanoseconds ?? 0) / 1_000_000
    }
}
