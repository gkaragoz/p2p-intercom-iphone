import Foundation
import MultipeerConnectivity
import os

/// The legacy connection engine on Multipeer Connectivity (selectable in Settings; both phones must match).
///
/// Both iPhones advertise *and* browse, so either finds the other regardless of who started first.
/// `PeerElection` (display names, then the persisted install-ID tokens) picks the side that invites; the
/// other only accepts and, if no invitation arrives, re-announces itself. On top of the framework this
/// class adds what the field logs showed Multipeer Connectivity lacks on iOS 26:
///
/// * a watchdog per handshake attempt (the framework can sit in `.connecting` forever) and a fresh
///   `MCSession` after every failed handshake, so no attempt reuses a session with stale peer state;
/// * app-level liveness: a ping every second (with the local status riding along) and a dead link
///   after ~4 s without any frame, instead of the framework's 10–20 s;
/// * an invitation from a peer that is still "connected" proves the old link dead, and the session is
///   replaced, once that link is old enough for the peer to have given up on it (or already suspect);
///   an invitation that crossed our own handshake is declined instead;
/// * reconnect backoff of 1, 2, 3, 5 s with jitter, never giving up, reset on foreground and manual connect;
/// * discovery restarts coordinated (earliest deadline wins, postponed during a handshake, the
///   advertiser recreated at most every 30 s so the other phone's resolved endpoint stays valid);
/// * browsing paused while every wanted peer is connected, resumed on a drop (advertising continues:
///   with neither running, the framework stopped carrying the session's data);
/// * explicit `bye` reasons, so a user's Disconnect is not undone by the other phone inviting again. The
///   `bye(userDisconnect)` frame is backed by a bye *invitation* (`MultipeerInvitation.bye`), sent when
///   the disconnected phone declines an invitation, so a lost frame cannot leave the other phone redialling;
///   and it binds only the instance that sent it: a peer that restarts (new advertised epoch) is dialled again.
///
/// Audio frames go out `.unreliable`; control, status and bye `.reliable`; pings `.unreliable`.
///
/// State is confined to `queue`. Delegate callbacks arrive on framework threads and are forwarded to
/// `queue`, except received audio, which goes to `onAudio` immediately. The session reference, the
/// callbacks and the receive-side peer map are read from other threads and guarded by `stateLock`.
final class MultipeerTransport: NSObject, PeerTransport, @unchecked Sendable {
    let kind: TransportKind = .multipeer
    let localPeerID: PeerID
    let mcPeerID: MCPeerID
    /// Election token: the persisted install ID, so roles never flip between launches.
    let token: String

    var onEvent: (@Sendable (TransportEvent) -> Void)? {
        get { stateLock.withLock { _onEvent } }
        set { stateLock.withLock { _onEvent = newValue } }
    }

    var onAudio: (@Sendable (AudioPacket, PeerID) -> Void)? {
        get { stateLock.withLock { _onAudio } }
        set { stateLock.withLock { _onAudio = newValue } }
    }

    /// Passed to `invitePeer`; the framework's own connect window is about 10 s anyway.
    static let inviteTimeout: TimeInterval = 10
    /// A handshake not connected after this long is abandoned and the session replaced.
    static let handshakeTimeout: TimeInterval = 12
    /// The non-inviting side re-announces itself if no invitation arrived within this time.
    static let fallbackDelay: TimeInterval = 15
    /// Recreating the advertiser changes its port, which breaks the other phone's cached endpoint.
    static let advertiserRestartSpacing: TimeInterval = 30
    static let pingInterval: TimeInterval = 1
    static let staleDiscoveryCheckDelay: TimeInterval = 5
    /// A discovery restart requested during a handshake waits this long and checks again.
    static let restartPostponement: TimeInterval = 2
    /// A dropped session stays open until its peers have left, at most this long, so a final `bye` can
    /// leave the device even over a stalling peer-to-peer link.
    static let byeDrainTimeout: TimeInterval = 1.2
    static let drainPollInterval: TimeInterval = 0.05
    /// Bye invitations to one peer are at least this far apart (they answer each declined invitation).
    static let byeInvitationSpacing: TimeInterval = 5
    static let byeInvitationTimeout: TimeInterval = 5
    /// A peer gives up on a link only after the liveness deadline plus a backoff delay, so an invitation
    /// arriving on a younger (and not suspect) link crossed our own handshake rather than replacing a ghost.
    static let ghostMinimumLinkAge: TimeInterval = LivenessMonitor.Configuration.multipeer.deadMinimum

    private enum Suppression {
        /// Disconnect was pressed here: invitations from the peer are declined.
        case local
        /// The peer said `bye(userDisconnect)`: don't invite, but accept its invitations.
        case remote
    }

    private struct Attempt {
        let id: Int
        let isInviter: Bool
        let watchdog: DispatchWorkItem
    }

    /// Everything known about one remote Multipeer identity. Queue-confined.
    private final class PeerRecord {
        let mcPeer: MCPeerID
        let id: PeerID
        var token: String?
        var protocolVersion: Int?
        /// Listed by discovery right now.
        var isListed = false
        var attempt: Attempt?
        var isConnected = false
        var connectedSince: MonotonicTime?
        var hasBeenConnected = false
        var liveness: LivenessMonitor?
        var backoff = ReconnectBackoff(schedule: .multipeer)
        var retry: DispatchWorkItem?
        var fallback: DispatchWorkItem?
        var suppression: Suppression?
        /// Connect was pressed: invite even if the election says the other phone should.
        var isManualOverride = false
        /// Transport epoch the peer last announced (discovery info or invitation); `nil` until one is seen.
        var remoteEpoch: UInt32?
        /// `remoteEpoch` when the peer said `bye(userDisconnect)`: `.remote` lasts only as long as that
        /// instance. `nil` (epoch unknown) never clears on its own.
        var suppressedAtEpoch: UInt32?
        /// Disconnect was pressed here and the peer still has to get a bye invitation.
        var needsByeInvitation = false
        var lastByeInvitation: MonotonicTime?
        var attemptsSinceLinkUp = 0
        var consecutiveFailures = 0
        var reportedState: LinkState?
        var reportedStatus: RemoteStatus?
        var roundTrip = RoundTripEstimator()

