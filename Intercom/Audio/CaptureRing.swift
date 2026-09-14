import CoreAudio
import Foundation
import Synchronization

/// Single-producer, single-consumer FIFO of mono Float32 capture samples, plus a small FIFO of
/// per-callback time stamps.
///
/// The producer is the real-time capture callback (`AVAudioSinkNode`) or, in compatible mode, the
/// tap callback; the consumer is `CaptureWorker`. Real-time rules on the producer side: storage is
/// allocated once in `init`, positions are `Atomic`s that only one side writes (the producer
/// advances `written`, the consumer advances `consumed`), and `write` does nothing but copy
/// samples and update counters: no locks, no allocation, no Objective-C or Swift runtime calls.
///
/// Positions are absolute sample counts (they never wrap; 2^63 samples is millions of years), so
/// `written - consumed` is the fill level and a stamp's `endPosition` identifies its samples.
final class CaptureRing: @unchecked Sendable {
    struct Stamp {
        /// Absolute position just past the callback's last sample.
        var endPosition: Int
        var frames: Int
        /// `mach_absolute_time` of the callback's first sample; 0 when unknown.
        var hostTime: UInt64
    }

    let sampleRate: Double
    let capacity: Int
    private let mask: Int
    private let samples: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    private static let stampCapacity = 256
    private let stamps: UnsafeMutablePointer<Stamp>
    private let stampsWritten = Atomic<Int>(0)
    private let stampsConsumed = Atomic<Int>(0)

    /// Producer-only scratch: host time of the previous callback.
    private let previousHostTime: UnsafeMutablePointer<UInt64>
    private let counters: AudioMetricsCounters

    /// - Parameter seconds: capacity; rounded up to a power of two samples.
    init(sampleRate: Double, seconds: Double = 1, counters: AudioMetricsCounters) {
        self.sampleRate = sampleRate
        self.counters = counters
        let wanted = max(4_096, Int((sampleRate * seconds).rounded(.up)))
        var size = 1
        while size < wanted { size <<= 1 }
        capacity = size
        mask = size - 1
        samples = UnsafeMutablePointer<Float>.allocate(capacity: size)
        samples.initialize(repeating: 0, count: size)
        stamps = UnsafeMutablePointer<Stamp>.allocate(capacity: Self.stampCapacity)
        stamps.initialize(repeating: Stamp(endPosition: 0, frames: 0, hostTime: 0), count: Self.stampCapacity)
        previousHostTime = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        previousHostTime.initialize(to: 0)
    }

    deinit {
        samples.deinitialize(count: capacity)
        samples.deallocate()
        stamps.deinitialize(count: Self.stampCapacity)
        stamps.deallocate()
        previousHostTime.deinitialize(count: 1)
        previousHostTime.deallocate()
    }

    // MARK: Producer (real-time)

    /// Copies channel 0 of `bufferList` (Float32; one buffer per channel, or interleaved channels in
    /// the first buffer). Samples that do not fit are dropped and counted as overruns.
    @inline(__always)
    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int, hostTime: UInt64) {
        counters.captureCallbacks.add(1, ordering: .relaxed)
        atomicLower(counters.captureFramesMin, to: frameCount)
        atomicRaise(counters.captureFramesMax, to: frameCount)
        if hostTime != 0 {
            let previous = previousHostTime.pointee
            if previous != 0, hostTime > previous {
                atomicRaise(counters.captureMaxIntervalTicks, to: hostTime - previous)
            }
            previousHostTime.pointee = hostTime
        }

        guard frameCount > 0, bufferList.pointee.mNumberBuffers > 0 else { return }
        let buffer = bufferList.pointee.mBuffers
        guard let data = buffer.mData else { return }
        let stride = max(1, Int(buffer.mNumberChannels))
        let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
        let incoming = min(frameCount, available)
        guard incoming > 0 else { return }
        counters.captureFrames.add(incoming, ordering: .relaxed)

        let source = data.assumingMemoryBound(to: Float.self)
        let start = written.load(ordering: .relaxed)
        let fill = start - consumed.load(ordering: .relaxed)
        let count = min(incoming, capacity - fill)
        if count < incoming {
            counters.captureOverrunSamples.add(incoming - count, ordering: .relaxed)
        }
        guard count > 0 else { return }

        if stride == 1 {
            let offset = start & mask
            let first = min(count, capacity - offset)
            (samples + offset).update(from: source, count: first)
            if first < count {
                samples.update(from: source + first, count: count - first)
            }
        } else {
            for index in 0..<count {
                samples[(start + index) & mask] = source[index * stride]
            }
        }
        let end = start + count
        written.store(end, ordering: .relaxed)

        let stampIndex = stampsWritten.load(ordering: .relaxed)
        if stampIndex - stampsConsumed.load(ordering: .relaxed) < Self.stampCapacity {
            stamps[stampIndex & (Self.stampCapacity - 1)] = Stamp(endPosition: end, frames: count, hostTime: hostTime)
            stampsWritten.store(stampIndex + 1, ordering: .relaxed)
        }
    }

    // MARK: Consumer (capture worker)

    /// Moves up to `maxCount` samples into `destination`; returns how many.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let start = consumed.load(ordering: .relaxed)
        let count = min(maxCount, written.load(ordering: .relaxed) - start)
        guard count > 0 else { return 0 }
        let offset = start & mask
        let first = min(count, capacity - offset)
        destination.update(from: samples + offset, count: first)
        if first < count {
            (destination + first).update(from: samples, count: count - first)
        }
        consumed.store(start + count, ordering: .relaxed)
        return count
    }

    /// Absolute position of the next sample `read` will return.
    var readPosition: Int {
        consumed.load(ordering: .relaxed)
    }

    /// Calls `body` for every stamp whose samples have all been read, oldest first.
    func consumeStamps(_ body: (Stamp) -> Void) {
        let limit = consumed.load(ordering: .relaxed)
        var index = stampsConsumed.load(ordering: .relaxed)
        let end = stampsWritten.load(ordering: .relaxed)
        while index < end {
            let stamp = stamps[index & (Self.stampCapacity - 1)]
            guard stamp.endPosition <= limit else { break }
            body(stamp)
            index += 1
        }
        stampsConsumed.store(index, ordering: .relaxed)
    }
}
