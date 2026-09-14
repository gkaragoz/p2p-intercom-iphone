import ActivityKit
import Combine
import Foundation
import os
import UIKit

/// Keeps one Live Activity in step with the running intercom, and performs its buttons' intents.
///
/// Lifecycle:
/// * Requested when the intercom starts (`phase` becomes running) while the app is in the foreground;
///   iOS refuses requests from the background. A start that completes in the background requests on
///   the next foreground.
/// * Ended with `.immediate` when the intercom stops, and best-effort when the app terminates.
///   Activities outlive their process (crash, jetsam, swipe-kill), so leftovers are ended at launch.
/// * iOS ends every activity after 8 hours, and the person may dismiss it. One older than 7 hours is
///   renewed the next time the app comes to the foreground while the intercom runs. One the system
///   ended stays on the Lock Screen (frozen, for up to 4 hours) with working buttons: it is renewed
///   when one of them is tapped (an intent may request from the background) or on the next foreground,
///   and the frozen card is then removed so there are never two. One the person dismissed is not
///   brought back until the intercom restarts, or Live Activities are turned off and on in Settings.
///
/// Updates are budgeted (`UpdateThrottle`): link, mute, mode and latch changes go out at once, at most
/// one per second; cosmetic changes (who is sending or talking, route, attempt count, round-trip time)
/// at most one per 5 s; meters never. The peer-talking flag is debounced (on after 0.3 s, off after
/// 1.5 s) so it does not flicker. No alert configurations: notifications and cues already alert.
/// Every update carries a stale date 15 minutes ahead and is repeated every 10 minutes, so an activity
/// whose app died or stopped getting updates through says "not updated recently" instead of lying.
///
/// Background updates: iOS may silently reject `Activity.update` from an app that is kept alive only
/// by background audio ("Process is only playing background media so is forbidden to update
/// activity" in the liveactivitiesd log). The app cannot detect that, so every request, update and end
/// is logged with the app state (category "liveactivity"): compare those lines with what the Lock
/// Screen shows, and with liveactivitiesd's lines in Console. Updates from an intent a person tapped,
/// and from the foreground, are the paths expected to work; the app re-sends the state on foreground.
@MainActor
final class LiveActivityCoordinator: IntercomIntentHandler {
    typealias ContentState = IntercomActivityAttributes.ContentState

    /// A published state older than this is shown as stale.
    static let staleInterval: TimeInterval = 15 * 60
    /// The unchanged state is re-sent this often, moving the stale date ahead.
    static let refreshInterval: TimeInterval = 10 * 60
    /// Renew on foreground before iOS's 8-hour limit ends the activity.
    static let renewalAge: TimeInterval = 7 * 3600

    private let controller: IntercomController
    private let authorization = ActivityAuthorizationInfo()
    private var throttle = UpdateThrottle<ContentState>(
        configuration: .init(essentialInterval: 1, cosmeticInterval: 5, refreshInterval: LiveActivityCoordinator.refreshInterval),
        isEssentialChange: ContentState.isEssentialChange
    )
    private var remoteTalking = BooleanHysteresis(onDelay: 0.3, offDelay: 1.5)

    private var activity: Activity<IntercomActivityAttributes>?
    private var activityRequestedAt: MonotonicTime?
    private var activityStateTask: Task<Void, Never>?
    /// The last activity the system ended (8-hour limit). Still on the Lock Screen and still tappable,
    /// so it is kept until a new activity replaces it or the intercom stops, and then removed.
    private var systemEndedActivity: Activity<IntercomActivityAttributes>?
    /// Activities this coordinator ended itself; their `ended`/`dismissed` updates are expected.
    private var endingActivityIDs = Set<String>()
    /// Background updates of the current activity were logged with the rejection hint already.
    private var hasLoggedBackgroundHint = false

    /// The intercom was running at the last reconcile.
    private var isSessionActive = false
    /// The person dismissed this session's activity: do not bring it back until the next start.
    private var isDismissedByUser = false
    /// Live Activities were turned off in Settings since they were last turned on.
    private var sawActivitiesDisabled = false
    /// The coarse link state last mapped, and since when, for states without a controller timestamp.
    private var mappedLink: ContentState.Link?
    private var mappedLinkSince = Date()

