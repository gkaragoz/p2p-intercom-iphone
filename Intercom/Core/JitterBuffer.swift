import Foundation

/// Reorders, de-jitters and conceals losses for a stream of `AudioPacket`s, and keeps the playout
/// delay close to a target without letting hiccups ratchet it up.
///
/// Threads: the network side calls `push(_:arrival:)` from any thread; the audio render callback
/// calls `pull(into:)` (never concurrently with itself). `statistics`, `configuration` and `reset()`
/// may be used from any thread.
///
/// Real-time safety of `pull(into:)`:
/// * It only ever `tryLock`s. If the lock is contended (after a short bounded spin) it outputs
///   silence for that cycle and counts a `renderLockMisses` statistic; it never waits.
/// * Frames live in one preallocated sample slab with fixed-size slots, a free list and an index
///   deque, all raw pointers: neither side allocates, frees or touches reference counts per packet.
///   `push` copies a packet into a free slot while holding the lock (a few hundred bytes).
/// * A configuration change that needs more slots allocates the new slab before taking the lock
///   and frees the old one after releasing it, on the caller's thread.
///
/// Behaviour:
/// * The stream starts in `.buffering` and begins playing once the queued audio reaches the
///   target (fixed: `targetDelayFrames`; adaptive: `PlayoutDelayEstimator`). An underrun goes
///   back to `.buffering` and re-buffers to the current target. Frames that never reach the
///   target (a spurt shorter than the target, or the tail after an underrun) start playing once
///   the render side has pulled a target's worth of silence with no new packet: they come out one
///   target late instead of sitting in the queue until the next transmission pushes them out
///   ahead of its own speech.
/// * Out-of-order packets are put back in sequence; a missing packet is concealed with silence as
///   soon as a later one is needed. Frames missing at the moment playout *resumes* are skipped, not
///   concealed: inserting silence there would only add latency (the end-of-burst loss ratchet).
/// * Latency trimming is time based (measured in samples played, so it behaves the same for any
///   IO buffer size). After every push of a newest packet the buffer computes the depth that packet
///   would have found had it arrived on time (`depth + its measured extra delay`). While that value
///   has stayed at least one frame above the target for `trimPatienceMs`, silent (or lost) frames
///   are dropped as they reach the head. Voiced frames are dropped only while the excess has been at
///   least two frames for `voicedTrimPatienceMs`, at most one per `voicedTrimSpacingMs`, with a short
///   crossfade into the following frame so the join does not click.
/// * The queue never spans more than `maxDelayFrames`; older frames are dropped beyond that.
/// * A sequence jump larger than `resyncDistance` (peer restarted) restarts the stream.
final class JitterBuffer {
    struct Configuration: Equatable {
        /// Samples per packet.
        var frameSize: Int = IntercomProtocol.frameSamples
        /// Sample rate of the stream; converts the millisecond settings into samples.
        var sampleRate: Int = Int(IntercomProtocol.sampleRate)
        /// Fixed playout target in frames, used unless `adaptiveTarget` is on.
        var targetDelayFrames: Int = 3
        /// Follow `PlayoutDelayEstimator.targetMs` instead of `targetDelayFrames`.
        var adaptiveTarget = false
        /// Settings of the adaptive estimator (its frame size and sample rate follow this configuration).
        var playoutDelay = PlayoutDelayEstimator.Configuration()
        /// Hard cap on the span of queued frames; older frames are dropped beyond this.
        var maxDelayFrames: Int = 12
        /// How long the queue must stay at least one frame too deep before silent frames are dropped.
        var trimPatienceMs: Int = 500
        /// How long the queue must stay at least two frames too deep before voiced frames are dropped.
        var voicedTrimPatienceMs: Int = 1_000
        /// Minimum spacing between two voiced-frame drops.
        var voicedTrimSpacingMs: Int = 200
        /// Frames whose RMS level is below this (dBFS) count as silence and are dropped first.
        var silenceThresholdDB: Float = -50
        /// Length of the crossfade from a dropped voiced frame into the next one (40 = 2.5 ms at 16 kHz).
        var crossfadeSamples: Int = 40
        /// Sequence jumps beyond this (in either direction) restart the stream.
        var resyncDistance: Int = 200

