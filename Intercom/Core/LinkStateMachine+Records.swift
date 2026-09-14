import Foundation

extension LinkStateMachine {
    /// Why the user (or the peer's user) does not want automatic reconnects.
    enum Suppression: Equatable {
        /// Disconnect was pressed on this phone: inbound HELLOs are refused too.
        case local
        /// The peer said `bye(userDisconnect)`: don't dial, but accept the peer dialling back.
        case remote
    }

    /// Everything known about one remote install.
    struct PeerRecord {
        let id: PeerID
        var displayName: String
        var appVersion: String?
        var protocolVersion: Int?
        var compatibility: PeerCompatibility
        /// The last TXT record seen, so an unchanged re-report does not undo a handshake verdict.
        var lastRecord: DiscoveryRecord?
        /// Currently listed by the browser.
        var isAdvertised = false
        /// Listed by the browser at some point this run, so the glue has an endpoint to dial.
        var isDialable = false
        var hasBeenLinked = false
        /// `.connect` was requested: dial even if discovery said the peer is incompatible.
        var isManualOverride = false
        var suppression: Suppression?
        /// Epoch of the peer instance we are (or were last) talking to.
        var remoteEpoch: UInt32?
        /// Epoch of the instance of the previous up link; decides `isResumption`.
        var lastLinkedEpoch: UInt32?
        /// Flow of the link that carries audio and control.
        var primary: FlowID?
        var linkUpSince: MonotonicTime?
        var backoff: ReconnectBackoff
        var nextDialAt: MonotonicTime?
        /// Dials since the last up link; reported as `LinkState.connecting(attempt:)`.
        var dialsSinceLinkUp = 0
        var consecutiveFailedDials = 0
        /// Gone from the browser and undialable while another link is healthy (a deleted install, a
        /// quit simulator): redialled rarely, not browsed for, and never a reason to rebuild discovery.
        /// Rediscovery, `.connect`, a path change, the foreground or a link-up undo it.
        var isParked = false
        var consecutiveHandshakeTimeouts = 0
        var infrastructureTimeouts: [String: Int] = [:]
        var prohibitedInterfaceName: String?
        var prohibitedDialTimeouts = 0
        var lastMigrationAt: MonotonicTime?
        var reportedState: LinkState?
        var reportedStatus: RemoteStatus?
        var controlOut: ControlRetransmitter<ControlMessage>
        var controlIn = ControlDeduplicator()
        /// Heartbeat sequence numbers double as ping IDs, so RTT needs no separate probe.
        var roundTrip = RoundTripEstimator()
        var hasUnreportedRoundTrip = false
        var lastRoundTripReportAt: MonotonicTime?
        var lastRemoteHeartbeat: (sequence: UInt32, receivedAt: MonotonicTime)?

        init(id: PeerID, displayName: String, compatibility: PeerCompatibility,
             backoff: ReconnectBackoff.Schedule, controlRetryInterval: TimeInterval) {
            self.id = id
            self.displayName = displayName
            self.compatibility = compatibility
            self.backoff = ReconnectBackoff(schedule: backoff)
            controlOut = ControlRetransmitter(retryInterval: controlRetryInterval)
        }

        var advert: PeerAdvert {
            PeerAdvert(id: id, displayName: displayName, protocolVersion: protocolVersion, compatibility: compatibility)
        }

        /// Heartbeat echoes and outstanding pings belong to the link they were measured on. A later
        /// link must neither echo nor match them: after a long outage the echo delay saturates at
        /// 65.535 s and the sample would come out tens of seconds too long.
        mutating func forgetRoundTripState() {
            roundTrip.reset()
            hasUnreportedRoundTrip = false
            lastRemoteHeartbeat = nil
        }

        /// Drops the black-hole fallback state: dial on every interface again.
        mutating func clearInterfaceAvoidance() {
            infrastructureTimeouts.removeAll()
            prohibitedInterfaceName = nil
            prohibitedDialTimeouts = 0
        }
    }

    /// One UDP flow as the glue sees it.
    struct FlowRecord {
        let id: FlowID
        let isOutbound: Bool
        /// Target of an outbound flow; for inbound flows the peer that sent a valid HELLO.
        var peer: PeerID?
        let createdAt: MonotonicTime
        var isReady: Bool
        var isLocalNetworkDenied = false
        var path: LinkPath = .unknown
        var interfaceName: String?
        /// Interface the dial excluded, if any (black-hole fallback bookkeeping).
        var prohibitedInterfaceName: String?
        /// Set while a losing or closed flow lingers before `.cancelFlow`.
        var closingDeadline: MonotonicTime?
        var undecodableCount = 0
    }

    enum LinkPhase: Equatable {
        case handshaking(deadline: MonotonicTime)
        case established(since: MonotonicTime)
    }

