import Foundation

/// Sliding-window duplicate detector for monotonically increasing counters (RFC 4303 style).
///
/// Used twice: by the packet sealer to reject replayed datagrams (nonce counters), and by the
/// control channel to deliver each retransmitted control message exactly once (sequence numbers).
/// Counters up to `size - 1` behind the newest one are tracked individually, so moderate
/// reordering is tolerated; anything older is treated as already seen.
struct ReplayWindow: Equatable, Sendable {
    static let size: UInt64 = 64

    /// Newest counter accepted so far, `nil` before the first one.
    private(set) var highest: UInt64?
    /// Bit `i` set ⇔ counter `highest - i` was accepted.
    private var bitmap: UInt64 = 0

    init() {}

    /// `true` if `counter` has not been seen and is not too old. Does not record it, so a caller can
    /// check before doing expensive authentication and only `insert` once the datagram is genuine.
    func wouldAccept(_ counter: UInt64) -> Bool {
        guard let highest else { return true }
        if counter > highest { return true }
        let age = highest - counter
        guard age < Self.size else { return false }
        return bitmap & (1 << age) == 0
    }

    /// Records `counter`; returns `false` (and changes nothing) for a duplicate or a too-old counter.
    @discardableResult
    mutating func insert(_ counter: UInt64) -> Bool {
        guard wouldAccept(counter) else { return false }
        guard let current = highest else {
            highest = counter
            bitmap = 1
            return true
        }
        if counter > current {
            let shift = counter - current
            bitmap = shift >= Self.size ? 1 : (bitmap << shift) | 1
            highest = counter
        } else {
            bitmap |= 1 << (current - counter)
        }
        return true
    }

    mutating func reset() {
        highest = nil
        bitmap = 0
    }
}