        static let `default` = Configuration()

        /// Returns a copy with every field clamped to a sane range.
        func normalized() -> Configuration {
            var copy = self
            copy.frameSize = min(max(1, copy.frameSize), AudioPacket.maxSamples)
            copy.sampleRate = min(max(1, copy.sampleRate), 384_000)
            copy.playoutDelay.frameSamples = copy.frameSize
            copy.playoutDelay.sampleRate = copy.sampleRate
            copy.playoutDelay = copy.playoutDelay.normalized()
            copy.targetDelayFrames = min(max(1, copy.targetDelayFrames), 500)
            var minimumMax = copy.targetDelayFrames + 2
            if copy.adaptiveTarget {
                let ceilingFrames = Int((copy.playoutDelay.ceilingMs / copy.playoutDelay.frameMs).rounded(.up))
                minimumMax = max(minimumMax, min(ceilingFrames, 998) + 2)
            }
            copy.maxDelayFrames = min(max(minimumMax, copy.maxDelayFrames), 1_000)
            copy.trimPatienceMs = min(max(0, copy.trimPatienceMs), 60_000)
            copy.voicedTrimPatienceMs = min(max(0, copy.voicedTrimPatienceMs), 60_000)
            copy.voicedTrimSpacingMs = min(max(0, copy.voicedTrimSpacingMs), 60_000)
            copy.silenceThresholdDB = copy.silenceThresholdDB.isFinite ? min(max(-100, copy.silenceThresholdDB), 0) : -50
            copy.crossfadeSamples = min(max(0, copy.crossfadeSamples), copy.frameSize)
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
        /// Frames dropped to bring the delay back to the target (silent and voiced).
        var trimmed = 0
        /// The part of `trimmed` that was silent or lost audio, i.e. inaudible.
        var silenceTrimmed = 0
        var duplicates = 0
        var underruns = 0
        var resyncs = 0
        /// Missing frames skipped (instead of concealed) when playout resumed.
        var skippedOnResume = 0
        /// Render pulls answered with silence because the lock was contended.
        var renderLockMisses = 0
        var bufferedFrames = 0
        var state: State = .idle
        /// Current playout target.
        var targetDelayMs = 0
        /// Audio currently queued ahead of the playout position.
        var depthMs = 0
        /// Extra network delay the adaptive estimator currently covers.
        var jitterMs = 0
    }

    /// `tryLock` attempts in `pull` before giving up on a cycle.
    private static let renderLockSpins = 100

    private struct Slot {
        var sequence: UInt16 = 0
        var count = 0
        var levelDB: Float = -100
    }

    /// Fixed-size frame storage. Plain pointers, so moving it around never retains or releases.
    private struct Storage {
        let slotCapacity: Int
        let frameSize: Int
        let samples: UnsafeMutablePointer<Int16>
        let slots: UnsafeMutablePointer<Slot>
        /// Stack of free slot indices.
        let freeList: UnsafeMutablePointer<Int>
        /// Circular deque of pending slot indices, ordered by sequence.
        let order: UnsafeMutablePointer<Int>

        static func allocate(slotCapacity: Int, frameSize: Int) -> Storage {
            let samples = UnsafeMutablePointer<Int16>.allocate(capacity: slotCapacity * frameSize)
            samples.initialize(repeating: 0, count: slotCapacity * frameSize)
            let slots = UnsafeMutablePointer<Slot>.allocate(capacity: slotCapacity)
            slots.initialize(repeating: Slot(), count: slotCapacity)
            let freeList = UnsafeMutablePointer<Int>.allocate(capacity: slotCapacity)
            freeList.initialize(repeating: 0, count: slotCapacity)
            let order = UnsafeMutablePointer<Int>.allocate(capacity: slotCapacity)
            order.initialize(repeating: 0, count: slotCapacity)
            return Storage(slotCapacity: slotCapacity, frameSize: frameSize, samples: samples,
                           slots: slots, freeList: freeList, order: order)
        }

        func deallocate() {
            samples.deinitialize(count: slotCapacity * frameSize)
            samples.deallocate()
            slots.deinitialize(count: slotCapacity)
            slots.deallocate()
            freeList.deinitialize(count: slotCapacity)
            freeList.deallocate()
            order.deinitialize(count: slotCapacity)
            order.deallocate()
        }
    }

