import Foundation
import MultipeerConnectivity
import os.log

/// Peer discovery and data transport on top of MultipeerConnectivity.
///
/// Both iPhones advertise *and* browse for the same service type, so either one finds the other
/// regardless of who launched first. `PeerElection` decides which side sends the invitation; the
/// other side only accepts. If the non-initiating side sees no invitation for a while it bounces
/// its own discovery so the initiator re-discovers it and invites again — it never invites on its
/// own, which keeps a single handshake per peer pair.
///
/// Audio frames go out with `.unreliable` (drop rather than delay); control messages with `.reliable`.
///
/// State is confined to `queue`. Delegate callbacks from MultipeerConnectivity arrive on an
/// internal framework thread and are forwarded to `queue`, except received audio, which is handed
/// to `onAudio` immediately. The session reference and the callbacks are read from other threads
/// (audio capture queue, main thread) and are therefore guarded by `stateLock`.
final class MultipeerTransport: NSObject {
    struct DiscoveredPeer: Equatable {
        let peerID: MCPeerID
        let token: String?
        let protocolVersion: Int?
    }

    enum Event {
        case discovered(DiscoveredPeer)
        case lost(MCPeerID)
        case stateChanged(MCPeerID, MCSessionState)
        case control(ControlMessage, from: MCPeerID)
        case failure(String)
    }

    /// Where a handshake with a given peer currently stands.
    private enum Attempt {
        case inviting
        case accepted
        case connected
    }

    let peerID: MCPeerID
    let token: String

