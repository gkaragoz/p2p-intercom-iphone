import Foundation

/// A point on a monotonic clock, in nanoseconds from an arbitrary, process-local origin.
///
/// Link timing (heartbeats, handshake deadlines, backoff) must never use `Date()`: the wall clock
/// jumps when the user or the network changes the time, which would fire or starve every timer at
/// once. The link types take a `MonotonicTime` as an explicit `now` argument instead of reading a
/// clock themselves, so tests drive them with a synthetic clock and production passes `.now()`.
///
/// The origin is process-local, so values are never sent over the network as absolute times.
struct MonotonicTime: Comparable, Hashable, Sendable, CustomStringConvertible {
    var nanoseconds: UInt64

    init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// Convenience for tests and configuration: `MonotonicTime(seconds: 1.5)`.
    init(seconds: TimeInterval) {
        nanoseconds = Self.nanoseconds(from: seconds)
    }

    static let zero = MonotonicTime(nanoseconds: 0)

    /// `ContinuousClock` keeps counting while the device sleeps, so a link that went quiet while
    /// the app was suspended is correctly seen as silent for the whole time on resume.
    private static let origin = ContinuousClock.now

    static func now() -> MonotonicTime {
        let elapsed = origin.duration(to: ContinuousClock.now).components
        let seconds = UInt64(max(0, elapsed.seconds))
        let nanos = UInt64(max(0, elapsed.attoseconds / 1_000_000_000))
        return MonotonicTime(nanoseconds: seconds &* 1_000_000_000 &+ nanos)
    }

    var seconds: TimeInterval { TimeInterval(nanoseconds) / 1_000_000_000 }

    /// Whole milliseconds since the origin.
    var milliseconds: UInt64 { nanoseconds / 1_000_000 }

    var description: String { String(format: "%.3fs", seconds) }

    static func < (lhs: MonotonicTime, rhs: MonotonicTime) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Adds a (possibly negative) number of seconds, clamping at the origin.
    static func + (lhs: MonotonicTime, rhs: TimeInterval) -> MonotonicTime {
        if rhs >= 0 {
            let (sum, overflow) = lhs.nanoseconds.addingReportingOverflow(nanoseconds(from: rhs))
            return MonotonicTime(nanoseconds: overflow ? .max : sum)
        }
        let delta = nanoseconds(from: -rhs)
        return MonotonicTime(nanoseconds: lhs.nanoseconds > delta ? lhs.nanoseconds - delta : 0)
    }

    static func += (lhs: inout MonotonicTime, rhs: TimeInterval) {
        lhs = lhs + rhs
    }

    /// Signed interval `lhs - rhs` in seconds.
    static func - (lhs: MonotonicTime, rhs: MonotonicTime) -> TimeInterval {
        if lhs.nanoseconds >= rhs.nanoseconds {
            return TimeInterval(lhs.nanoseconds - rhs.nanoseconds) / 1_000_000_000
        }
        return -TimeInterval(rhs.nanoseconds - lhs.nanoseconds) / 1_000_000_000
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let value = seconds * 1_000_000_000
        return value >= Double(UInt64.max) ? .max : UInt64(value.rounded())
    }
}