    /// Tracks how long the on-time depth has continuously stayed at least `requiredExcess` above
    /// the target, and the lowest such depth, i.e. a running "minimum depth over the window".
    ///
    /// Comparisons allow `tolerance` samples of slack: the on-time depth adds a measured delay
    /// whose anchor drifts by a few hundredths of a millisecond per packet, so an excess of exactly
    /// one frame reads a sample or two short.
    private struct ExcessRun {
        var elapsed = 0
        var minDepth = Int.max
        var tolerance = 0

        var isActive: Bool { minDepth != .max }

        mutating func observe(depth: Int, target: Int, requiredExcess: Int) {
            if depth - target >= requiredExcess - tolerance {
                minDepth = min(minDepth, depth)
            } else {
                reset()
            }
        }

        mutating func advance(by samples: Int) {
            guard isActive else { return }
            elapsed = min(elapsed + samples, Int.max / 4)
        }

        /// A frame was removed, so every depth measured during the run is one frame lower now.
        mutating func frameRemoved(frameSize: Int, target: Int, requiredExcess: Int) {
            guard isActive else { return }
            minDepth -= frameSize
            if minDepth - target < requiredExcess - tolerance { reset() }
        }

        func allows(target: Int, requiredExcess: Int, patience: Int) -> Bool {
            isActive && elapsed >= patience && minDepth - target >= requiredExcess - tolerance
        }

        mutating func reset() {
            elapsed = 0
            minDepth = .max
        }
    }

    // Lock order: `pushLock` before `lock`. `pull` takes only `lock` (and only with tryLock).
    /// Guards all state below except `estimator` and `unreportedLockMisses`.
    private let lock = UnfairLock()
    /// Serializes writers (push, reset, configuration) and guards `estimator`, so the estimator's
    /// work happens outside the lock the render thread needs. Writers hold both locks while
    /// changing `config` or `storage`, so either lock is enough to read those two.
    private let pushLock = UnfairLock()

    private var config: Configuration
    private var storage: Storage
    private var freeCount = 0
    private var orderHead = 0
    private var pendingCount = 0

    /// Slot being played, or -1 while playing concealment silence.
    private var currentSlot = -1
    private var currentOffset = 0
    private var currentLength = 0

    private var nextSequence: UInt16 = 0
    private var state: State = .idle
    private var stats = Statistics()
    private var targetSamples = 0
    private var trimPatienceSamples = 0
    private var voicedTrimPatienceSamples = 0
    private var voicedTrimSpacingSamples = 0
    private var silentRun = ExcessRun()
    private var voicedRun = ExcessRun()
    private var samplesSinceVoicedTrim = Int.max / 4
    /// Samples pulled while `.buffering` since the last packet was queued; once it reaches the
    /// target, whatever is queued starts playing even though it is short of the target.
    private var bufferingIdleSamples = 0
    private var pullWindowElapsed = 0
    private var pullWindowMax = 0
    private var previousPullWindowMax = 0

    private var estimator: PlayoutDelayEstimator
    /// Written only by the pulling thread when it could not get the lock; folded into `stats` by
    /// the next pull that does.
    private var unreportedLockMisses = 0

    init(configuration: Configuration = .default) {
        let normalized = configuration.normalized()
        config = normalized
        storage = Storage.allocate(slotCapacity: Self.slotCapacity(for: normalized), frameSize: normalized.frameSize)
        estimator = PlayoutDelayEstimator(configuration: normalized.playoutDelay)
        resetSlots()
        applyDerivedSettings()
    }

    deinit {
        storage.deallocate()
    }

    private static func slotCapacity(for config: Configuration) -> Int {
        // The pending span never exceeds maxDelayFrames; plus the frame being played and the one
        // being inserted before the cap is enforced.
        config.maxDelayFrames + 3
    }