        init(mcPeer: MCPeerID, id: PeerID, token: String?, protocolVersion: Int?) {
            self.mcPeer = mcPeer
            self.id = id
            self.token = token
            self.protocolVersion = protocolVersion
        }

        var compatibility: PeerCompatibility {
            guard let protocolVersion, protocolVersion != IntercomProtocol.version else { return .compatible }
            return .incompatibleVersion
        }

        var advert: PeerAdvert {
            PeerAdvert(id: id, displayName: mcPeer.displayName, protocolVersion: protocolVersion, compatibility: compatibility)
        }

        func cancelTimers() {
            attempt?.watchdog.cancel()
            retry?.cancel()
            retry = nil
            fallback?.cancel()
            fallback = nil
        }
    }

    private final class PendingRestart {
        let deadline: MonotonicTime
        var includeAdvertiser: Bool
        let item: DispatchWorkItem

        init(deadline: MonotonicTime, includeAdvertiser: Bool, item: DispatchWorkItem) {
            self.deadline = deadline
            self.includeAdvertiser = includeAdvertiser
            self.item = item
        }
    }

    private let queue = DispatchQueue(label: "intercom.transport.multipeer", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _session: MCSession!
    private var _onEvent: (@Sendable (TransportEvent) -> Void)?
    private var _onAudio: (@Sendable (AudioPacket, PeerID) -> Void)?
    /// MCPeerID → PeerID for the receive thread.
    private var receivePeers: [MCPeerID: PeerID] = [:]
    /// Arrival time of the newest frame per peer, written by the receive thread.
    private var lastHeard: [MCPeerID: MonotonicTime] = [:]

    private let advertisedName: String
    /// Random per start (a stopped transport may be started again): lets the peer tell a restarted
    /// instance from the one that said `bye`.
    private var epoch: UInt32 = 0
    private var isStarted = false
    private var isAppActive = true
    private var localStatus = RemoteStatus()
    private var advertiser: MCNearbyServiceAdvertiser?
    private var lastAdvertiserStart: MonotonicTime?
    private var browser: MCNearbyServiceBrowser?
    /// Peers found by the current browser; invitations must go through the browser that found the peer.
    private var foundByBrowser: Set<MCPeerID> = []
    private var possiblyStale: Set<MCPeerID> = []
    private var staleCheck: DispatchWorkItem?
    private var pendingRestart: PendingRestart?
    private var peers: [MCPeerID: PeerRecord] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var nextAttemptID = 1
    private var rng = SplitMix64()
    private static let log = Logger(subsystem: "intercom", category: "transport.multipeer")

    init(installID: UUID, displayName: String) {
        let name = DisplayName.sanitized(displayName)
        localPeerID = PeerID(installID: installID)
        token = localPeerID.rawValue
        mcPeerID = PeerIdentity.peerID(displayName: name)
        advertisedName = name
        super.init()
        _session = makeSession()
    }

    deinit {
        _session.delegate = nil
        advertiser?.delegate = nil
        browser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        pingTimer?.cancel()
        _session.disconnect()
    }

    // MARK: - PeerTransport

    func start() {
        queue.async { [self] in startNow() }
    }

    func stop() {
        queue.async { [self] in stopNow() }
    }

    func connect(to peer: PeerID) {
        queue.async { [self] in
            guard isStarted, let record = peers.values.first(where: { $0.id == peer }) else {
                Self.log.error("connect \(peer.rawValue, privacy: .public) ignored: unknown peer")
                return
            }
            Self.log.notice("connect \(record.mcPeer.displayName, privacy: .public) requested")
            record.suppression = nil
            record.suppressedAtEpoch = nil
            record.needsByeInvitation = false
            record.isManualOverride = true
            record.backoff.reset()
            record.consecutiveFailures = 0
            record.retry?.cancel()
            record.retry = nil
            cancelFallback(record)
            evaluate(record)
        }
    }

    func disconnectAll() {
        queue.async { [self] in
            Self.log.notice("disconnect all requested")
            sendFrame(.bye(.userDisconnect), to: session.connectedPeers, mode: .reliable)
            for record in sortedPeers() {
                record.suppression = .local
                record.suppressedAtEpoch = nil
                record.isManualOverride = false
                record.needsByeInvitation = true
                record.retry?.cancel()
                record.retry = nil
                cancelFallback(record)
            }
            dropSession(reason: .userRequested, drainTimeout: Self.byeDrainTimeout)
            for record in sortedPeers() {
                if case .connecting? = record.reportedState {
                    report(record, .disconnected(.userRequested))
                }
                // The frame above may be lost; peers listed right now get the invitation form at once,
                // the others when discovery finds them.
                sendByeInvitationIfNeeded(record)
            }
        }
    }

    func sendAudio(_ packet: AudioPacket) {
        let session = self.session
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? MultipeerFrame.audio(packet).encoded() else { return }
        // A peer that just dropped makes `send` throw; liveness and the state callback handle that.
        try? session.send(data, toPeers: peers, with: .unreliable)
    }

    func sendControl(_ message: ControlMessage) {
        queue.async { [self] in
            sendFrame(.control(message), to: session.connectedPeers, mode: .reliable)
        }
    }

    func updateLocalStatus(_ status: RemoteStatus) {
        queue.async { [self] in
            guard status != localStatus else { return }
            localStatus = status
            sendFrame(.status(status), to: session.connectedPeers, mode: .reliable)
        }
    }

    func setAppActive(_ active: Bool) {
        queue.async { [self] in
            guard active != isAppActive else { return }
            isAppActive = active
            Self.log.notice("app \(active ? "active: backoff reset" : "in background", privacy: .public)")
            guard active, isStarted else { return }
            for record in sortedPeers() where !record.isConnected {
                record.backoff.reset()
                if record.retry != nil {
                    record.retry?.cancel()
                    record.retry = nil
                    evaluate(record)
                }
            }
            if !allWantedPeersConnected() {
                requestDiscoveryRestart(after: 0, includeAdvertiser: false, reason: "app became active")
            }
        }
    }

    // MARK: - Lifecycle (queue)

    private func startNow() {
        guard !isStarted else { return }
        isStarted = true
        epoch = UInt32(truncatingIfNeeded: rng.next())
        Self.log.notice("""
            starting: id \(self.localPeerID.rawValue, privacy: .public) as "\(self.mcPeerID.displayName, privacy: .public)" \
            protocol v\(IntercomProtocol.version, privacy: .public), epoch \(self.epoch, privacy: .public)
            """)
        startAdvertiser()
        startBrowser()
        startPingTimer()
    }

    private func stopNow() {
        guard isStarted else { return }
        Self.log.notice("stopping")
        sendFrame(.bye(.stopped), to: session.connectedPeers, mode: .reliable)
        // Cleared first so nothing below schedules a reconnect.
        isStarted = false
        cancelPendingRestart()
        staleCheck?.cancel()
        staleCheck = nil
        pingTimer?.cancel()
        pingTimer = nil
        stopAdvertiser()
        stopBrowser()
        dropSession(reason: .stopped, drainTimeout: Self.byeDrainTimeout)
        for record in peers.values {
            record.cancelTimers()
        }
        peers.removeAll()
        foundByBrowser.removeAll()
        possiblyStale.removeAll()
        stateLock.withLock {
            receivePeers.removeAll()
            lastHeard.removeAll()
        }
    }

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.livenessTick()
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: - Session (reference guarded by stateLock)

    private var session: MCSession {
        stateLock.withLock { _session }
    }

    private func makeSession() -> MCSession {
        let session = MCSession(peer: mcPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    /// Swaps in a fresh session and settles every peer the old one carried: connected peers go down with
    /// `reason`, handshakes in progress fail. With a `drainTimeout` the old session stays open until its
    /// peers have left (a peer that handles our `bye` drops its session at once) or the timeout passes,
    /// so a final `bye` has a chance to leave the device; a fixed short delay was not enough on a
    /// stalling peer-to-peer link.
    private func dropSession(reason: DisconnectReason, drainTimeout: TimeInterval) {
        let fresh = makeSession()
        let old: MCSession = stateLock.withLock {
            let old = _session!
            _session = fresh
            return old
        }
        old.delegate = nil
        if drainTimeout > 0 {
            Self.disconnectWhenDrained(old, queue: queue, deadline: MonotonicTime.now() + drainTimeout)
        } else {
            old.disconnect()
        }
        Self.log.notice("fresh MCSession (\(String(describing: reason), privacy: .public))")
        for record in sortedPeers() {
            if record.isConnected {
                linkDown(record, reason: reason)
            } else if record.attempt != nil {
                attemptFailed(record, reason: "session replaced (\(reason))", replaceSession: false)
            }
        }
    }

    /// Captures only the session, so a transport released meanwhile still closes it.
    private static func disconnectWhenDrained(_ session: MCSession, queue: DispatchQueue, deadline: MonotonicTime) {
        guard session.connectedPeers.isEmpty || MonotonicTime.now() >= deadline else {
            queue.asyncAfter(deadline: .now() + drainPollInterval) {
                disconnectWhenDrained(session, queue: queue, deadline: deadline)
            }
            return
        }
        session.disconnect()
    }

    // MARK: - Peers (queue)

    private func sortedPeers() -> [PeerRecord] {
        peers.values.sorted { $0.id < $1.id }
    }

    private static func normalizedToken(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(), !token.isEmpty else { return nil }
        return token
    }

    /// Returns the record for `mcPeer`, creating it if needed. The PeerID comes from the token (the
    /// peer's install ID); a peer without one gets a random ID for as long as this transport runs.
    private func record(for mcPeer: MCPeerID, token rawToken: String?, protocolVersion: Int?) -> (PeerRecord, isNew: Bool) {
        let token = Self.normalizedToken(rawToken)
        if let existing = peers[mcPeer] {
            if let token { existing.token = token }
            if let protocolVersion { existing.protocolVersion = protocolVersion }
            return (existing, false)
        }
        let id = token.flatMap(UUID.init(uuidString:)).map(PeerID.init(installID:))
            ?? PeerID(rawValue: "mc-" + UUID().uuidString.lowercased())
        if let stale = peers.values.first(where: { $0.id == id }) {
            // Same install under a new Multipeer identity (renamed, which restarts its transport).
            Self.log.notice("\(id.rawValue, privacy: .public) reappeared as \"\(mcPeer.displayName, privacy: .public)\"; forgetting \"\(stale.mcPeer.displayName, privacy: .public)\"")
            if stale.isConnected || stale.attempt != nil {
                dropSession(reason: .remoteBye(.replaced), drainTimeout: 0)
            }
            stale.cancelTimers()
            peers[stale.mcPeer] = nil
            foundByBrowser.remove(stale.mcPeer)
            stateLock.withLock {
                receivePeers[stale.mcPeer] = nil
                lastHeard[stale.mcPeer] = nil
            }
        }
        let record = PeerRecord(mcPeer: mcPeer, id: id, token: token, protocolVersion: protocolVersion)
        peers[mcPeer] = record
        stateLock.withLock { receivePeers[mcPeer] = id }
        return (record, true)
    }

    private func forget(_ record: PeerRecord) {
        record.cancelTimers()
        peers[record.mcPeer] = nil
        stateLock.withLock {
            receivePeers[record.mcPeer] = nil
            lastHeard[record.mcPeer] = nil
        }
    }

    private func report(_ record: PeerRecord, _ state: LinkState) {
        guard record.reportedState != state else { return }
        record.reportedState = state
        emit(.linkStateChanged(record.id, state))
    }

    private func emit(_ event: TransportEvent) {
        if case .linkStateChanged(let peer, let state) = event {
            Self.log.notice("link \(peer.rawValue, privacy: .public): \(String(describing: state), privacy: .public)")
        }
        onEvent?(event)
    }

    @discardableResult
    private func sendFrame(_ frame: MultipeerFrame, to peers: [MCPeerID], mode: MCSessionSendDataMode) -> Bool {
        guard !peers.isEmpty, let data = try? frame.encoded() else { return false }
        do {
            try session.send(data, toPeers: peers, with: mode)
            return true
        } catch {
            Self.log.error("send failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `true` when the local side should send the invitation. Without the remote token and with equal
    /// names no shared tie-break exists; then nobody invites on a guess (both would) and the fallback
    /// re-announcement lets fresh discovery info settle it.
    private func isElectedInviter(_ record: PeerRecord) -> Bool {
        let localName = mcPeerID.displayName
        let remoteName = record.mcPeer.displayName
        if record.token == nil, localName == remoteName {
            return false
        }
        return PeerElection.shouldInitiate(localToken: token, remoteToken: record.token,
                                           localTieBreaker: localName, remoteTieBreaker: remoteName)
    }

    // MARK: - Connecting (queue)

    /// Decides what to do next for a peer without a link: invite, wait for the other side, or wait for
    /// discovery. Called on discovery, when a backoff delay ends and on manual connect.
    private func evaluate(_ record: PeerRecord) {
        guard isStarted, peers[record.mcPeer] === record, !record.isConnected, record.attempt == nil,
              record.retry == nil, record.suppression == nil else { return }
        guard record.compatibility == .compatible || record.isManualOverride else { return }
        guard let browser, foundByBrowser.contains(record.mcPeer) else {
            ensureDiscoveryRunning()
            return
        }
        if record.isManualOverride || isElectedInviter(record) {
            invite(record, using: browser)
        } else {
            scheduleFallback(record)
        }
    }

    private func invite(_ record: PeerRecord, using browser: MCNearbyServiceBrowser) {
        cancelFallback(record)
        beginAttempt(record, isInviter: true)
        Self.log.notice("""
            inviting \(record.mcPeer.displayName, privacy: .public) (attempt \(record.attemptsSinceLinkUp, privacy: .public)\
            \(record.isManualOverride ? ", manual" : "", privacy: .public))
            """)
        browser.invitePeer(record.mcPeer, to: session, withContext: MultipeerInvitation.connect(token: token, epoch: epoch).encoded(),
                           timeout: Self.inviteTimeout)
    }

    private func beginAttempt(_ record: PeerRecord, isInviter: Bool) {
        let id = nextAttemptID
        nextAttemptID += 1
        record.attemptsSinceLinkUp += 1
        let watchdog = DispatchWorkItem { [weak self, weak record] in
            guard let self, let record, record.attempt?.id == id else { return }
            self.attemptFailed(record, reason: "not connected within \(Int(Self.handshakeTimeout)) s", replaceSession: true)
        }
        record.attempt = Attempt(id: id, isInviter: isInviter, watchdog: watchdog)
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: watchdog)
        report(record, .connecting(attempt: record.attemptsSinceLinkUp))
    }

    /// A handshake did not complete. The session is replaced (when no other peer is connected on it)
    /// so the next attempt starts clean, and the next one is scheduled on the backoff.
    private func attemptFailed(_ record: PeerRecord, reason: String, replaceSession: Bool) {
        guard let attempt = record.attempt else { return }
        attempt.watchdog.cancel()
        record.attempt = nil
        record.consecutiveFailures += 1
        Self.log.error("""
            handshake with \(record.mcPeer.displayName, privacy: .public) failed: \(reason, privacy: .public) \
            (\(attempt.isInviter ? "we invited" : "we accepted", privacy: .public), failure \(record.consecutiveFailures, privacy: .public))
            """)
        if replaceSession, session.connectedPeers.isEmpty {
            dropSession(reason: .transportError("handshake failed"), drainTimeout: 0)
        }
        guard isStarted else { return }
        if !record.isListed, !record.hasBeenConnected, !record.isConnected, record.suppression == nil {
            // Discovery lost the peer during the handshake (or only its invitation ever reached us): no
            // retry can reach it, so the row leaves "Connecting…" and the record goes. `foundPeer` or its
            // next invitation brings it back. The `peerLost` sent while the row was connecting did not
            // remove it, so it is sent again now that the row is merely discovered.
            Self.log.info("forgetting \(record.mcPeer.displayName, privacy: .public): not listed after a failed handshake")
            report(record, .discovered)
            emit(.peerLost(record.id))
            if peers[record.mcPeer] === record {
                forget(record)
            }
            return
        }
        if record.consecutiveFailures % 2 == 0 {
            // Repeated failures often mean stale Bonjour data for the peer.
            requestDiscoveryRestart(after: 0, includeAdvertiser: false, reason: "repeated handshake failures")
        }
        scheduleRetry(record)
    }

    private func scheduleRetry(_ record: PeerRecord) {
        record.retry?.cancel()
        record.retry = nil
        guard isStarted, peers[record.mcPeer] === record, !record.isConnected, record.attempt == nil,
              record.suppression == nil else { return }
        let delay = record.backoff.nextDelay(using: &rng)
        let item = DispatchWorkItem { [weak self, weak record] in
            guard let self, let record else { return }
            record.retry = nil
            self.evaluate(record)
        }
        record.retry = item
        Self.log.notice("next attempt with \(record.mcPeer.displayName, privacy: .public) in \(String(format: "%.2f", delay), privacy: .public)s")
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleFallback(_ record: PeerRecord) {
        guard record.fallback == nil else { return }
        let item = DispatchWorkItem { [weak self, weak record] in
            guard let self, let record else { return }
            record.fallback = nil
            guard self.isStarted, !record.isConnected, record.attempt == nil, record.suppression == nil else { return }
            Self.log.notice("no invitation from \(record.mcPeer.displayName, privacy: .public) within \(Int(Self.fallbackDelay), privacy: .public) s: re-announcing")
            self.requestDiscoveryRestart(after: 0, includeAdvertiser: true, reason: "waiting for an invitation")
        }
        record.fallback = item
        queue.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: item)
    }

    private func cancelFallback(_ record: PeerRecord) {
        record.fallback?.cancel()
        record.fallback = nil
    }

    private func linkUp(_ record: PeerRecord) {
        let now = MonotonicTime.now()
        record.attempt?.watchdog.cancel()
        record.attempt = nil
        record.isConnected = true
        record.hasBeenConnected = true
        record.connectedSince = now
        var liveness = LivenessMonitor(configuration: .multipeer, now: now)
        liveness.isLocalInBackground = !isAppActive
        record.liveness = liveness
        record.attemptsSinceLinkUp = 0
        record.consecutiveFailures = 0
        record.isManualOverride = false
        record.reportedStatus = nil
        record.roundTrip.reset()
        record.retry?.cancel()
        record.retry = nil
        cancelFallback(record)
        stateLock.withLock { lastHeard[record.mcPeer] = now }
        report(record, .connected(path: .unknown, isResumption: false))
        sendFrame(.status(localStatus), to: [record.mcPeer], mode: .reliable)
        sendPing(record)
        pauseDiscoveryIfAllConnected()
    }

    private func linkDown(_ record: PeerRecord, reason: DisconnectReason) {
        guard record.isConnected else { return }
        let now = MonotonicTime.now()
        record.isConnected = false
        if let since = record.connectedSince {
            record.backoff.linkWentDown(upFor: now - since)
        }
        record.connectedSince = nil
        record.liveness = nil
        record.reportedStatus = nil
        stateLock.withLock { lastHeard[record.mcPeer] = nil }
        report(record, .disconnected(reason))
        guard isStarted else { return }
        // Discovery was paused while connected; both phones must find each other again.
        ensureDiscoveryRunning()
        scheduleRetry(record)
    }

    // MARK: - Liveness (queue)

    private func livenessTick() {
        guard isStarted else { return }
        let now = MonotonicTime.now()
        let heard = stateLock.withLock { lastHeard }
        for record in sortedPeers() where record.isConnected {
            guard var liveness = record.liveness else { continue }
            if let at = heard[record.mcPeer] {
                liveness.recordReceive(at: at)
            }
            liveness.isLocalInBackground = !isAppActive
            record.liveness = liveness
            switch liveness.health(at: now) {
            case .alive:
                if record.reportedState == .suspect {
                    report(record, .connected(path: .unknown, isResumption: true))
                }
            case .suspect:
                if record.reportedState != .suspect {
                    Self.log.notice("\(record.mcPeer.displayName, privacy: .public) silent for \(String(format: "%.1f", liveness.silence(at: now)), privacy: .public)s: suspect")
                    report(record, .suspect)
                }
            case .dead:
                Self.log.error("\(record.mcPeer.displayName, privacy: .public) silent for \(String(format: "%.1f", liveness.silence(at: now)), privacy: .public)s: link dead")
                if session.connectedPeers.allSatisfy({ $0 == record.mcPeer }) {
                    dropSession(reason: .timeout, drainTimeout: 0)
                } else {
                    linkDown(record, reason: .timeout)
                }
                continue
            }
            sendPing(record)
        }
    }

    private func sendPing(_ record: PeerRecord) {
        let now = MonotonicTime.now()
        let ping = record.roundTrip.makePing(nowMs: now.milliseconds)
        let sent = sendFrame(.ping(sequence: ping.id, status: localStatus), to: [record.mcPeer], mode: .unreliable)
        if sent {
            record.liveness?.recordSendSuccess(at: now)
        } else {
            record.liveness?.recordSendError(at: now)
        }
    }

    private func updateRemoteStatus(_ record: PeerRecord, _ status: RemoteStatus) {
        guard record.reportedStatus != status else { return }
        record.reportedStatus = status
        emit(.remoteStatus(status, from: record.id))
    }

    private func handleFrame(_ frame: MultipeerFrame, from mcPeer: MCPeerID, session: MCSession) {
        guard session === self.session, let record = peers[mcPeer] else { return }
        switch frame {
        case .audio:
            break
        case .control(let message):
            emit(.control(message, from: record.id))
        case .ping(let sequence, let status):
            sendFrame(.pong(sequence: sequence, status: localStatus), to: [mcPeer], mode: .unreliable)
            updateRemoteStatus(record, status)
        case .pong(let sequence, let status):
            let now = MonotonicTime.now()
            if record.roundTrip.receivePong(ControlMessage.Ping(id: sequence, sentAtMs: 0), nowMs: now.milliseconds) != nil,
               let rtt = record.roundTrip.smoothedRTTMs {
                emit(.roundTrip(record.id, ms: rtt))
            }
            updateRemoteStatus(record, status)
        case .status(let status):
            updateRemoteStatus(record, status)
        case .bye(let reason):
            Self.log.notice("bye(\(String(describing: reason), privacy: .public)) from \(mcPeer.displayName, privacy: .public)")
            if reason == .userDisconnect {
                peerDisconnectedByUser(record)
                return
            }
            guard record.isConnected else { return }
            if session.connectedPeers.allSatisfy({ $0 == mcPeer }) {
                dropSession(reason: .remoteBye(reason), drainTimeout: 0)
            } else {
                linkDown(record, reason: .remoteBye(reason))
            }
        }
    }

    // MARK: - User disconnects (queue)

    /// The peer's user pressed Disconnect: a `bye(userDisconnect)` frame, or a bye invitation when that
    /// frame was lost. Stops dialling the peer and ends any link or handshake without scheduling a retry.
    /// The disconnect is reported even when the link was already down (redialling after a transport
    /// error), so the row stops showing "Reconnecting…".
    private func peerDisconnectedByUser(_ record: PeerRecord) {
        // Both users pressed Disconnect: ours stays in force (`.remote` would accept the peer's invitations
        // and end with its next restart), and there is no link or retry left to settle.
        guard record.suppression != .local else { return }
        let reason = DisconnectReason.remoteBye(.userDisconnect)
        record.suppression = .remote
        record.suppressedAtEpoch = record.remoteEpoch
        record.isManualOverride = false
        record.retry?.cancel()
        record.retry = nil
        cancelFallback(record)
        let hadAttempt = record.attempt != nil
        if let attempt = record.attempt {
            // Not through attemptFailed, which would schedule the next attempt.
            attempt.watchdog.cancel()
            record.attempt = nil
        }
        if (record.isConnected || hadAttempt), session.connectedPeers.allSatisfy({ $0 == record.mcPeer }) {
            dropSession(reason: reason, drainTimeout: 0)
        } else if record.isConnected {
            linkDown(record, reason: reason)
        }
        report(record, .disconnected(reason))
    }

    /// Answers a declined invitation (or follows a Disconnect) with a bye invitation, so the peer learns
    /// why: a plain decline looks like any failed handshake and it would redial forever. Invitations must
    /// go through the browser that found the peer; until then the invitation stays pending. It goes into
    /// a throwaway session so nothing about it can touch the real one.
    private func sendByeInvitationIfNeeded(_ record: PeerRecord) {
        guard isStarted, record.needsByeInvitation, record.suppression == .local,
              let browser, foundByBrowser.contains(record.mcPeer) else { return }
        let now = MonotonicTime.now()
        if let last = record.lastByeInvitation, now - last < Self.byeInvitationSpacing {
            return
        }
        record.lastByeInvitation = now
        record.needsByeInvitation = false
        Self.log.notice("telling \(record.mcPeer.displayName, privacy: .public) about the Disconnect with a bye invitation")
        let throwaway = MCSession(peer: mcPeerID, securityIdentity: nil, encryptionPreference: .required)
        browser.invitePeer(record.mcPeer, to: throwaway, withContext: MultipeerInvitation.bye(token: token, epoch: epoch).encoded(),
                           timeout: Self.byeInvitationTimeout)
        // Kept alive until the invitation has certainly been answered or timed out.
        queue.asyncAfter(deadline: .now() + Self.byeInvitationTimeout + 1) {
            throwaway.disconnect()
        }
    }

    /// A `bye(userDisconnect)` binds only the instance that sent it. Once the peer shows another epoch
    /// (it restarted its intercom or the app), `.remote` ends and the election decides again who invites;
    /// merely being listed again after a Bonjour flap does not count.
    private func noteRemoteEpoch(_ record: PeerRecord, _ epoch: UInt32?) {
        guard let epoch else { return }
        if record.suppression == .remote, let suppressedAt = record.suppressedAtEpoch, suppressedAt != epoch {
            Self.log.notice("\(record.mcPeer.displayName, privacy: .public) restarted: clearing its remote disconnect")
            record.suppression = nil
            record.suppressedAtEpoch = nil
            record.backoff.reset()
        }
        record.remoteEpoch = epoch
    }

    // MARK: - Discovery (queue)

    private func startAdvertiser() {
        guard advertiser == nil else { return }
        let discoveryInfo = [
            IntercomProtocol.DiscoveryKey.token: token,
            IntercomProtocol.DiscoveryKey.name: advertisedName,
            IntercomProtocol.DiscoveryKey.version: String(IntercomProtocol.version),
            IntercomProtocol.DiscoveryKey.epoch: String(epoch),
        ]
        let advertiser = MCNearbyServiceAdvertiser(peer: mcPeerID, discoveryInfo: discoveryInfo,
                                                   serviceType: IntercomProtocol.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        lastAdvertiserStart = .now()
        Self.log.info("advertising started")
    }

    private func stopAdvertiser() {
        guard let advertiser else { return }
        advertiser.delegate = nil
        advertiser.stopAdvertisingPeer()
        self.advertiser = nil
        Self.log.info("advertising stopped")
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let browser = MCNearbyServiceBrowser(peer: mcPeerID, serviceType: IntercomProtocol.serviceType)
        browser.delegate = self
        possiblyStale.formUnion(foundByBrowser)
        foundByBrowser.removeAll()
        self.browser = browser
        browser.startBrowsingForPeers()
        scheduleStaleCheck()
        Self.log.info("browsing started")
    }

    private func stopBrowser() {
        staleCheck?.cancel()
        staleCheck = nil
        guard let browser else { return }
        browser.delegate = nil
        browser.stopBrowsingForPeers()
        self.browser = nil
        possiblyStale.formUnion(foundByBrowser)
        foundByBrowser.removeAll()
        Self.log.info("browsing stopped")
    }

    private func allWantedPeersConnected() -> Bool {
        let wanted = peers.values.filter {
            $0.suppression == nil && ($0.hasBeenConnected || ($0.isListed && $0.compatibility == .compatible))
        }
        return !wanted.isEmpty && wanted.allSatisfy(\.isConnected)
    }

    /// An ongoing peer-to-peer browse degrades the live link (TN3213), so browsing pauses while every
    /// peer the intercom wants is connected; a dropped link starts it again.
    ///
    /// The advertiser keeps running. Stopping advertiser *and* browser leaves Multipeer Connectivity with
    /// no Bonjour activity at all, and in a two-instance test the session then stopped carrying data
    /// about two seconds later (pings and `bye` lost, link declared dead). Stopping either one alone did
    /// not affect the session. An advertised peer can also be invited again right after a restart.
    private func pauseDiscoveryIfAllConnected() {
        guard allWantedPeersConnected(), browser != nil else { return }
        Self.log.notice("all peers connected: pausing browsing (advertising continues)")
        cancelPendingRestart()
        stopBrowser()
    }

    private func ensureDiscoveryRunning() {
        guard isStarted else { return }
        startAdvertiser()
        startBrowser()
    }

    /// Coalesces restart requests from everywhere: the earliest deadline wins and the advertiser flags
    /// merge. The restart itself never runs during a handshake.
    private func requestDiscoveryRestart(after delay: TimeInterval, includeAdvertiser: Bool, reason: String) {
        guard isStarted else { return }
        let deadline = MonotonicTime.now() + delay
        var includeAdvertiser = includeAdvertiser
        if let pending = pendingRestart {
            if pending.deadline <= deadline {
                pending.includeAdvertiser = pending.includeAdvertiser || includeAdvertiser
                return
            }
            pending.item.cancel()
            includeAdvertiser = includeAdvertiser || pending.includeAdvertiser
        }
        let item = DispatchWorkItem { [weak self] in
            self?.performDiscoveryRestart()
        }
        pendingRestart = PendingRestart(deadline: deadline, includeAdvertiser: includeAdvertiser, item: item)
        Self.log.notice("discovery restart in \(String(format: "%.1f", delay), privacy: .public)s: \(reason, privacy: .public)")
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelPendingRestart() {
        pendingRestart?.item.cancel()
        pendingRestart = nil
    }

    private func performDiscoveryRestart() {
        guard let pending = pendingRestart, isStarted else { return }
        pendingRestart = nil
        guard !allWantedPeersConnected() else { return }
        if peers.values.contains(where: { $0.attempt != nil }) {
            // Recreating the browser or advertiser under a pending invitation kills that handshake.
            requestDiscoveryRestart(after: Self.restartPostponement, includeAdvertiser: pending.includeAdvertiser,
                                    reason: "postponed: handshake in progress")
            return
        }
        let now = MonotonicTime.now()
        if advertiser == nil {
            startAdvertiser()
        } else if pending.includeAdvertiser,
                  lastAdvertiserStart.map({ now - $0 >= Self.advertiserRestartSpacing }) ?? true {
            Self.log.notice("re-announcing: recreating the advertiser")
            stopAdvertiser()
            startAdvertiser()
        }
        Self.log.notice("restarting browsing")
        stopBrowser()
        startBrowser()
    }

    /// A restarted browser starts empty; peers the previous one found are reported lost only if this
    /// one does not find them again soon.
    private func scheduleStaleCheck() {
        staleCheck?.cancel()
        staleCheck = nil
        guard !possiblyStale.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.browser != nil else { return }
            self.staleCheck = nil
            let gone = self.possiblyStale.subtracting(self.foundByBrowser)
            self.possiblyStale.removeAll()
            for mcPeer in gone {
                self.peerNoLongerListed(mcPeer)
            }
        }
        staleCheck = item
        queue.asyncAfter(deadline: .now() + Self.staleDiscoveryCheckDelay, execute: item)
    }

    private func peerNoLongerListed(_ mcPeer: MCPeerID) {
        guard let record = peers[mcPeer], record.isListed else { return }
        record.isListed = false
        cancelFallback(record)
        Self.log.info("\(mcPeer.displayName, privacy: .public) no longer listed")
        let isForgotten = !record.hasBeenConnected && !record.isConnected && record.attempt == nil
        if isForgotten, record.reportedState != nil {
            // A handshake that failed while the peer was still listed left the row "Connecting…"; the
            // controller removes only discovered rows.
            report(record, .discovered)
        }
        emit(.peerLost(record.id))
        if isForgotten {
            forget(record)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async { [self] in
            guard isStarted, browser === self.browser, peerID != mcPeerID else { return }
            let version = info?[IntercomProtocol.DiscoveryKey.version].flatMap { Int($0) }
            let (record, isNew) = self.record(for: peerID, token: info?[IntercomProtocol.DiscoveryKey.token],
                                              protocolVersion: version)
            foundByBrowser.insert(peerID)
            possiblyStale.remove(peerID)
            let wasListed = record.isListed
            record.isListed = true
            noteRemoteEpoch(record, info?[IntercomProtocol.DiscoveryKey.epoch].flatMap { UInt32($0) })
            Self.log.info("""
                found \(peerID.displayName, privacy: .public) (\(record.id.rawValue, privacy: .public), \
                v\(version.map(String.init) ?? "?", privacy: .public))
                """)
            if isNew || !wasListed {
                emit(.peerDiscovered(record.advert))
            }
            if record.reportedState == nil {
                report(record, .discovered)
            }
            sendByeInvitationIfNeeded(record)
            evaluate(record)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [self] in
            guard isStarted, browser === self.browser else { return }
            foundByBrowser.remove(peerID)
            peerNoLongerListed(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async { [self] in
            guard isStarted, browser === self.browser else { return }
            Self.log.error("browsing failed: \(String(describing: error), privacy: .public)")
            emit(.warning(.browserFailed(error.localizedDescription)))
            stopBrowser()
            requestDiscoveryRestart(after: 3, includeAdvertiser: false, reason: "browsing failed")
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        queue.async { [self] in
            guard isStarted, advertiser === self.advertiser else {
                invitationHandler(false, nil)
                return
            }
            let invitation = context.flatMap(MultipeerInvitation.decode)
            if case .bye(_, let byeEpoch)? = invitation {
                invitationHandler(false, nil)
                guard let record = peers[peerID] else {
                    Self.log.info("ignoring bye invitation from unknown \(peerID.displayName, privacy: .public)")
                    return
                }
                Self.log.notice("bye invitation from \(peerID.displayName, privacy: .public): disconnected on the other iPhone")
                record.remoteEpoch = byeEpoch
                peerDisconnectedByUser(record)
                return
            }
            let remoteToken = invitation?.token ?? context.map { String(decoding: $0, as: UTF8.self) }
            let (record, isNew) = self.record(for: peerID, token: remoteToken, protocolVersion: nil)
            if isNew {
                emit(.peerDiscovered(record.advert))
            }
            noteRemoteEpoch(record, invitation?.epoch)
            if record.suppression == .local {
                Self.log.notice("declining invitation from \(peerID.displayName, privacy: .public): disconnected by the user")
                invitationHandler(false, nil)
                record.needsByeInvitation = true
                sendByeInvitationIfNeeded(record)
                return
            }
            if record.compatibility != .compatible {
                // It would never answer our pings, so the link would die every few seconds.
                Self.log.error("declining invitation from \(peerID.displayName, privacy: .public): protocol v\(record.protocolVersion ?? 0, privacy: .public), we speak v\(IntercomProtocol.version, privacy: .public)")
                emit(.warning(.incompatibleVersion(record.id)))
                invitationHandler(false, nil)
                return
            }
            if record.isConnected || session.connectedPeers.contains(peerID) {
                // The peer invites once it has given up on the link, which takes the liveness deadline plus
                // a backoff delay: then ours is a stale ghost. An invitation on a younger link that is not
                // suspect (or one whose `.connected` callback is still queued) crossed our own handshake,
                // for example a manual-connect retry already in flight; replacing the session would kill
                // the fresh link for an invitation whose session the peer has already discarded.
                let now = MonotonicTime.now()
                let linkAge = record.connectedSince.map { now - $0 }
                let isCrossedHandshake: Bool
                if record.isConnected {
                    isCrossedHandshake = (linkAge ?? .infinity) < Self.ghostMinimumLinkAge && record.reportedState != .suspect
                } else {
                    isCrossedHandshake = record.attempt != nil
                }
                if isCrossedHandshake {
                    Self.log.notice("""
                        declining invitation from \(peerID.displayName, privacy: .public): link up for only \
                        \(linkAge.map { String(format: "%.1f s", $0) } ?? "an instant", privacy: .public), likely crossed with our handshake
                        """)
                    invitationHandler(false, nil)
                    return
                }
                Self.log.notice("invitation from \(peerID.displayName, privacy: .public), which we think is connected: replacing the stale session")
                if record.isConnected, !session.connectedPeers.allSatisfy({ $0 == peerID }) {
                    linkDown(record, reason: .remoteBye(.replaced))
                } else {
                    dropSession(reason: .remoteBye(.replaced), drainTimeout: 0)
                }
            }
            if let attempt = record.attempt {
                if attempt.isInviter, isElectedInviter(record) {
                    Self.log.notice("declining invitation from \(peerID.displayName, privacy: .public): our own invitation takes precedence")
                    invitationHandler(false, nil)
                    return
                }
                // Their invitation wins, or they retried an invitation we already accepted: an MCSession
                // must not carry two handshakes with one peer, so start over on a fresh one.
                Self.log.notice("""
                    invitation from \(peerID.displayName, privacy: .public) supersedes our \
                    \(attempt.isInviter ? "invitation" : "earlier acceptance", privacy: .public)
                    """)
                attempt.watchdog.cancel()
                record.attempt = nil
                if session.connectedPeers.isEmpty {
                    dropSession(reason: .remoteBye(.replaced), drainTimeout: 0)
                }
            }
            record.suppression = nil
            record.retry?.cancel()
            record.retry = nil
            cancelFallback(record)
            beginAttempt(record, isInviter: false)
            Self.log.notice("accepting invitation from \(peerID.displayName, privacy: .public) (attempt \(record.attemptsSinceLinkUp, privacy: .public))")
            invitationHandler(true, session)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async { [self] in
            guard isStarted, advertiser === self.advertiser else { return }
            Self.log.error("advertising failed: \(String(describing: error), privacy: .public)")
            emit(.warning(.listenerFailed(error.localizedDescription)))
            stopAdvertiser()
            requestDiscoveryRestart(after: 3, includeAdvertiser: false, reason: "advertising failed")
        }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [self] in
            guard session === self.session else { return }
            Self.log.info("\(peerID.displayName, privacy: .public) -> \(Self.describe(state), privacy: .public)")
            guard let record = peers[peerID] else { return }
            switch state {
            case .connecting:
                break
            case .connected:
                guard !record.isConnected else { return }
                guard record.suppression == nil else {
                    // A bye arrived while this handshake was finishing (the session is replaced for that
                    // when it carries no one else): the peer wants no link.
                    Self.log.notice("\(peerID.displayName, privacy: .public) connected after a disconnect: closing")
                    session.cancelConnectPeer(peerID)
                    return
                }
                linkUp(record)
            case .notConnected:
                if record.isConnected {
                    if session.connectedPeers.isEmpty {
                        dropSession(reason: .transportError("Multipeer Connectivity dropped the peer"), drainTimeout: 0)
                    } else {
                        linkDown(record, reason: .transportError("Multipeer Connectivity dropped the peer"))
                    }
                } else if record.attempt != nil {
                    attemptFailed(record, reason: "Multipeer Connectivity reported notConnected", replaceSession: true)
                }
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let frame = MultipeerFrame.decode(data) else { return }
        let now = MonotonicTime.now()
        stateLock.lock()
        let isCurrentSession = session === _session
        let peer = receivePeers[peerID]
        if isCurrentSession, peer != nil {
            lastHeard[peerID] = now
        }
        let onAudio = _onAudio
        stateLock.unlock()
        guard isCurrentSession else { return }
        if case .audio(let packet) = frame {
            if let peer {
                onAudio?(packet, peer)
            }
            return
        }
        queue.async { [self] in
            handleFrame(frame, from: peerID, session: session)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Streams are not used; everything travels as discrete messages.
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Resources are not used.
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Resources are not used.
    }

    private static func describe(_ state: MCSessionState) -> String {
        switch state {
        case .notConnected: return "notConnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}
