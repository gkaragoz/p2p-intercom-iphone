import Foundation

/// Reorders, de-jitters and conceals losses for a stream of `AudioPacket`s.
///
/// Network side calls `push(_:)` from any thread; the audio render callback calls
/// `pull(into:)`. Both are serialized with a lock that is only held for a few microseconds and
/// never while allocating. Frame storage is recycled through a small pool so the steady-state
/// pull path neither allocates nor frees memory on the audio thread.
///
/// Behaviour:
/// * The stream starts in `.buffering` and only begins playing once `targetDelayFrames`
///   frames have accumulated. That prebuffer is the playout delay that absorbs jitter.
/// * Packets that arrive out of order are put back in sequence.
/// * A missing packet is concealed with silence as soon as a later packet is needed,
///   so one lost packet costs 20 ms of silence rather than a stall.
/// * If more than `maxDelayFrames` pile up (the network delivered a burst) the oldest
///   frames are dropped so latency does not grow without bound.
/// * If the buffer stays consistently deeper than the target, one frame is trimmed every
///   so often to creep latency back down.
/// * A sequence jump larger than `resyncDistance` (peer app restarted, or a very long gap)
///   restarts the stream from the new sequence number.
final class JitterBuffer {
    struct Configuration: Equatable {
        /// Samples per packet.
        var frameSize: Int = IntercomProtocol.frameSamples
        /// Frames to accumulate before playout starts (each frame is 20 ms).
        var targetDelayFrames: Int = 3
        /// Hard cap on queued frames; older frames are dropped beyond this.
        var maxDelayFrames: Int = 12
        /// How many consecutive pulls the queue may stay `targetDelayFrames + 2` deep before one frame is trimmed.
        var trimPatiencePulls: Int = 50
        /// Sequence jumps beyond this (in either direction) restart the stream.
        var resyncDistance: Int = 200

        static let `default` = Configuration()

        /// Returns a copy with every field clamped to a sane range.
        func normalized() -> Configuration {
            var copy = self
            copy.frameSize = min(max(1, copy.frameSize), AudioPacket.maxSamples)
            copy.targetDelayFrames = min(max(1, copy.targetDelayFrames), 500)
            copy.maxDelayFrames = min(max(copy.targetDelayFrames + 2, copy.maxDelayFrames), 1_000)
            copy.trimPatiencePulls = min(max(1, copy.trimPatiencePulls), 100_000)
            copy.resyncDistance = min(max(copy.maxDelayFrames + 1, copy.resyncDistance), 30_000)
            return copy
        }
    }

    enum State: Equatable {
        case idle
        case buffering
        case playing
    }

    struct Statistics: Equatable {
        var received = 0
        var played = 0
        var concealed = 0
        var lateDropped = 0
        var overflowDropped = 0
        var trimmed = 0
        var duplicates = 0
        var underruns = 0
        var resyncs = 0
        var bufferedFrames = 0
        var state: State = .idle
    }

    private struct PendingFrame {
        let sequence: UInt16
        let samples: [Int16]
    }

    private let lock = NSLock()
    private var config: Configuration
    private var pending: [PendingFrame] = []
    /// Recycled sample arrays, so consuming a frame on the audio thread does not free memory.
    private var pool: [[Int16]] = []
    private var ring: SampleRingBuffer
    private var nextSequence: UInt16 = 0
    private var state: State = .idle
    private var stats = Statistics()
    private var excessPulls = 0

    init(configuration: Configuration = .default) {
        let normalized = configuration.normalized()
        config = normalized
        ring = SampleRingBuffer(capacity: Self.ringCapacity(for: normalized))
        pending.reserveCapacity(Self.poolLimit(for: normalized))
        pool.reserveCapacity(Self.poolLimit(for: normalized))
    }

    private static func ringCapacity(for config: Configuration) -> Int {
        // Enough for the deepest queue plus the largest render request we expect.
        (config.maxDelayFrames + 2) * config.frameSize + 8192
    }

    private static func poolLimit(for config: Configuration) -> Int {
        config.maxDelayFrames + 4
    }