    var configuration: Configuration {
        get {
            lock.lock()
            defer { lock.unlock() }
            return config
        }
        set {
            let normalized = newValue.normalized()
            pushLock.lock()
            defer { pushLock.unlock() }
            guard normalized != config else { return }

            // Allocate before taking the lock the render thread needs; free after releasing it.
            let slotsNeeded = Self.slotCapacity(for: normalized)
            let replacement = (slotsNeeded > storage.slotCapacity || normalized.frameSize != storage.frameSize)
                ? Storage.allocate(slotCapacity: slotsNeeded, frameSize: normalized.frameSize)
                : nil
            if normalized.playoutDelay != estimator.configuration {
                let pullQuantum = estimator.pullQuantumMs
                estimator = PlayoutDelayEstimator(configuration: normalized.playoutDelay)
                estimator.pullQuantumMs = pullQuantum
            }

            var retired: Storage?
            lock.lock()
            config = normalized
            if let replacement {
                retired = storage
                storage = replacement
                resetSlots()
                if state != .idle { state = .buffering }
            } else {
                enforceCap()
            }
            applyDerivedSettings()
            silentRun.reset()
            voicedRun.reset()
            lock.unlock()
            retired?.deallocate()
        }
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = stats
        snapshot.bufferedFrames = pendingCount
        snapshot.state = state
        snapshot.targetDelayMs = milliseconds(targetSamples)
        snapshot.depthMs = milliseconds(depthSamples(fromNext: state == .playing))
        return snapshot
    }

    var currentState: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Forgets all queued audio, statistics and delay history.
    func reset() {
        pushLock.lock()
        defer { pushLock.unlock() }
        estimator.reset()
        lock.lock()
        clearFrames()
        state = .idle
        stats = Statistics()
        silentRun.reset()
        voicedRun.reset()
        samplesSinceVoicedTrim = Int.max / 4
        pullWindowElapsed = 0
        pullWindowMax = 0
        previousPullWindowMax = 0
        applyDerivedSettings()
        lock.unlock()
    }

    /// Queues one received packet. `arrival` is when it was received, for the delay estimator.
    func push(_ packet: AudioPacket, arrival: MonotonicTime = .now()) {
        // Level and delay estimate are computed before taking the lock the render thread needs.
        let levelDB = packet.samples.withUnsafeBufferPointer { AudioLevel.decibels(fromLinear: AudioLevel.rms($0)) }
        pushLock.lock()
        defer { pushLock.unlock() }
        let delayMs = estimator.record(sequence: packet.sequence, timestamp: packet.timestamp, arrival: arrival)
        let sampleRate = config.sampleRate
        let delaySamples = Int((delayMs * Double(sampleRate) / 1000).rounded())

        lock.lock()
        pushLocked(packet, levelDB: levelDB, delaySamples: delaySamples)
        let observedPull = max(pullWindowMax, previousPullWindowMax)
        lock.unlock()

        if observedPull > 0 {
            estimator.pullQuantumMs = Double(observedPull) * 1000 / Double(sampleRate)
        }
    }

    /// Fills `output` with audio and returns how many of the samples are real audio (played or
    /// concealed); the remainder, if any, is silence. Real-time safe; see the type documentation.
    @discardableResult
    func pull(into output: UnsafeMutableBufferPointer<Int16>) -> Int {
        guard let base = output.baseAddress, output.count > 0 else { return 0 }
        guard lock.tryLock(spinning: Self.renderLockSpins) else {
            base.update(repeating: 0, count: output.count)
            unreportedLockMisses &+= 1
            return 0
        }
        defer { lock.unlock() }
        return pullLocked(into: base, count: output.count)
    }

