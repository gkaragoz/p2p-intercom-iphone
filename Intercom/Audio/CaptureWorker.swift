import AVFoundation
import Foundation
import os
import Synchronization

/// Everything the capture worker needs for one input format: the ring the capture callback fills,
/// and a converter with its buffers, all created up front on the engine queue.
///
/// Handed to the worker once (`CaptureWorker.setSource`) and then used only by the worker thread.
final class CaptureSource: @unchecked Sendable {
    let ring: CaptureRing
    /// The rate the converter produces; sets the frame size the worker re-blocks into.
    let wireRate: WireRate
    fileprivate let converter: AVAudioConverter
    fileprivate let input: AVAudioPCMBuffer
    fileprivate let output: AVAudioPCMBuffer

    /// Worker samples per conversion round.
    private static let chunkFrames: AVAudioFrameCount = 4_096

    /// Samples per 20 ms frame at `wireRate`.
    var frameSamples: Int { wireRate.frameSamples }

    init(sampleRate: Double, wireRate: WireRate, wireFormat: AVAudioFormat, counters: AudioMetricsCounters) throws {
        guard sampleRate > 0,
              let monoFloat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFloat, to: wireFormat),
              let input = AVAudioPCMBuffer(pcmFormat: monoFloat, frameCapacity: Self.chunkFrames) else {
            throw AudioEngineError.converterUnavailable
        }
        let ratio = wireFormat.sampleRate / sampleRate
        let outputCapacity = AVAudioFrameCount((Double(Self.chunkFrames) * ratio).rounded(.up)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: outputCapacity) else {
            throw AudioEngineError.converterUnavailable
        }
        ring = CaptureRing(sampleRate: sampleRate, counters: counters)
        self.wireRate = wireRate
        self.converter = converter
        self.input = input
        self.output = output
    }
}

/// Turns captured hardware-rate samples into 20 ms wire frames on a dedicated thread.
///
/// The real-time capture callback only copies samples into a `CaptureRing`. This worker polls the
/// ring every `pollInterval` (polling instead of being woken keeps the real-time thread free of
/// semaphores and dispatch calls, at a cost of 0–5 ms), converts with a reused `AVAudioConverter`
/// (not real-time safe, so it must never run in the callback), re-blocks into frames of the
/// source's wire rate, optionally runs them through a `VoiceEffectProcessor` (the transmit effect
/// and microphone EQ the peer hears) and hands them to `onFrame`, which gates and sends them.
/// Allocation and locks are fine here.
///
/// The level passed to `onFrame` is measured on the *raw* frame, before the processor, so the
/// voice-activation threshold and the input meter mean the same whatever effect is on.
final class CaptureWorker: @unchecked Sendable {
    typealias FrameHandler = @Sendable (_ samples: [Int16], _ levelDB: Float) -> Void

    static let pollInterval: useconds_t = 5_000

    private let counters: AudioMetricsCounters
    private let isRunning = Atomic<Bool>(false)
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var pendingSource: CaptureSource?
    private var sourceGeneration = 0
    private var pendingProcessor: VoiceEffectProcessor?
    private var processorGeneration = 0
    private var handler: FrameHandler?
    private var thread: Thread?
    private var exited: DispatchSemaphore?
    private static let log = Logger(subsystem: "intercom", category: "audio.capture")

    init(counters: AudioMetricsCounters) {
        self.counters = counters
    }

    var onFrame: FrameHandler? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    /// Makes the worker read from `source` (or nothing). Samples still queued in the previous
    /// source are discarded together with the partial frame.
    func setSource(_ source: CaptureSource?) {
        lock.withLock {
            pendingSource = source
            sourceGeneration &+= 1
        }
    }

