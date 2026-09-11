import Foundation

/// Helpers for 16-bit packet sequence numbers that wrap around.
enum SequenceNumber {
    /// Signed distance from `a` to `b` in modular 16-bit arithmetic.
    ///
    /// Positive when `b` comes after `a`, negative when it comes before.
    /// `distance(from: 65_535, to: 0) == 1` and `distance(from: 0, to: 65_535) == -1`.
    static func distance(from a: UInt16, to b: UInt16) -> Int {
        Int(Int16(bitPattern: b &- a))
    }

    /// `true` when `a` was produced after `b`.
    static func isNewer(_ a: UInt16, than b: UInt16) -> Bool {
        distance(from: b, to: a) > 0
    }
}