    /// Convenience for tests.
    func pull(count: Int) -> [Int16] {
        var result = [Int16](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { _ = self.pull(into: $0) }
        return result
    }

    /// Test hook: runs `body` while holding the lock `pull` needs, so a concurrent pull misses.
    func withStateLockHeldForTesting(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    // MARK: - Push (lock held)

    private func pushLocked(_ packet: AudioPacket, levelDB: Float, delaySamples: Int) {
        stats.received += 1
        stats.jitterMs = Int(estimator.delayMs.rounded())
        targetSamples = computeTargetSamples()

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

        var insertAt = pendingCount
        for index in 0..<pendingCount {
            let sequence = slot(at: index).sequence
            if sequence == packet.sequence {
                stats.duplicates += 1
                return
            }
            if insertAt == pendingCount, SequenceNumber.distance(from: nextSequence, to: sequence) > distance {
                insertAt = index
            }
        }

        guard freeCount > 0 else {
            // Unreachable while the cap holds (capacity exceeds the cap), but never overwrite.
            stats.overflowDropped += 1
            return
        }
        freeCount -= 1
        let slotIndex = storage.freeList[freeCount]
        let count = min(packet.samples.count, storage.frameSize)
        packet.samples.withUnsafeBufferPointer { source in
            if let sourceBase = source.baseAddress, count > 0 {
                (storage.samples + slotIndex * storage.frameSize).update(from: sourceBase, count: count)
            }
        }
        storage.slots[slotIndex] = Slot(sequence: packet.sequence, count: count, levelDB: levelDB)
        let isNewest = insertAt == pendingCount
        insertPending(slotIndex, at: insertAt)
        bufferingIdleSamples = 0

        enforceCap()

        if state == .buffering {
            startPlayoutIfTargetReached()
        } else if state == .playing, isNewest, pendingCount > 0,
                  slot(at: pendingCount - 1).sequence == packet.sequence {
            // The depth this packet would have found had it arrived on time: while playing, the
            // buffer drained for exactly its extra delay before it came in.
            let onTimeDepth = depthSamples(fromNext: true) + delaySamples
            let frame = config.frameSize
            silentRun.observe(depth: onTimeDepth, target: targetSamples, requiredExcess: frame)
            voicedRun.observe(depth: onTimeDepth, target: targetSamples, requiredExcess: 2 * frame)
        }
    }

    private func beginStream(at sequence: UInt16) {
        clearFrames()
        nextSequence = sequence
        state = .buffering
        bufferingIdleSamples = 0
        silentRun.reset()
        voicedRun.reset()
    }

    /// Push side: starts playout once the queued span covers the target.
    private func startPlayoutIfTargetReached() {
        guard pendingCount > 0 else { return }
        let first = slot(at: 0).sequence
        let last = slot(at: pendingCount - 1).sequence
        let span = SequenceNumber.distance(from: first, to: last) + 1
        guard span * config.frameSize >= targetSamples else { return }
        startPlayout()
    }

    /// Starts playing the queue from its head, whatever its depth. Requires `pendingCount > 0`.
    private func startPlayout() {
        let first = slot(at: 0).sequence
        let gap = SequenceNumber.distance(from: nextSequence, to: first)
        if gap > 0 {
            // Lost before playout resumed (typically the last packets of the previous burst).
            // Concealing them now would add their duration to the delay for good.
            stats.skippedOnResume += gap
            nextSequence = first
        }
        state = .playing
        bufferingIdleSamples = 0
        silentRun.reset()
        voicedRun.reset()
    }

    /// Keeps the queued span within `maxDelayFrames`, skipping missing frames before real ones.
    private func enforceCap() {
        let cap = config.maxDelayFrames
        while pendingCount > 0 {
            let last = slot(at: pendingCount - 1).sequence
            let span = SequenceNumber.distance(from: nextSequence, to: last) + 1
            guard span > cap else { return }
            let head = slot(at: 0).sequence
            let gap = SequenceNumber.distance(from: nextSequence, to: head)
            if gap > 0 {
                nextSequence = nextSequence &+ UInt16(truncatingIfNeeded: min(gap, span - cap))
                continue
            }
            let dropped = removeFirstPending()
            nextSequence = storage.slots[dropped].sequence &+ 1
            releaseSlot(dropped)
            stats.overflowDropped += 1
        }
    }

    // MARK: - Pull (lock held)

    private func pullLocked(into output: UnsafeMutablePointer<Int16>, count requested: Int) -> Int {
        if unreportedLockMisses > 0 {
            stats.renderLockMisses += unreportedLockMisses
            unreportedLockMisses = 0
        }
        trackPullSize(requested)

        if state == .buffering, pendingCount > 0, bufferingIdleSamples >= targetSamples {
            // The sender stopped short of the target (a short spurt, or the tail after an
            // underrun) and a whole target has gone by without a packet: play what is queued now.
            // Left in place it would play ahead of the next transmission, seconds or minutes late.
            startPlayout()
        }
        guard state == .playing else {
            if state == .buffering, pendingCount > 0 {
                bufferingIdleSamples = min(bufferingIdleSamples + requested, Int.max / 4)
            }
            output.update(repeating: 0, count: requested)
            return 0
        }

        var written = 0
        while written < requested {
            let remaining = currentLength - currentOffset
            if remaining > 0 {
                let chunk = min(remaining, requested - written)
                if currentSlot >= 0 {
                    let source = storage.samples + currentSlot * storage.frameSize + currentOffset
                    (output + written).update(from: source, count: chunk)
                } else {
                    (output + written).update(repeating: 0, count: chunk)
                }
                currentOffset += chunk
                written += chunk
                continue
            }
            finishCurrentFrame()
            guard beginNextFrame() else { break }
        }

        if written < requested {
            (output + written).update(repeating: 0, count: requested - written)
            stats.underruns += 1
            state = .buffering
            bufferingIdleSamples = 0
            silentRun.reset()
            voicedRun.reset()
        } else {
            silentRun.advance(by: requested)
            voicedRun.advance(by: requested)
            samplesSinceVoicedTrim = min(samplesSinceVoicedTrim + requested, Int.max / 4)
        }
        return written
    }

    /// Makes the next frame current (real, concealed or crossfaded). Returns `false` when the
    /// queue is empty.
    private func beginNextFrame() -> Bool {
        let frame = config.frameSize
        while pendingCount > 0 {
            let headIndex = storage.order[orderHead]
            let head = storage.slots[headIndex]
            let distance = SequenceNumber.distance(from: nextSequence, to: head.sequence)

            if distance < 0 {
                releaseSlot(removeFirstPending())
                stats.lateDropped += 1
                continue
            }

            if distance > 0 {
                // The frame we need is missing but a later one is queued.
                nextSequence &+= 1
                if canTrimSilence() {
                    recordTrim(silent: true)
                    continue
                }
                currentSlot = -1
                currentOffset = 0
                currentLength = frame
                stats.concealed += 1
                return true
            }

            if head.levelDB < config.silenceThresholdDB, canTrimSilence() {
                releaseSlot(removeFirstPending())
                nextSequence &+= 1
                recordTrim(silent: true)
                continue
            }

            if pendingCount >= 2, canTrimVoiced() {
                let followerIndex = storage.order[(orderHead + 1) % storage.slotCapacity]
                if SequenceNumber.distance(from: head.sequence, to: storage.slots[followerIndex].sequence) == 1 {
                    crossfade(from: headIndex, into: followerIndex)
                    releaseSlot(removeFirstPending())
                    nextSequence &+= 1
                    samplesSinceVoicedTrim = 0
                    recordTrim(silent: false)
                    continue
                }
            }

            _ = removeFirstPending()
            nextSequence &+= 1
            stats.played += 1
            guard head.count > 0 else {
                releaseSlot(headIndex)
                continue
            }
            currentSlot = headIndex
            currentOffset = 0
            currentLength = head.count
            return true
        }
        return false
    }

    private func canTrimSilence() -> Bool {
        silentRun.allows(target: targetSamples, requiredExcess: config.frameSize, patience: trimPatienceSamples)
    }

    private func canTrimVoiced() -> Bool {
        samplesSinceVoicedTrim >= voicedTrimSpacingSamples
            && voicedRun.allows(target: targetSamples, requiredExcess: 2 * config.frameSize, patience: voicedTrimPatienceSamples)
    }

    private func recordTrim(silent: Bool) {
        stats.trimmed += 1
        if silent { stats.silenceTrimmed += 1 }
        let frame = config.frameSize
        silentRun.frameRemoved(frameSize: frame, target: targetSamples, requiredExcess: frame)
        voicedRun.frameRemoved(frameSize: frame, target: targetSamples, requiredExcess: 2 * frame)
    }

    /// Blends the start of the dropped frame into the start of its successor: playback continues
    /// from where the dropped frame would have started and lands on the successor within a few ms.
    private func crossfade(from droppedIndex: Int, into followerIndex: Int) {
        let length = min(config.crossfadeSamples, storage.slots[droppedIndex].count, storage.slots[followerIndex].count)
        guard length > 0 else { return }
        let dropped = storage.samples + droppedIndex * storage.frameSize
        let follower = storage.samples + followerIndex * storage.frameSize
        let steps = Float(length + 1)
        for index in 0..<length {
            let weight = Float(index + 1) / steps
            let mixed = Float(dropped[index]) * (1 - weight) + Float(follower[index]) * weight
            follower[index] = Int16(clamping: Int(mixed.rounded()))
        }
    }

    private func finishCurrentFrame() {
        if currentSlot >= 0 {
            releaseSlot(currentSlot)
        }
        currentSlot = -1
        currentOffset = 0
        currentLength = 0
    }

    /// Remembers the largest render request over roughly the last half second to a second; the
    /// estimator's target includes one pull.
    private func trackPullSize(_ requested: Int) {
        pullWindowMax = max(pullWindowMax, requested)
        pullWindowElapsed += requested
        if pullWindowElapsed >= max(1, config.sampleRate / 2) {
            previousPullWindowMax = pullWindowMax
            pullWindowMax = 0
            pullWindowElapsed = 0
        }
    }

    // MARK: - Storage helpers (lock held)

    private func slot(at pendingIndex: Int) -> Slot {
        storage.slots[storage.order[(orderHead + pendingIndex) % storage.slotCapacity]]
    }

    private func insertPending(_ slotIndex: Int, at position: Int) {
        let capacity = storage.slotCapacity
        var index = pendingCount
        while index > position {
            storage.order[(orderHead + index) % capacity] = storage.order[(orderHead + index - 1) % capacity]
            index -= 1
        }
        storage.order[(orderHead + position) % capacity] = slotIndex
        pendingCount += 1
    }

    private func removeFirstPending() -> Int {
        let slotIndex = storage.order[orderHead]
        orderHead = (orderHead + 1) % storage.slotCapacity
        pendingCount -= 1
        return slotIndex
    }

    private func releaseSlot(_ slotIndex: Int) {
        storage.freeList[freeCount] = slotIndex
        freeCount += 1
    }

    private func clearFrames() {
        while pendingCount > 0 {
            releaseSlot(removeFirstPending())
        }
        finishCurrentFrame()
        orderHead = 0
        bufferingIdleSamples = 0
    }

    private func resetSlots() {
        for index in 0..<storage.slotCapacity {
            storage.freeList[index] = storage.slotCapacity - 1 - index
        }
        freeCount = storage.slotCapacity
        orderHead = 0
        pendingCount = 0
        currentSlot = -1
        currentOffset = 0
        currentLength = 0
        bufferingIdleSamples = 0
    }

    /// Audio ahead of the playout position: the rest of the current frame plus the queued span
    /// (lost frames inside it count, they will be played as concealment).
    private func depthSamples(fromNext: Bool) -> Int {
        var depth = max(0, currentLength - currentOffset)
        if pendingCount > 0 {
            let start = fromNext ? nextSequence : slot(at: 0).sequence
            let span = SequenceNumber.distance(from: start, to: slot(at: pendingCount - 1).sequence) + 1
            depth += max(0, span) * config.frameSize
        }
        return depth
    }

    private func computeTargetSamples() -> Int {
        let frame = config.frameSize
        let raw: Int
        if config.adaptiveTarget {
            raw = Int((estimator.targetMs * Double(config.sampleRate) / 1000).rounded())
        } else {
            raw = config.targetDelayFrames * frame
        }
        return min(max(frame, raw), max(frame, (config.maxDelayFrames - 1) * frame))
    }

    private func applyDerivedSettings() {
        let rate = config.sampleRate
        trimPatienceSamples = config.trimPatienceMs * rate / 1000
        voicedTrimPatienceSamples = config.voicedTrimPatienceMs * rate / 1000
        voicedTrimSpacingSamples = config.voicedTrimSpacingMs * rate / 1000
        // 1/16 frame (1.25 ms at 20 ms frames): far below anything audible, well above anchor drift.
        silentRun.tolerance = config.frameSize / 16
        voicedRun.tolerance = config.frameSize / 16
        targetSamples = computeTargetSamples()
    }

    private func milliseconds(_ samples: Int) -> Int {
        samples * 1000 / max(1, config.sampleRate)
    }
}