    /// Delivered on the transport's serial queue.
    var onEvent: (@Sendable (Event) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); _onEvent = newValue; stateLock.unlock() }
    }

    /// Delivered on MultipeerConnectivity's receive thread; must be cheap and thread-safe.
    var onAudio: (@Sendable (AudioPacket, MCPeerID) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onAudio }
        set { stateLock.lock(); _onAudio = newValue; stateLock.unlock() }
    }

    /// When `false`, discovered peers are only reported and `invite(_:)` must be called explicitly.
    var autoConnect = true

    /// How long the non-initiating side waits for an invitation before re-announcing itself.
    var fallbackDelay: TimeInterval = 15
    var inviteTimeout: TimeInterval = 20

    private let queue = DispatchQueue(label: "intercom.transport", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _session: MCSession
    private var _onEvent: (@Sendable (Event) -> Void)?
    private var _onAudio: (@Sendable (AudioPacket, MCPeerID) -> Void)?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var isStarted = false
    private var discovered: [MCPeerID: DiscoveredPeer] = [:]
    private var attempts: [MCPeerID: Attempt] = [:]
    private var failedAttempts: [MCPeerID: Int] = [:]
    /// Peers the user disconnected on purpose; not reconnected until `invite(_:)` or `start()`.
    private var suppressed: Set<MCPeerID> = []
    private var fallbackTimers: [MCPeerID: DispatchWorkItem] = [:]
    private var pendingRestart: DispatchWorkItem?
    private let discoveryInfo: [String: String]
    private static let log = OSLog(subsystem: "intercom", category: "transport")

    init(peerID: MCPeerID, displayName: String) {
        self.peerID = peerID
        token = PeerElection.makeToken()
        discoveryInfo = [
            IntercomProtocol.DiscoveryKey.token: token,
            IntercomProtocol.DiscoveryKey.name: displayName,
            IntercomProtocol.DiscoveryKey.version: String(IntercomProtocol.version),
        ]
        _session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        _session.delegate = self
    }

    deinit {
        _session.delegate = nil
        advertiser?.delegate = nil
        browser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        _session.disconnect()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard !isStarted else { return }
            isStarted = true
            suppressed.removeAll()
            failedAttempts.removeAll()
            startDiscovery()
        }
    }

    func stop() {
        queue.async { [self] in
            guard isStarted else { return }
            isStarted = false
            pendingRestart?.cancel()
            pendingRestart = nil
            cancelAllFallbacks()
            stopDiscovery()
            discovered.removeAll()
            sendControlNow(.bye)
            replaceSession(disconnectingAfter: 0.2)
        }
    }

    /// Manually invites a discovered peer, clearing any earlier manual disconnect.
    func invite(_ peer: MCPeerID) {
        queue.async { [self] in
            suppressed.remove(peer)
            failedAttempts[peer] = nil
            inviteNow(peer)
        }
    }

    /// Drops every connection on purpose. Discovery keeps running, but the dropped peers are not
    /// reconnected automatically until `invite(_:)` is called for them.
    func disconnectAll() {
        queue.async { [self] in
            let connected = session.connectedPeers
            suppressed.formUnion(connected)
            sendControlNow(.bye)
            replaceSession(disconnectingAfter: 0.2)
        }
    }

    /// Thread-safe snapshot of the connected peers.
    var connectedPeers: [MCPeerID] {
        session.connectedPeers
    }

    // MARK: - Sending

    /// Sends one audio frame to every connected peer without waiting for acknowledgements.
    func sendAudio(_ packet: AudioPacket) {
        let session = self.session
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? WireMessage.audio(packet).encoded() else { return }
        do {
            try session.send(data, toPeers: peers, with: .unreliable)
        } catch {
            // A peer that just dropped makes `send` throw; the state change callback handles it.
        }
    }

    func sendControl(_ message: ControlMessage) {
        queue.async { [self] in
            sendControlNow(message)
        }
    }

    private func sendControlNow(_ message: ControlMessage) {
        let session = self.session
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? WireMessage.control(message).encoded() else { return }
        do {
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            os_log("Control send failed: %{public}@", log: Self.log, type: .error, String(describing: error))
        }
    }

    // MARK: - Session (reference guarded by stateLock)

    private var session: MCSession {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _session
    }

    /// Swaps in a fresh session. The old one is disconnected after `delay` so a final control
    /// message has a chance to leave the device. Peers that were connected are reported as
    /// `.notConnected` immediately because the old session's delegate is detached.
    private func replaceSession(disconnectingAfter delay: TimeInterval) {
        let fresh = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        fresh.delegate = self
        stateLock.lock()
        let old = _session
        _session = fresh
        stateLock.unlock()

        old.delegate = nil
        // Connected peers and peers mid-handshake will never get a delegate callback from the old
        // session any more, so report them as gone right here.
        let affected = Set(old.connectedPeers).union(attempts.keys)
        attempts.removeAll()
        if delay > 0 {
            queue.asyncAfter(deadline: .now() + delay) { old.disconnect() }
        } else {
            old.disconnect()
        }
        for peer in affected {
            emit(.stateChanged(peer, .notConnected))
        }
    }

    // MARK: - Discovery (queue only)

    private func startDiscovery() {
        stopDiscovery()
        cancelAllFallbacks()
        let stale = discovered.keys.filter { !session.connectedPeers.contains($0) }
        discovered.removeAll()
        for peer in stale {
            emit(.lost(peer))
        }

        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: discoveryInfo, serviceType: IntercomProtocol.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: IntercomProtocol.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    private func stopDiscovery() {
        advertiser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.delegate = nil
        browser?.stopBrowsingForPeers()
        browser = nil
    }

    /// MultipeerConnectivity often fails to re-discover a peer that disconnected unless browsing
    /// is restarted, so discovery is bounced after drops, failed handshakes and start failures.
    private func scheduleDiscoveryRestart(after delay: TimeInterval) {
        guard isStarted else { return }
        pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.pendingRestart = nil
            self.startDiscovery()
        }
        pendingRestart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func inviteNow(_ peer: MCPeerID) {
        guard isStarted, let browser, discovered[peer] != nil else { return }
        guard attempts[peer] == nil, !session.connectedPeers.contains(peer) else { return }
        attempts[peer] = .inviting
        cancelFallback(for: peer)
        os_log("Inviting %{public}@", log: Self.log, type: .info, peer.displayName)
        browser.invitePeer(peer, to: session, withContext: Data(token.utf8), timeout: inviteTimeout)
        emit(.stateChanged(peer, .connecting))
    }

    /// The non-initiating side re-announces itself if the initiator has not invited it in time.
    private func scheduleFallback(for peer: MCPeerID) {
        cancelFallback(for: peer)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fallbackTimers[peer] = nil
            guard self.isStarted, self.discovered[peer] != nil, self.attempts[peer] == nil,
                  !self.suppressed.contains(peer), !self.session.connectedPeers.contains(peer) else { return }
            os_log("No invitation from %{public}@ yet; re-announcing", log: Self.log, type: .info, peer.displayName)
            self.scheduleDiscoveryRestart(after: 0)
        }
        fallbackTimers[peer] = item
        queue.asyncAfter(deadline: .now() + fallbackDelay, execute: item)
    }

    private func cancelFallback(for peer: MCPeerID) {
        fallbackTimers[peer]?.cancel()
        fallbackTimers[peer] = nil
    }

    private func cancelAllFallbacks() {
        fallbackTimers.values.forEach { $0.cancel() }
        fallbackTimers.removeAll()
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async { [self] in
            guard isStarted, browser === self.browser else { return }
            let peer = DiscoveredPeer(
                peerID: peerID,
                token: info?[IntercomProtocol.DiscoveryKey.token],
                protocolVersion: info?[IntercomProtocol.DiscoveryKey.version].flatMap(Int.init)
            )
            discovered[peerID] = peer
            emit(.discovered(peer))
            guard autoConnect, attempts[peerID] == nil, !suppressed.contains(peerID),
                  !session.connectedPeers.contains(peerID) else { return }
            if PeerElection.shouldInitiate(localToken: token, remoteToken: peer.token) {
                inviteNow(peerID)
            } else {
                scheduleFallback(for: peerID)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [self] in
            guard browser === self.browser else { return }
            discovered[peerID] = nil
            cancelFallback(for: peerID)
            emit(.lost(peerID))
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async { [self] in
            os_log("Browsing failed: %{public}@", log: Self.log, type: .error, String(describing: error))
            emit(.failure(error.localizedDescription))
            scheduleDiscoveryRestart(after: 3)
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
            guard isStarted, advertiser === self.advertiser, !suppressed.contains(peerID),
                  !session.connectedPeers.contains(peerID) else {
                invitationHandler(false, nil)
                return
            }
            let remoteToken = context.map { String(decoding: $0, as: UTF8.self) }
            switch attempts[peerID] {
            case .accepted?, .connected?:
                // A handshake with this peer is already under way on the current session.
                invitationHandler(false, nil)
                return
            case .inviting?:
                // Both sides invited at once (manual Connect on one of them). Let the elected
                // initiator's invitation win and decline the other one.
                if PeerElection.shouldInitiate(localToken: token, remoteToken: remoteToken) {
                    os_log("Declining invitation from %{public}@: our own invitation takes precedence", log: Self.log, type: .info, peerID.displayName)
                    invitationHandler(false, nil)
                    return
                }
            case nil:
                break
            }
            attempts[peerID] = .accepted
            cancelFallback(for: peerID)
            os_log("Accepting invitation from %{public}@", log: Self.log, type: .info, peerID.displayName)
            invitationHandler(true, session)
            emit(.stateChanged(peerID, .connecting))
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async { [self] in
            os_log("Advertising failed: %{public}@", log: Self.log, type: .error, String(describing: error))
            emit(.failure(error.localizedDescription))
            scheduleDiscoveryRestart(after: 3)
        }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [self] in
            guard session === self.session else { return }
            os_log("%{public}@ -> %d", log: Self.log, type: .info, peerID.displayName, state.rawValue)
            switch state {
            case .connecting:
                break
            case .connected:
                attempts[peerID] = .connected
                failedAttempts[peerID] = nil
                cancelFallback(for: peerID)
            case .notConnected:
                let previous = attempts.removeValue(forKey: peerID)
                if previous == .connected {
                    // A live link dropped. Give the framework a fresh session and fresh discovery so
                    // the peer shows up again and can reconnect.
                    if session.connectedPeers.isEmpty {
                        replaceSession(disconnectingAfter: 0)
                        scheduleDiscoveryRestart(after: 1)
                    }
                } else if previous != nil, !suppressed.contains(peerID) {
                    // A handshake failed, timed out or was declined. Re-discover and try again,
                    // backing off if it keeps failing (the other side may have declined on purpose).
                    let failures = (failedAttempts[peerID] ?? 0) + 1
                    failedAttempts[peerID] = failures
                    let delay = min(30, 3 * pow(2, Double(failures - 1)))
                    scheduleDiscoveryRestart(after: delay)
                }
            @unknown default:
                break
            }
            emit(.stateChanged(peerID, state))
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = WireMessage.decode(data) else { return }
        switch message {
        case .audio(let packet):
            onAudio?(packet, peerID)
        case .control(let control):
            queue.async { [self] in
                guard session === self.session else { return }
                emit(.control(control, from: peerID))
            }
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
}
