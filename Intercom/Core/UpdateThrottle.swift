import Foundation

/// Decides when a slow, budgeted mirror of some state should be refreshed: the Live Activity.
///
/// iOS budgets Live Activity updates and may silently drop them from a background app, so the mirror
/// is updated sparingly and every update must count:
/// * The first state is published at once.
/// * An *essential* change (link, mute, mode, latch: something a person acts on) is published at most
///   once per `essentialInterval`.
/// * A change that is only *cosmetic* (who is talking, route, round-trip time) waits until
///   `cosmeticInterval` has passed since the previous publish. It rides along for free whenever an
///   essential change is published earlier.
/// * With nothing new, the last state is re-published every `refreshInterval`, so a stale date
///   attached to it keeps moving forward while the app is alive.
///
/// Every publish carries the *latest* state, so a burst of changes collapses into one update. Pure
/// and clock-injected: the owner calls `submit` on every change, arms a timer for `nextDeadline`,
/// and calls `takeDue` when it fires.
struct UpdateThrottle<State: Equatable> {
    struct Configuration: Equatable {
        var essentialInterval: TimeInterval = 1
        var cosmeticInterval: TimeInterval = 5
        /// `nil` disables periodic refreshes.
        var refreshInterval: TimeInterval? = 600
    }

    let configuration: Configuration
    /// Whether going from the first state to the second is worth an update of its own.
    private let isEssentialChange: (State, State) -> Bool

    /// The most recent state handed to `submit`.
    private(set) var latest: State?
    /// The state of the last publish, and when it happened.
    private(set) var published: State?
    private(set) var publishedAt: MonotonicTime?

    init(configuration: Configuration = Configuration(), isEssentialChange: @escaping (State, State) -> Bool) {
        self.configuration = configuration
        self.isEssentialChange = isEssentialChange
    }

    /// Records the newest state. Returns `nextDeadline` for convenience.
    @discardableResult
    mutating func submit(_ state: State) -> MonotonicTime? {
        latest = state
        return nextDeadline
    }

    /// When `takeDue` will next return a state, or `nil` when nothing is waiting (no state yet, or no
    /// change and no periodic refresh). May be in the past: then it is due now.
    var nextDeadline: MonotonicTime? {
        guard let latest else { return nil }
        guard let published, let publishedAt else { return .zero }
        if latest != published {
            let interval = isEssentialChange(published, latest)
                ? configuration.essentialInterval
                : configuration.cosmeticInterval
            return publishedAt + interval
        }
        guard let refresh = configuration.refreshInterval else { return nil }
        return publishedAt + refresh
    }

    /// Returns the state to publish if its deadline has come, and records it as published.
    mutating func takeDue(now: MonotonicTime) -> State? {
        guard let deadline = nextDeadline, deadline <= now, let latest else { return nil }
        markPublished(latest, now: now)
        return latest
    }

    /// Publishes the latest state regardless of the intervals, unless it equals what was last
    /// published (then returns `nil`, as with no state). "Published" means handed to the sender, not
    /// shown: when a send can fail silently, re-send with `markPublished` instead.
    mutating func takeImmediately(now: MonotonicTime) -> State? {
        guard let latest, latest != published else { return nil }
        markPublished(latest, now: now)
        return latest
    }

    /// Records a publish made outside `takeDue` (for example the initial request of a new activity).
    mutating func markPublished(_ state: State, now: MonotonicTime) {
        latest = state
        published = state
        publishedAt = now
    }

    /// Forgets everything: the next submitted state is published at once.
    mutating func reset() {
        latest = nil
        published = nil
        publishedAt = nil
    }
}

/// A Boolean that follows its input only after the input has held a new value for a while, with
/// separate delays for turning on and off. Used so "the peer is talking" does not flicker on for a
/// cough, nor off in the pause between two sentences. Pure and clock-injected.
struct BooleanHysteresis: Equatable {
    let onDelay: TimeInterval
    let offDelay: TimeInterval

    private(set) var value: Bool
    /// When the input started to differ from `value`, if it currently does.
    private var changeStartedAt: MonotonicTime?

    init(onDelay: TimeInterval, offDelay: TimeInterval, initialValue: Bool = false) {
        self.onDelay = onDelay
        self.offDelay = offDelay
        value = initialValue
    }

    /// Feeds the current input and returns the filtered value.
    @discardableResult
    mutating func update(_ input: Bool, now: MonotonicTime) -> Bool {
        guard input != value else {
            changeStartedAt = nil
            return value
        }
        let startedAt = changeStartedAt ?? now
        changeStartedAt = startedAt
        if now - startedAt >= (input ? onDelay : offDelay) {
            value = input
            changeStartedAt = nil
        }
        return value
    }

    /// When the value will flip if the input keeps its current value, or `nil` when the input agrees
    /// with the value. Call `update` again at that time.
    var pendingDeadline: MonotonicTime? {
        guard let changeStartedAt else { return nil }
        return changeStartedAt + (value ? offDelay : onDelay)
    }

    /// Sets the value directly (for example to `false` when the link goes down).
    mutating func reset(to value: Bool = false) {
        self.value = value
        changeStartedAt = nil
    }
}