    private var isReconcileScheduled = false
    private var deadlineTask: Task<Void, Never>?
    /// Serializes ActivityKit calls so updates and the final end arrive in order.
    private var activityCalls: Task<Void, Never>?
    private var enablementTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    private static let log = Logger(subsystem: "intercom", category: "liveactivity")

    init(controller: IntercomController) {
        self.controller = controller
        observeController()
        observeApplication()
        observeEnablement()
        // After launch has settled (not inside `App.init`): end what a previous process left behind.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.endLeftoverActivities() }
        }
    }

    // MARK: - Intents

    func handle(_ command: IntercomIntentCommand) async {
        guard controller.isRunning else {
            // The activity outlived its session (the app was killed, and this intent launched it in
            // the background). Audio cannot start from here; take the stale controls away instead.
            Self.log.notice("intent \(command.description, privacy: .public) while the intercom is not running: ending activities")
            await endAllActivities(reason: "intent without a running intercom")
            return
        }
        switch command {
        case .setMuted(let muted):
            controller.setMuted(muted)
        case .setTransmitMode(let mode):
            controller.setMode(TransmitMode(mode))
        case .setTalkLatched(let latched):
            if !controller.setTalkLatched(latched) {
                Self.log.notice("intent: talk latch refused by the controller")
            }
        }
        if activity == nil, isSessionActive, !isDismissedByUser {
            // The tapped card is one the system ended (it stays on the Lock Screen after the 8-hour
            // limit). An intent a person tapped may request from the background: replace it.
            requestActivity(reason: "intent renewal", allowBackground: true)
            if activity != nil {
                dismissSystemEndedActivity(reason: "replaced after an intent")
                await activityCalls?.value
                return
            }
        }
        // An update made while the intent runs is the one most likely to be accepted in the
        // background, and the button should reflect the result (including a refusal) right away.
        // Always the full state, even when nothing changed: an earlier background update may have
        // been rejected without notice, and the card may still show what the tap was based on.
        await publishNow(reason: "intent \(command.description)")
    }

    // MARK: - Observation

    private func observeController() {
        let settings = controller.settings
        // Only the values the activity shows (never the 20 Hz meters). `@Published` emits before the
        // property changes, so these only schedule a reconcile that reads the new values afterwards.
        let triggers: [AnyPublisher<Void, Never>] = [
            controller.$phase.map { _ in () }.eraseToAnyPublisher(),
            controller.$linkState.map { _ in () }.eraseToAnyPublisher(),
            controller.$lastPeerName.map { _ in () }.eraseToAnyPublisher(),
            controller.$linkPath.map { _ in () }.eraseToAnyPublisher(),
            controller.$isMuted.map { _ in () }.eraseToAnyPublisher(),
            controller.$isTalkLatched.map { _ in () }.eraseToAnyPublisher(),
            controller.$isSending.map { _ in () }.eraseToAnyPublisher(),
            controller.$remoteTalking.map { _ in () }.eraseToAnyPublisher(),
            controller.$remoteMuted.map { _ in () }.eraseToAnyPublisher(),
            controller.$remoteAudioPaused.map { _ in () }.eraseToAnyPublisher(),
            controller.$route.map { _ in () }.eraseToAnyPublisher(),
            controller.$roundTripMs.map { _ in () }.eraseToAnyPublisher(),
            settings.$transmitMode.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] in self?.setNeedsReconcile() }
            .store(in: &observers)
    }

    private func observeApplication() {
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
            }
            .store(in: &observers)
        // Posted on the main thread; the process exits right after the observers return.
        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationWillTerminate() }
            }
            .store(in: &observers)
    }

    private func observeEnablement() {
        let updates = authorization.activityEnablementUpdates
        enablementTask = Task { [weak self] in
            for await enabled in updates {
                self?.enablementDidChange(enabled)
            }
        }
    }

    /// Coalesces the burst of `@Published` changes one controller action causes into one reconcile.
    private func setNeedsReconcile() {
        guard !isReconcileScheduled else { return }
        isReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    private func reconcile() {
        isReconcileScheduled = false
        let running = controller.isRunning
        if running != isSessionActive {
            isSessionActive = running
            if running {
                sessionDidStart()
            } else {
                sessionDidStop()
            }
        }
        guard isSessionActive, activity != nil else { return }
        submitCurrentState()
        publishIfDue()
    }

    // MARK: - Session

    private func sessionDidStart() {
        Self.log.notice("intercom started")
        isDismissedByUser = false
        requestActivity(reason: "intercom started")
    }

    private func sessionDidStop() {
        Self.log.notice("intercom stopped")
        endActivity(reason: "intercom stopped")
        dismissSystemEndedActivity(reason: "intercom stopped")
        remoteTalking.reset()
        mappedLink = nil
    }

    private func applicationDidBecomeActive() {
        guard isSessionActive else { return }
        if let activity, let requestedAt = activityRequestedAt, MonotonicTime.now() - requestedAt >= Self.renewalAge {
            Self.log.notice("renewing activity \(activity.id, privacy: .public): older than \(Int(Self.renewalAge / 3600), privacy: .public) h")
            endActivity(reason: "renewal")
            requestActivity(reason: "renewal")
        } else if activity == nil {
            if isDismissedByUser {
                Self.log.notice("foreground: activity was dismissed by the user this session; not renewing")
            } else {
                requestActivity(reason: "foreground renewal")
            }
            // A card the system ended would stay next to the new one with frozen controls; the app
            // is in front now, so nothing is lost if the request failed.
            dismissSystemEndedActivity(reason: "foreground")
        } else {
            // Background updates may have been rejected; the foreground is allowed to fix that.
            Task { await publishNow(reason: "foreground resync") }
        }
    }

    private func enablementDidChange(_ enabled: Bool) {
        Self.log.notice("Live Activities \(enabled ? "enabled" : "disabled", privacy: .public) for Intercom")
        guard enabled else {
            sawActivitiesDisabled = true
            return
        }
        // Turning them back on in Settings is an explicit wish to see the activity; turning them off
        // removed it, which may have been reported as a dismissal. This arrives while Settings is in
        // front (the app is in the background), so clear the flag here and let the next foreground
        // request. Only after an actual off, so a repeated `true` cannot revive a swiped-away activity.
        if sawActivitiesDisabled {
            sawActivitiesDisabled = false
            isDismissedByUser = false
        }
        guard isSessionActive, activity == nil, UIApplication.shared.applicationState != .background else { return }
        requestActivity(reason: "Live Activities enabled")
        if activity != nil {
            dismissSystemEndedActivity(reason: "replaced after Live Activities were enabled")
        }
    }

    // MARK: - Request and end

    /// `allowBackground`: the caller runs inside a `LiveActivityIntent` a person tapped, the one
    /// background context where iOS allows a request.
    private func requestActivity(reason: String, allowBackground: Bool = false) {
        guard activity == nil else { return }
        let appState = Self.applicationStateDescription
        guard allowBackground || UIApplication.shared.applicationState != .background else {
            Self.log.notice("not requesting an activity (\(reason, privacy: .public)): the app is in the background; will request on the next foreground")
            return
        }
        guard authorization.areActivitiesEnabled else {
            Self.log.notice("not requesting an activity (\(reason, privacy: .public)): Live Activities are turned off for Intercom in Settings")
            return
        }
        let now = MonotonicTime.now()
        let state = makeState(now: now)
        let attributes = IntercomActivityAttributes(localName: controller.localDisplayName)
        do {
            let activity = try Activity.request(attributes: attributes, content: content(for: state), pushType: nil)
            self.activity = activity
            activityRequestedAt = now
            hasLoggedBackgroundHint = false
            throttle.reset()
            throttle.markPublished(state, now: now)
            observeState(of: activity)
            Self.log.notice("requested activity \(activity.id, privacy: .public) (\(reason, privacy: .public), app \(appState, privacy: .public)): \(state.logDescription, privacy: .public)")
            scheduleDeadline()
        } catch {
            Self.log.error("activity request failed (\(reason, privacy: .public), app \(appState, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    private func endActivity(reason: String) {
        deadlineTask?.cancel()
        deadlineTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        throttle.reset()
        guard let activity else { return }
        self.activity = nil
        activityRequestedAt = nil
        endingActivityIDs.insert(activity.id)
        let id = activity.id
        var final = makeState(now: .now())
        final.link = .stopped
        let finalContent = ActivityContent(state: final, staleDate: nil)
        let appState = Self.applicationStateDescription
        Self.log.notice("ending activity \(id, privacy: .public) (\(reason, privacy: .public), app \(appState, privacy: .public))")
        enqueueActivityCall {
            await activity.end(finalContent, dismissalPolicy: .immediate)
            Self.log.notice("ended activity \(id, privacy: .public)")
        }
    }

    /// Ends every activity of this app, including ones this process did not create, and waits.
    private func endAllActivities(reason: String) async {
        if activity != nil {
            endActivity(reason: reason)
        }
        dismissSystemEndedActivity(reason: reason)
        endUntracked(Activity<IntercomActivityAttributes>.activities, reason: reason)
        await activityCalls?.value
    }

    /// Ends what a previous process left behind. Never the current activity: the intercom may have
    /// started (and requested one) before this runs.
    private func endLeftoverActivities() {
        let leftovers = Activity<IntercomActivityAttributes>.activities.filter { $0.id != activity?.id }
        Self.log.notice("launch: \(leftovers.count, privacy: .public) leftover activit\(leftovers.count == 1 ? "y" : "ies", privacy: .public)")
        endUntracked(leftovers, reason: "left over from a previous launch")
    }

    /// Ends activities this coordinator does not track (and is not already ending).
    private func endUntracked(_ activities: [Activity<IntercomActivityAttributes>], reason: String) {
        for other in activities where other.id != activity?.id && !endingActivityIDs.contains(other.id) {
            endingActivityIDs.insert(other.id)
            let id = other.id
            Self.log.notice("ending activity \(id, privacy: .public) (\(reason, privacy: .public))")
            enqueueActivityCall {
                await other.end(nil, dismissalPolicy: .immediate)
                Self.log.notice("ended activity \(id, privacy: .public)")
            }
        }
    }

    /// Removes the card the system ended, if one is still kept.
    private func dismissSystemEndedActivity(reason: String) {
        guard let ended = systemEndedActivity else { return }
        systemEndedActivity = nil
        endUntracked([ended], reason: "system-ended, \(reason)")
    }

    /// Best effort: the app is going away, and with it everything the activity's buttons control.
    /// `end` is asynchronous and the process exits once this returns, so wait a little for it.
    private func applicationWillTerminate() {
        let activities = Activity<IntercomActivityAttributes>.activities
        Self.log.notice("app will terminate: ending \(activities.count, privacy: .public) activit\(activities.count == 1 ? "y" : "ies", privacy: .public)")
        guard !activities.isEmpty else { return }
        deadlineTask?.cancel()
        activityStateTask?.cancel()
        activity = nil
        systemEndedActivity = nil
        activities.forEach { endingActivityIDs.insert($0.id) }
        let done = DispatchSemaphore(value: 0)
        let box = UncheckedSendableBox(activities)
        // Detached: this thread (main) is blocked below, so the calls must not need it.
        Task.detached {
            for activity in box.value {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 0.5) == .timedOut {
            Self.log.error("app will terminate: ending activities timed out")
        }
    }

    private func observeState(of activity: Activity<IntercomActivityAttributes>) {
        activityStateTask?.cancel()
        let id = activity.id
        let updates = activity.activityStateUpdates
        activityStateTask = Task { [weak self] in
            for await state in updates {
                guard !Task.isCancelled else { return }
                self?.activityStateDidChange(id: id, state: state)
            }
        }
    }

    private func activityStateDidChange(id: String, state: ActivityState) {
        guard !endingActivityIDs.contains(id) else { return }
        guard let activity, activity.id == id else { return }
        switch state {
        case .active:
            Self.log.notice("activity \(id, privacy: .public) is active")
        case .pending:
            Self.log.notice("activity \(id, privacy: .public) is pending")
        case .stale:
            Self.log.notice("activity \(id, privacy: .public) is stale: no update got through for \(Int(Self.staleInterval / 60), privacy: .public) min (background updates rejected, or the app was suspended)")
        case .ended:
            // Not by us: the 8-hour limit (maybe also Live Activities turned off; which state that
            // reports is unverified). The card may stay on the Lock Screen: keep it, so a tap on it can
            // renew, and remove it once replaced.
            Self.log.notice("activity \(id, privacy: .public) was ended by the system; will renew on a tap or the next foreground")
            dismissSystemEndedActivity(reason: "superseded")
            systemEndedActivity = activity
            detachActivity()
        case .dismissed:
            // Removed while still active: the person swiped it away, or the system removed it (turning
            // Live Activities off in Settings may report this too; turning them on clears the flag).
            Self.log.notice("activity \(id, privacy: .public) was dismissed by the user; not renewing until the intercom restarts")
            isDismissedByUser = true
            detachActivity()
        @unknown default:
            Self.log.notice("activity \(id, privacy: .public) changed to an unknown state")
        }
    }

    private func detachActivity() {
        activity = nil
        activityRequestedAt = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        throttle.reset()
    }

    // MARK: - Updates

    private func submitCurrentState() {
        throttle.submit(makeState(now: .now()))
    }

    private func publishIfDue() {
        guard let activity else { return }
        let now = MonotonicTime.now()
        let isRefresh = throttle.latest == throttle.published
        if let state = throttle.takeDue(now: now) {
            sendUpdate(state, to: activity, reason: isRefresh ? "refresh" : "state change")
        }
        scheduleDeadline()
    }

    /// Sends the current state at once, ignoring the throttle intervals, and waits until ActivityKit
    /// took it. Also re-sends a state equal to the last one sent: its callers (a tapped intent, the
    /// foreground) are the paths where an update goes through, and the last one may not have.
    private func publishNow(reason: String) async {
        guard let activity else { return }
        let now = MonotonicTime.now()
        let state = makeState(now: now)
        throttle.markPublished(state, now: now)
        sendUpdate(state, to: activity, reason: reason)
        scheduleDeadline()
        await activityCalls?.value
    }

    private func sendUpdate(_ state: ContentState, to activity: Activity<IntercomActivityAttributes>, reason: String) {
        let appState = Self.applicationStateDescription
        let id = activity.id
        let content = content(for: state)
        Self.log.notice("update \(id, privacy: .public) (\(reason, privacy: .public), app \(appState, privacy: .public)): \(state.logDescription, privacy: .public)")
        if UIApplication.shared.applicationState == .background, !hasLoggedBackgroundHint {
            hasLoggedBackgroundHint = true
            Self.log.notice("background update: if the Lock Screen does not change, look for 'forbidden to update activity' from liveactivitiesd")
        }
        enqueueActivityCall {
            await activity.update(content)
        }
    }

    private func content(for state: ContentState) -> ActivityContent<ContentState> {
        ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: Self.staleInterval))
    }

    private func enqueueActivityCall(_ call: @escaping @MainActor () async -> Void) {
        let previous = activityCalls
        activityCalls = Task {
            await previous?.value
            await call()
        }
    }

    /// Arms one timer for the earliest of: the throttle's next publish, and the talking debounce.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard activity != nil else { return }
        let deadlines = [throttle.nextDeadline, remoteTalking.pendingDeadline].compactMap { $0 }
        guard let deadline = deadlines.min() else { return }
        let delay = max(0, deadline - MonotonicTime.now())
        deadlineTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.deadlineTask = nil
            self.submitCurrentState()
            self.publishIfDue()
        }
    }

    // MARK: - Mapping

    private func makeState(now: MonotonicTime) -> ContentState {
        let link: ContentState.Link
        var since: Date?
        var attempt = 0
        var needsForeground = false
        switch controller.linkState {
        case .idle:
            link = .stopped
        case .searching:
            link = .searching
        case .disconnected:
            link = .disconnected
        case .connecting(let current):
            link = .connecting
            attempt = current
        case .connected(let connectedSince, _):
            link = .connected
            since = connectedSince
        case .reconnecting(let lostSince, let current):
            link = .reconnecting
            since = lostSince
            attempt = current
        case .audioInterrupted(let foreground):
            link = .audioPaused
            needsForeground = foreground
        }
        if link != mappedLink {
            mappedLink = link
            mappedLinkSince = Date()
        }
        let connected = link == .connected
        if !connected {
            remoteTalking.reset()
        }
        let talking = remoteTalking.update(connected && controller.remoteTalking, now: now)
        return ContentState(
            link: link,
            linkSince: since ?? mappedLinkSince,
            peerName: controller.lastPeerName,
            reconnectAttempt: attempt,
            audioNeedsForeground: needsForeground,
            mode: ActivityTransmitMode(controller.settings.transmitMode),
            isMuted: controller.isMuted,
            isTalkLatched: controller.isTalkLatched,
            isSending: controller.isSending,
            remoteTalking: talking,
            remoteMuted: connected && controller.remoteMuted,
            remoteAudioPaused: connected && controller.remoteAudioPaused,
            route: ContentState.Route(controller.route),
            linkPath: connected ? controller.linkPath.flatMap(ContentState.Path.init) : nil,
            rttBucketMs: connected ? controller.roundTripMs.flatMap(Self.rttBucket) : nil
        )
    }

    /// Round-trip time rounded up to 10 ms, so jitter of a few milliseconds is not an update.
    nonisolated static func rttBucket(_ milliseconds: Double) -> Int? {
        guard milliseconds.isFinite, milliseconds >= 0 else { return nil }
        return max(10, Int((milliseconds / 10).rounded(.up)) * 10)
    }

    private static var applicationStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Mapping helpers