    var configuration: Configuration {
        get {
            lock.lock()
            defer { lock.unlock() }
            return config
        }
        set {
            let normalized = newValue.normalized()
            let needed = Self.ringCapacity(for: normalized)
            lock.lock()
            let currentCapacity = ring.capacity
            lock.unlock()
            // Allocate outside the lock so the audio thread never waits on malloc.
            let replacement = currentCapacity < needed ? SampleRingBuffer(capacity: needed) : nil
            var spare: [PendingFrame] = []
            spare.reserveCapacity(Self.poolLimit(for: normalized))
            var sparePool: [[Int16]] = []
            sparePool.reserveCapacity(Self.poolLimit(for: normalized))

            lock.lock()
            defer { lock.unlock() }
            guard normalized != config else { return }
            config = normalized
            if let replacement {
                ring = replacement
                pending = spare
                pool = sparePool
                if state == .playing { state = .buffering }
            }
        }
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = stats
        snapshot.bufferedFrames = pending.count
        snapshot.state = state
        return snapshot
    }

    var currentState: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Forgets all queued audio and statistics.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        while let frame = pending.popLast() {
            recycle(frame.samples)
        }
        ring.removeAll()
        state = .idle
        stats = Statistics()
        excessPulls = 0
    }

    func push(_ packet: AudioPacket) {
        lock.lock()
        defer { lock.unlock() }
        stats.received += 1

        if state == .idle {
            beginStream(at: packet.sequence)
        }

        var distance = SequenceNumber.distance(from: nextSequence, to: packet.sequence)
        if distance < -config.resyncDistance || distance > config.resyncDistance {
            stats.resyncs += 1
            beginStream(at: packet.sequence)
            distance = 0
        }

        if distance < 0 {
            stats.lateDropped += 1
            return
        }

        if pending.contains(where: { $0.sequence == packet.sequence }) {
            stats.duplicates += 1
            return
        }

        var storage = pool.popLast() ?? []
        storage.removeAll(keepingCapacity: true)
        storage.append(contentsOf: packet.samples)
        let frame = PendingFrame(sequence: packet.sequence, samples: storage)
        let insertAt = pending.firstIndex { SequenceNumber.distance(from: nextSequence, to: $0.sequence) > distance } ?? pending.count
        pending.insert(frame, at: insertAt)

        while pending.count > config.maxDelayFrames {
            let dropped = pending.removeFirst()
            recycle(dropped.samples)
            stats.overflowDropped += 1
            nextSequence = dropped.sequence &+ 1
        }

        if state == .buffering, pending.count >= config.targetDelayFrames {
            state = .playing
        }
    }

    /// Fills `output` with audio and returns how many of the samples are real audio;
    /// the remainder (if any) is silence.
    @discardableResult
    func pull(into output: UnsafeMutableBufferPointer<Int16>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let requested = output.count
        guard requested > 0 else { return 0 }

        guard state == .playing else {
            fillSilence(output, from: 0)
            return 0
        }

        while ring.count < requested, let first = pending.first {
            let distance = SequenceNumber.distance(from: nextSequence, to: first.sequence)
            if distance == 0 {
                ring.write(first.samples)
                recycle(pending.removeFirst().samples)
                stats.played += 1
            } else if distance > 0 {
                // The frame we need is missing but a later one is queued: conceal it rather than stall.
                ring.writeSilence(config.frameSize)
                stats.concealed += 1
            } else {
                recycle(pending.removeFirst().samples)
                stats.lateDropped += 1
                continue
            }
            nextSequence &+= 1
        }

        let real = ring.read(into: output)
        if real < requested {
            fillSilence(output, from: real)
            stats.underruns += 1
            state = .buffering
            excessPulls = 0
        } else {
            trimIfPersistentlyDeep()
        }
        return real
    }

    /// Convenience for tests.
    func pull(count: Int) -> [Int16] {
        var result = [Int16](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { _ = self.pull(into: $0) }
        return result
    }

    // MARK: - Private

    private func beginStream(at sequence: UInt16) {
        while let frame = pending.popLast() {
            recycle(frame.samples)
        }
        ring.removeAll()
        nextSequence = sequence
        state = .buffering
        excessPulls = 0
    }

    private func trimIfPersistentlyDeep() {
        if pending.count > config.targetDelayFrames + 2 {
            excessPulls += 1
            if excessPulls >= config.trimPatiencePulls {
                let dropped = pending.removeFirst()
                recycle(dropped.samples)
                nextSequence = dropped.sequence &+ 1
                stats.trimmed += 1
                excessPulls = 0
            }
        } else {
            excessPulls = 0
        }
    }

    /// Keeps a consumed frame's storage for reuse instead of freeing it (bounded by the pool limit).
    private func recycle(_ samples: [Int16]) {
        if pool.count < Self.poolLimit(for: config) {
            pool.append(samples)
        }
    }

    private func fillSilence(_ output: UnsafeMutableBufferPointer<Int16>, from start: Int) {
        guard start < output.count else { return }
        for index in start..<output.count {
            output[index] = 0
        }
    }
}
