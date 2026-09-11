import Foundation
import MultipeerConnectivity
import os.log

/// Peer discovery and data transport on top of MultipeerConnectivity.
///
/// Both iPhones advertise *and* browse for the same service type, so either one finds the other
/// regardless of who launched first. `PeerElection` decides which side sends the invitation.
/// Audio frames go out with `.unreliable` (drop rather than delay); control messages with `.reliable`.
///
/// All state is confined to `queue`. Delegate callbacks from MultipeerConnectivity arrive on an
/// internal framework thread and are forwarded to `queue`, except received audio, which is
/// handed to `onAudio` immediately to keep the hot path short.
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

    let peerID: MCPeerID
    let token: String

    /// Delivered on the transport's serial queue.
    var onEvent: (@Sendable (Event) -> Void)?
    /// Delivered on MultipeerConnectivity's receive thread; must be cheap and thread-safe.
    var onAudio: (@Sendable (AudioPacket, MCPeerID) -> Void)?
    /// When `false`, discovered peers are only reported and `invite(_:)` must be called explicitly.
    var autoConnect = true

    /// How long the non-initiating side waits for an invitation before inviting anyway.
    var fallbackInviteDelay: TimeInterval = 12
    var inviteTimeout: TimeInterval = 20

    private let queue = DispatchQueue(label: "intercom.transport", qos: .userInitiated)
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var isStarted = false
    private var discovered: [MCPeerID: DiscoveredPeer] = [:]
    private var pendingFallbackInvites: [MCPeerID: DispatchWorkItem] = [:]
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
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    deinit {
        session.delegate = nil
        advertiser?.delegate = nil
        browser?.delegate = nil
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard !isStarted else { return }
            isStarted = true
            startDiscovery()
        }
    }

    func stop() {
        queue.async { [self] in
            guard isStarted else { return }
            isStarted = false
            pendingRestart?.cancel()
            pendingRestart = nil
            cancelAllFallbackInvites()
            stopDiscovery()
            discovered.removeAll()
            sendControlNow(.bye)
            replaceSession()
        }
    }

    /// Manually invites a discovered peer (also used by the fallback timer).
    func invite(_ peer: MCPeerID) {
        queue.async { [self] in
            inviteNow(peer)
        }
    }

    /// Drops every connection; discovery keeps running so peers can reconnect.
    func disconnectAll() {
        queue.async { [self] in
            sendControlNow(.bye)
            replaceSession()
            scheduleDiscoveryRestart(after: 0.5)
        }
    }

    /// Thread-safe snapshot of the connected peers.
    var connectedPeers: [MCPeerID] {
        session.connectedPeers
    }

    // MARK: - Sending

    /// Sends one audio frame to every connected peer without waiting for acknowledgements.
    func sendAudio(_ packet: AudioPacket) {
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
        let peers = session.connectedPeers
        guard !peers.isEmpty, let data = try? WireMessage.control(message).encoded() else { return }
        do {
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            os_log("Control send failed: %{public}@", log: Self.log, type: .error, String(describing: error))
        }
    }

    // MARK: - Discovery (queue only)

    private func startDiscovery() {
        stopDiscovery()
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
    /// is restarted, so discovery is bounced after every disconnect and after start failures.
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

    private func replaceSession() {
        let old = session
        old.delegate = nil
        old.disconnect()
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    private func inviteNow(_ peer: MCPeerID) {
        guard isStarted, let browser else { return }
        guard !session.connectedPeers.contains(peer) else { return }
        cancelFallbackInvite(for: peer)
        os_log("Inviting %{public}@", log: Self.log, type: .info, peer.displayName)
        browser.invitePeer(peer, to: session, withContext: nil, timeout: inviteTimeout)
        emit(.stateChanged(peer, .connecting))
    }

    private func scheduleFallbackInvite(for peer: MCPeerID) {
        cancelFallbackInvite(for: peer)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFallbackInvites[peer] = nil
            guard self.discovered[peer] != nil, !self.session.connectedPeers.contains(peer) else { return }
            os_log("No invitation arrived from %{public}@; inviting as fallback", log: Self.log, type: .info, peer.displayName)
            self.inviteNow(peer)
        }
        pendingFallbackInvites[peer] = item
        queue.asyncAfter(deadline: .now() + fallbackInviteDelay, execute: item)
    }

    private func cancelFallbackInvite(for peer: MCPeerID) {
        pendingFallbackInvites[peer]?.cancel()
        pendingFallbackInvites[peer] = nil
    }

    private func cancelAllFallbackInvites() {
        pendingFallbackInvites.values.forEach { $0.cancel() }
        pendingFallbackInvites.removeAll()
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
            guard autoConnect, !session.connectedPeers.contains(peerID) else { return }
            if PeerElection.shouldInitiate(localToken: token, remoteToken: peer.token) {
                inviteNow(peerID)
            } else {
                scheduleFallbackInvite(for: peerID)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [self] in
            guard browser === self.browser else { return }
            discovered[peerID] = nil
            cancelFallbackInvite(for: peerID)
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
            guard isStarted, advertiser === self.advertiser else {
                invitationHandler(false, nil)
                return
            }
            if session.connectedPeers.contains(peerID) {
                invitationHandler(false, nil)
                return
            }
            cancelFallbackInvite(for: peerID)
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
            case .connected:
                cancelFallbackInvite(for: peerID)
            case .notConnected:
                if session.connectedPeers.isEmpty {
                    // Give the framework a fresh session and a fresh browser so the peer shows up again.
                    replaceSession()
                    scheduleDiscoveryRestart(after: 1)
                }
            case .connecting:
                break
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
