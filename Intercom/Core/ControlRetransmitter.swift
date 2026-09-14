import Foundation

/// Reliable delivery for the few control messages that need it, over an unreliable datagram flow.
///
/// Each message gets a sequence number and is resent every `retryInterval` until the peer
/// acknowledges that sequence. Retries pause while there is no link (`due` is simply not called)
/// and resume on the next one, so a message survives a quick reconnect. The queue is bounded:
/// control traffic is tiny and a peer that never acks must not grow memory.
struct ControlRetransmitter<Message> {
    struct Pending {
        let sequence: UInt32
        let message: Message
        fileprivate(set) var lastSentAt: MonotonicTime?
        fileprivate(set) var sendCount: Int
    }

    var retryInterval: TimeInterval
    var maxPending: Int
    private(set) var pending: [Pending] = []
    private var nextSequence: UInt32 = 1
    /// Messages evicted from a full queue before they were acknowledged.
    private(set) var droppedCount = 0

    init(retryInterval: TimeInterval = 0.25, maxPending: Int = 32) {
        self.retryInterval = retryInterval
        self.maxPending = max(1, maxPending)
    }

    /// Queues `message` and returns its sequence number. It is sent by the next `due(at:)`.
    @discardableResult
    mutating func enqueue(_ message: Message) -> UInt32 {
        let sequence = nextSequence
        nextSequence &+= 1
        if nextSequence == 0 { nextSequence = 1 }
        pending.append(Pending(sequence: sequence, message: message, lastSentAt: nil, sendCount: 0))
        if pending.count > maxPending {
            let excess = pending.count - maxPending
            pending.removeFirst(excess)
            droppedCount += excess
        }
        return sequence
    }

    /// Messages to (re)send now, oldest first; marks them as sent at `now`.
    mutating func due(at now: MonotonicTime) -> [(sequence: UInt32, message: Message)] {
        var result: [(sequence: UInt32, message: Message)] = []
        for index in pending.indices {
            if let last = pending[index].lastSentAt, now - last < retryInterval { continue }
            pending[index].lastSentAt = now
            pending[index].sendCount += 1
            result.append((pending[index].sequence, pending[index].message))
        }
        return result
    }

    /// Forgets the message with `sequence`. Returns `false` for an unknown or repeated ack.
    @discardableResult
    mutating func acknowledge(_ sequence: UInt32) -> Bool {
        guard let index = pending.firstIndex(where: { $0.sequence == sequence }) else { return false }
        pending.remove(at: index)
        return true
    }

    /// Makes every pending message due immediately (e.g. a new link just came up).
    mutating func expediteAll() {
        for index in pending.indices {
            pending[index].lastSentAt = nil
        }
    }

    /// Drops everything, e.g. when the peer restarted and old messages no longer apply.
    mutating func removeAll() {
        pending.removeAll()
    }
}

/// Receiving side of `ControlRetransmitter`: every copy is acknowledged, but each sequence number
/// is delivered to the application only once.
struct ControlDeduplicator: Equatable, Sendable {
    private var window = ReplayWindow()

    init() {}

    /// `true` the first time `sequence` is seen.
    mutating func shouldDeliver(_ sequence: UInt32) -> Bool {
        window.insert(UInt64(sequence))
    }

    mutating func reset() {
        window.reset()
    }
}
