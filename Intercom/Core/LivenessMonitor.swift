import Foundation

/// App-level liveness of one link, based on how long ago anything valid arrived.
///
/// UDP has no connection state, and Bonjour removal over peer-to-peer Wi-Fi is late or spurious,
/// so heartbeats are the only trustworthy signal. Thresholds scale with the heartbeat interval of
/// whichever side is slower (a backgrounded peer sends less often), but never go below floors that
/// ride out peer-to-peer Wi-Fi channel-hopping stalls of a few hundred milliseconds:
///
/// * suspect after max(600 ms, 3 intervals) of silence — "weak link", keep playing;
/// * dead after max(2 s, 8 intervals) — or max(3 s, 6 intervals) when either side is in the
///   background, where the radio is allowed to doze longer;
/// * dead as well once sends have failed continuously for at least 300 ms (the interface is gone) —
///   or for as long as the suspect threshold while the peer is still being heard, so a short burst of
///   failed sends during peer-to-peer Wi-Fi congestion does not tear down a path that evidently works.
struct LivenessMonitor: Equatable, Sendable {
    enum Health: Int, Comparable, Sendable {
        case alive
        case suspect
        case dead

        static func < (lhs: Health, rhs: Health) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct Configuration: Equatable, Sendable {
        var foregroundHeartbeatInterval: TimeInterval = 0.2
        var backgroundHeartbeatInterval: TimeInterval = 0.5
        var suspectMinimum: TimeInterval = 0.6
        var suspectIntervals: Double = 3
        var deadMinimum: TimeInterval = 2
        var deadIntervals: Double = 8
        var backgroundDeadMinimum: TimeInterval = 3
        var backgroundDeadIntervals: Double = 6
        /// Continuous send failures for this long mean the path is gone.
        var sendErrorDeadline: TimeInterval = 0.3
        /// Failed sends a run needs before it counts, so two unlucky samples are never a verdict.
        var sendErrorMinimumCount = 3

        static let `default` = Configuration()

        /// Multipeer Connectivity: ping every 1 s, dead after ~4 s without pong or audio.
        static let multipeer = Configuration(
            foregroundHeartbeatInterval: 1,
            backgroundHeartbeatInterval: 1,
            suspectMinimum: 2,
            suspectIntervals: 2,
            deadMinimum: 4,
            deadIntervals: 4,
            backgroundDeadMinimum: 4,
            backgroundDeadIntervals: 4,
            sendErrorDeadline: 1,
            // A ping per second: two failures already span the deadline.
            sendErrorMinimumCount: 2
        )
    }

    let configuration: Configuration
    var isLocalInBackground = false
    var isRemoteInBackground = false
    private(set) var lastReceivedAt: MonotonicTime
    /// Start of the current run of failed sends; `nil` after any success.
    private(set) var firstSendErrorAt: MonotonicTime?
    private(set) var lastSendErrorAt: MonotonicTime?
    /// Failed sends in the current run.
    private(set) var sendErrorCount = 0

    /// `now` counts as the last sign of life, so a new link gets a full grace period.
    init(configuration: Configuration = .default, now: MonotonicTime) {
        self.configuration = configuration
        lastReceivedAt = now
    }

    /// Heartbeat interval the local side should use.
    var localHeartbeatInterval: TimeInterval {
        isLocalInBackground ? configuration.backgroundHeartbeatInterval : configuration.foregroundHeartbeatInterval
    }

    private var remoteHeartbeatInterval: TimeInterval {
        isRemoteInBackground ? configuration.backgroundHeartbeatInterval : configuration.foregroundHeartbeatInterval
    }

    /// The interval silence is measured against: the slower of the two sides.
    var effectiveInterval: TimeInterval {
        max(localHeartbeatInterval, remoteHeartbeatInterval)
    }

    var suspectAfter: TimeInterval {
        max(configuration.suspectMinimum, configuration.suspectIntervals * effectiveInterval)
    }

    var deadAfter: TimeInterval {
        let interval = effectiveInterval
        if isLocalInBackground || isRemoteInBackground {
            return max(configuration.backgroundDeadMinimum, configuration.backgroundDeadIntervals * interval, suspectAfter)
        }
        return max(configuration.deadMinimum, configuration.deadIntervals * interval, suspectAfter)
    }

    mutating func recordReceive(at now: MonotonicTime) {
        if now > lastReceivedAt {
            lastReceivedAt = now
        }
    }

    mutating func recordSendSuccess(at now: MonotonicTime) {
        firstSendErrorAt = nil
        lastSendErrorAt = nil
        sendErrorCount = 0
    }

    mutating func recordSendError(at now: MonotonicTime) {
        if firstSendErrorAt == nil {
            firstSendErrorAt = now
        }
        lastSendErrorAt = now
        sendErrorCount += 1
    }

    func silence(at now: MonotonicTime) -> TimeInterval {
        max(0, now - lastReceivedAt)
    }

    /// `true` once at least `sendErrorMinimumCount` failures with no success between span
    /// `sendErrorDeadline`. While the peer is still heard, the run must span the suspect threshold
    /// instead: receives never clear the run (a one-way failure must still be repaired quickly), but
    /// they show the path is not simply gone, so a burst of a few failed heartbeats is not enough.
    /// A quarter interval of slack keeps timer jitter from delaying that verdict by a whole heartbeat.
    func hasPersistentSendErrors(at now: MonotonicTime) -> Bool {
        guard let first = firstSendErrorAt, let last = lastSendErrorAt,
              sendErrorCount >= configuration.sendErrorMinimumCount else { return false }
        let isPeerHeard = silence(at: now) < suspectAfter
        let deadline = isPeerHeard
            ? max(configuration.sendErrorDeadline, suspectAfter - effectiveInterval / 4)
            : configuration.sendErrorDeadline
        return last - first >= deadline
    }

    func health(at now: MonotonicTime) -> Health {
        if hasPersistentSendErrors(at: now) { return .dead }
        let quiet = silence(at: now)
        if quiet >= deadAfter { return .dead }
        if quiet >= suspectAfter { return .suspect }
        return .alive
    }
}