    /// Makes the worker run every frame through `processor` (or none) from the next frame on. The
    /// previous processor is released on the worker thread, which is fine: its teardown is not
    /// real-time work and the worker is not a real-time thread.
    func setProcessor(_ processor: VoiceEffectProcessor?) {
        lock.withLock {
            pendingProcessor = processor
            processorGeneration &+= 1
        }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        isRunning.store(true, ordering: .relaxed)
        let exited = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            run()
            exited.signal()
        }
        thread.name = "intercom.audio.capture"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        self.exited = exited
        thread.start()
    }

    /// Stops the thread and waits until it has delivered its last frame, so nothing reaches
    /// `onFrame` after this returns.
    func stop() {
        lock.lock()
        let exited = self.exited
        let wasRunning = thread != nil
        thread = nil
        self.exited = nil
        lock.unlock()
        guard wasRunning else { return }
        isRunning.store(false, ordering: .relaxed)
        exited?.wait()
    }

    // MARK: Worker thread

    private func run() {
        var source: CaptureSource?
        var generation = -1
        var processor: VoiceEffectProcessor?
        var effectGeneration = -1
        var chunker = FrameChunker(frameSize: IntercomProtocol.frameSamples)
        var loggedConversionError = false
        let feed = ConverterFeed()

        while isRunning.load(ordering: .relaxed) {
            autoreleasepool {
                lock.lock()
                if generation != sourceGeneration {
                    generation = sourceGeneration
                    source = pendingSource
                    // A new wire rate means a new frame size; the partial frame of the old source
                    // is dropped either way (it was captured before the rebuild).
                    if let source, source.frameSamples != chunker.frameSize {
                        chunker = FrameChunker(frameSize: source.frameSamples)
                    } else {
                        chunker.reset()
                    }
                    source?.converter.reset()
                    loggedConversionError = false
                }
                if effectGeneration != processorGeneration {
                    effectGeneration = processorGeneration
                    processor = pendingProcessor
                }
                let handler = self.handler
                lock.unlock()

                guard let source else { return }
                while true {
                    guard let inputChannel = source.input.floatChannelData?[0] else { return }
                    let count = source.ring.read(into: inputChannel, maxCount: Int(source.input.frameCapacity))
                    guard count > 0 else { break }
                    source.input.frameLength = AVAudioFrameCount(count)

                    let now = HostTime.now()
                    source.ring.consumeStamps { stamp in
                        guard stamp.hostTime != 0 else { return }
                        // From the callback's first sample: includes the capture buffer itself, so a
                        // tap delivering 100 ms chunks shows up as ~100 ms here.
                        let lag = now > stamp.hostTime ? HostTime.nanoseconds(fromTicks: now - stamp.hostTime) : 0
                        counters.deliveryLagSumNs.add(lag, ordering: .relaxed)
                        counters.deliveryLagCount.add(1, ordering: .relaxed)
                        atomicRaise(counters.deliveryLagMaxNs, to: lag)
                    }

                    source.output.frameLength = 0
                    feed.buffer = source.input
                    var error: NSError?
                    let status = source.converter.convert(to: source.output, error: &error) { _, inputStatus in
                        guard let buffer = feed.buffer else {
                            inputStatus.pointee = .noDataNow
                            return nil
                        }
                        feed.buffer = nil
                        inputStatus.pointee = .haveData
                        return buffer
                    }
                    feed.buffer = nil
                    if status == .error {
                        if !loggedConversionError {
                            loggedConversionError = true
                            Self.log.error("capture conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                        }
                        continue
                    }
                    guard source.output.frameLength > 0, let channel = source.output.int16ChannelData?[0] else { continue }
                    let frames = chunker.append(UnsafeBufferPointer(start: channel, count: Int(source.output.frameLength)))
                    guard !frames.isEmpty else { continue }
                    counters.deliveredFrames.add(frames.count, ordering: .relaxed)
                    guard let handler else { continue }
                    for frame in frames {
                        // Level from the raw frame: VOX and the meter must not follow the effect.
                        let levelDB = AudioLevel.decibels(fromLinear: AudioLevel.rms(frame))
                        var out = frame
                        if let processor, processor.frameSamples == frame.count {
                            out = processor.process(frame)
                            if out.count != frame.count {
                                // Contract violation; the raw frame keeps the stream whole.
                                out = frame
                            }
                        }
                        handler(out, levelDB)
                    }
                }
            }
            usleep(Self.pollInterval)
        }
    }
}

/// Hands one input buffer to `AVAudioConverter`'s pull block per conversion round; reused so the
/// block does not capture a fresh mutable box every time.
private final class ConverterFeed: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer?
}