extension IntercomActivityAttributes.ContentState {
    /// Changes a person acts on or must see at once; everything else is cosmetic and waits.
    static func isEssentialChange(_ old: Self, _ new: Self) -> Bool {
        old.link != new.link
            || old.linkSince != new.linkSince
            || old.peerName != new.peerName
            || old.audioNeedsForeground != new.audioNeedsForeground
            || old.mode != new.mode
            || old.isMuted != new.isMuted
            || old.isTalkLatched != new.isTalkLatched
            || old.remoteMuted != new.remoteMuted
            || old.remoteAudioPaused != new.remoteAudioPaused
    }

    /// One log line; the peer name stays out (it is personal).
    var logDescription: String {
        "link=\(link.rawValue) attempt=\(reconnectAttempt) mode=\(mode.rawValue) muted=\(isMuted)"
            + " latched=\(isTalkLatched) sending=\(isSending) remoteTalking=\(remoteTalking)"
            + " remoteMuted=\(remoteMuted) remotePaused=\(remoteAudioPaused) needsForeground=\(audioNeedsForeground)"
            + " route=\(route.rawValue) path=\(linkPath?.rawValue ?? "-") rtt=\(rttBucketMs.map { "\($0)ms" } ?? "-")"
    }
}

extension IntercomActivityAttributes.ContentState.Route {
    init(_ route: AudioSessionController.Route) {
        if route.isBluetooth {
            self = .bluetooth
        } else if route.isWiredHeadset {
            self = .wired
        } else if route.isReceiver {
            self = .receiver
        } else {
            self = .speaker
        }
    }
}

extension IntercomActivityAttributes.ContentState.Path {
    /// `nil` for an unknown path (Multipeer does not expose one).
    init?(_ path: LinkPath) {
        switch path {
        case .peerToPeerWiFi: self = .direct
        case .wifiNetwork: self = .wifiNetwork
        case .wired: self = .wired
        case .other: self = .other
        case .unknown: return nil
        }
    }
}

extension ActivityTransmitMode {
    init(_ mode: TransmitMode) {
        switch mode {
        case .pushToTalk: self = .pushToTalk
        case .voiceActivated: self = .voiceActivated
        case .alwaysOn: self = .alwaysOn
        }
    }
}

extension TransmitMode {
    init(_ mode: ActivityTransmitMode) {
        switch mode {
        case .pushToTalk: self = .pushToTalk
        case .voiceActivated: self = .voiceActivated
        case .alwaysOn: self = .alwaysOn
        }
    }
}

/// Carries a value the compiler cannot prove `Sendable` across a task boundary. Only for values the
/// sender stops using, as in `applicationWillTerminate`.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
