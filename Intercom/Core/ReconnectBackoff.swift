import Foundation

/// Delay schedule between reconnect attempts.
///
/// An intercom must never give up while it runs, but two phones hammering a broken path in lock-step
/// waste radio time, so delays grow quickly to a short cap and are jittered. The first retry after a
/// link that had been stable is immediate; a link that flaps keeps escalating.
///
/// Reset (next delay back to the first step) when:
/// * a link that had been up for at least `stableLinkDuration` goes down (`linkWentDown(upFor:)`),
/// * the app returns to the foreground, or the network path changes (`reset()`).
struct ReconnectBackoff: Equatable, Sendable {
    struct Schedule: Equatable, Sendable {
        /// Delay before attempt 1, 2, …; the last value repeats forever.
        var delays: [TimeInterval]
        /// Relative jitter: each delay is scaled by a uniform factor in `1 ± jitter`.
        var jitter: Double
        /// A link up at least this long counts as stable, so its loss restarts the schedule.
        var stableLinkDuration: TimeInterval

        /// Network framework: 0, 0.25, 0.5, 1, 2, 2, … s.
        static let network = Schedule(delays: [0, 0.25, 0.5, 1, 2], jitter: 0.2, stableLinkDuration: 5)
        /// Multipeer Connectivity handshakes take seconds, so retrying faster only collides: 1, 2, 3, 5 s.
        static let multipeer = Schedule(delays: [1, 2, 3, 5], jitter: 0.2, stableLinkDuration: 5)
    }

    let schedule: Schedule
    /// Delays handed out since the last reset. Saturates instead of overflowing.
    private(set) var failures: Int = 0

    init(schedule: Schedule = .network) {
        var normalized = schedule
        if normalized.delays.isEmpty { normalized.delays = [0] }
        normalized.delays = normalized.delays.map { max(0, $0) }
        normalized.jitter = min(max(0, normalized.jitter), 1)
        self.schedule = normalized
    }

    /// The un-jittered delay the next call to `nextDelay` is based on.
    var nominalNextDelay: TimeInterval {
        schedule.delays[min(failures, schedule.delays.count - 1)]
    }

    /// The largest delay this schedule can ever return, jitter included.
    var maximumDelay: TimeInterval {
        (schedule.delays.max() ?? 0) * (1 + schedule.jitter)
    }

    /// Returns the delay before the next attempt and advances the schedule.
    mutating func nextDelay<R: RandomNumberGenerator>(using rng: inout R) -> TimeInterval {
        let nominal = nominalNextDelay
        if failures < Int.max { failures += 1 }
        guard nominal > 0, schedule.jitter > 0 else { return nominal }
        let factor = 1 + Double.random(in: -schedule.jitter...schedule.jitter, using: &rng)
        return nominal * factor
    }

    mutating func reset() {
        failures = 0
    }

    /// Call when an established link goes down; restarts the schedule if the link had been stable.
    mutating func linkWentDown(upFor duration: TimeInterval) {
        if duration >= schedule.stableLinkDuration {
            reset()
        }
    }
}

/// Small, fast, seedable generator (SplitMix64) so jitter and nonces are reproducible in tests.
/// Not cryptographically secure: seed it from `SystemRandomNumberGenerator` in production.
struct SplitMix64: RandomNumberGenerator, Equatable, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// Seeds from the system generator.
    init() {
        var system = SystemRandomNumberGenerator()
        state = system.next()
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