    /// A flow bound to a peer by a HELLO (sent or received).
    struct LinkRecord {
        let flow: FlowID
        let peer: PeerID
        let isLocalDialer: Bool
        let dialSequence: UInt32
        let localNonce: UInt32
        var remoteNonce: UInt32?
        var remoteEpoch: UInt32?
        /// 0 until HELLO_ACK assigns it.
        var linkID: UInt32
        var phase: LinkPhase
        var nextHelloAt: MonotonicTime?
        /// Listener side: the HELLO_ACK to repeat when the dialer retransmits HELLO.
        var ack: NetHelloAck?
        var liveness: LivenessMonitor
        var isViable = true
        /// Close the current primary as soon as this link is up, even if the tie-break favours it.
        var supersedesPrimary = false
        /// Opened by `flowBetterPathAvailable` while another link is up; failure is not a reconnect.
        let isMigration: Bool
        var nextHeartbeatAt: MonotonicTime

        var isEstablished: Bool {
            if case .established = phase { return true }
            return false
        }

        var isHandshaking: Bool { !isEstablished }
    }

    // MARK: - Shared helpers

    func candidate(for link: LinkRecord) -> LinkArbiter.Candidate {
        LinkArbiter.Candidate(dialer: link.isLocalDialer ? configuration.localID : link.peer,
                              dialSequence: link.dialSequence)
    }

    func links(of peer: PeerID) -> [LinkRecord] {
        links.values.filter { $0.peer == peer }.sorted { $0.flow < $1.flow }
    }

    func hasHandshakingLink(_ peer: PeerID) -> Bool {
        links.values.contains { $0.peer == peer && $0.isHandshaking }
    }

    func hasOutboundHandshake(_ peer: PeerID) -> Bool {
        links.values.contains { $0.peer == peer && $0.isHandshaking && $0.isLocalDialer }
    }

    /// The peer's primary link is established and alive.
    func hasHealthyPrimary(_ peer: PeerRecord, now: MonotonicTime) -> Bool {
        guard let flow = peer.primary, let link = links[flow], link.isEstablished else { return false }
        return health(of: link, now: now) == .alive
    }

    func hasHealthyLink(toPeerOtherThan excluded: PeerID, now: MonotonicTime) -> Bool {
        peers.values.contains { $0.id != excluded && hasHealthyPrimary($0, now: now) }
    }

    func health(of link: LinkRecord, now: MonotonicTime) -> LivenessMonitor.Health {
        var health = link.liveness.health(at: now)
        if !link.isViable, health < .suspect {
            health = .suspect
        }
        return health
    }

    func canDial(_ peer: PeerRecord) -> Bool {
        guard isRunning, peer.isDialable, peer.suppression == nil else { return false }
        if peer.isManualOverride { return true }
        return configuration.autoConnect && peer.compatibility == .compatible
    }

    func makeDatagram(_ payload: NetPayload, linkID: UInt32) -> NetDatagram {
        NetDatagram(linkID: linkID, senderEpoch: configuration.localEpoch, status: localStatus,
                    isSenderInBackground: !isAppActive, payload: payload)
    }

    func localHello(nonce: UInt32, dialSequence: UInt32) -> NetHello {
        NetHello(peerID: configuration.localID, epoch: configuration.localEpoch, nonce: nonce,
                 protocolVersion: configuration.protocolVersion, capabilities: configuration.capabilities,
                 dialSequence: dialSequence, displayName: configuration.displayName,
                 appVersion: configuration.appVersion)
    }

    mutating func send(_ payload: NetPayload, on link: LinkRecord) {
        emit(.send(makeDatagram(payload, linkID: link.linkID), on: link.flow))
    }

    func keyContext(for link: LinkRecord) -> LinkKeyContext? {
        guard let remoteNonce = link.remoteNonce, let remoteEpoch = link.remoteEpoch else { return nil }
        return LinkKeyContext(
            localID: configuration.localID,
            remoteID: link.peer,
            isLocalDialer: link.isLocalDialer,
            dialerNonce: link.isLocalDialer ? link.localNonce : remoteNonce,
            listenerNonce: link.isLocalDialer ? remoteNonce : link.localNonce,
            dialerEpoch: link.isLocalDialer ? configuration.localEpoch : remoteEpoch,
            listenerEpoch: link.isLocalDialer ? remoteEpoch : configuration.localEpoch,
            linkID: link.linkID
        )
    }

    /// Cancels a flow now, or after `closingLinger` so late datagrams on it are ignored quietly.
    mutating func retireFlow(_ id: FlowID, linger: Bool, now: MonotonicTime) {
        unboundFlows.removeAll { $0 == id }
        guard flows[id] != nil else { return }
        if linger {
            if flows[id]?.closingDeadline == nil {
                let deadline = now + configuration.closingLinger
                flows[id]?.closingDeadline = deadline
            }
        } else {
            flows[id] = nil
            emit(.cancelFlow(id))
        }
    }
}
