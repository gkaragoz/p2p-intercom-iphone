import Foundation

// Handshake and everything that arrives on a flow.
extension LinkStateMachine {
    mutating func received(_ datagram: NetDatagram, on id: FlowID, now: MonotonicTime) {
        guard let flow = flows[id], flow.closingDeadline == nil else { return }
        switch datagram.payload {
        case .hello(let hello):
            receivedHello(hello, header: datagram, on: flow, now: now)
        case .helloAck(let ack):
            receivedHelloAck(ack, on: flow, now: now)
        default:
            receivedOnLink(datagram, on: id, now: now)
        }
    }

    // MARK: - HELLO (listener side)

    private mutating func receivedHello(_ hello: NetHello, header: NetDatagram, on flow: FlowRecord, now: MonotonicTime) {
        let id = flow.id
        guard !flow.isOutbound else {
            log("\(id): HELLO on an outbound flow ignored")
            return
        }
        guard hello.peerID != configuration.localID else {
            log("\(id): HELLO from ourselves; cancelling")
            retireFlow(id, linger: false, now: now)
            return
        }
        if let existing = links[id] {
            if existing.peer == hello.peerID, existing.remoteEpoch == hello.epoch,
               existing.remoteNonce == hello.nonce, let ack = existing.ack {
                // The dialer did not get our HELLO_ACK yet; answer again, identically.
                emit(.send(makeDatagram(.helloAck(ack), linkID: ack.linkID), on: id))
            } else {
                log("\(id): unexpected second HELLO ignored")
            }
            return
        }
        guard flow.peer == nil else { return }
        let remote = hello.peerID
        guard authenticator.isValidAuthenticationTag(hello.authenticationTag, for: hello.helloAuthenticatedBytes) else {
            log("HELLO from \(remote) failed authentication: pairing codes differ")
            rejectHandshake(on: id, reason: .authenticationFailed, peer: remote, now: now)
            return
        }
        guard hello.protocolVersion == configuration.protocolVersion else {
            log("HELLO from \(remote) has protocol v\(hello.protocolVersion), we speak v\(configuration.protocolVersion)")
            rejectHandshake(on: id, reason: .incompatibleVersion, peer: remote, now: now)
            return
        }
        var peer = ensurePeer(remote, now: now)
        adopt(hello, into: &peer)
        if peer.suppression == .local {
            peers[remote] = peer
            log("HELLO from \(remote) refused: disconnected by the user")
            emit(.send(makeDatagram(.bye(.userDisconnect), linkID: 0), on: id))
            retireFlow(id, linger: true, now: now)
            return
        }
        if peer.suppression == .remote {
            peer.suppression = nil
        }
        peers[remote] = peer

        // A HELLO proves only that its tag was made with the pairing key at some point: a captured one
        // can be replayed. A new epoch therefore replaces the old instance's links only once this flow
        // carries a sealed datagram (see `receivedOnLink`); until then the current link stays untouched.
        let isNewEpoch = peer.remoteEpoch.map { $0 != hello.epoch } ?? false
        let primaryLink = peers[remote]?.primary.flatMap { links[$0] }
        let decision = LinkArbiter.decideInboundHello(
            local: configuration.localID,
            remote: remote,
            helloEpoch: hello.epoch,
            primary: primaryLink.flatMap { link in
                link.remoteEpoch.map {
                    LinkArbiter.ExistingLink(dialer: candidate(for: link).dialer, remoteEpoch: $0,
                                             health: health(of: link, now: now))
                }
            }
        )
        var supersedes = false
        switch decision {
        case .rejectDuplicate:
            log("HELLO from \(remote) on \(id): our healthy link wins the tie-break; bye(duplicate)")
            emit(.send(makeDatagram(.bye(.duplicate), linkID: 0), on: id))
            retireFlow(id, linger: true, now: now)
            return
        case .acceptReplacingRestartedPeer:
            break
        case .accept(let supersedesPrimary):
            supersedes = supersedesPrimary
        }

        // Skipped for an unconfirmed new epoch, so a replay cannot abandon our own dial either.
        for other in links(of: remote) where other.isHandshaking && !isNewEpoch {
            if other.isLocalDialer,
               LinkArbiter.shouldAbandonOwnDialOnInboundHello(local: configuration.localID, remote: remote) {
                log("abandoning our dial \(other.flow): \(remote)'s flow wins the tie-break")
                links[other.flow] = nil
                retireFlow(other.flow, linger: false, now: now)
            } else if !other.isLocalDialer, other.dialSequence < hello.dialSequence {
                log("newer HELLO from \(remote) replaces handshake on \(other.flow)")
                links[other.flow] = nil
                retireFlow(other.flow, linger: false, now: now)
            }
        }

        var linkID = randomNonZeroUInt32()
        while links.values.contains(where: { $0.linkID == linkID }) {
            linkID = randomNonZeroUInt32()
        }
        let localNonce = randomNonZeroUInt32()
        var ack = NetHelloAck(echoNonce: hello.nonce, linkID: linkID,
                              responder: localHello(nonce: localNonce, dialSequence: 0))
        ack.responder.authenticationTag = authenticator.authenticationTag(for: ack.authenticatedBytes)
        var link = LinkRecord(
            flow: id,
            peer: remote,
            isLocalDialer: false,
            dialSequence: hello.dialSequence,
            localNonce: localNonce,
            remoteNonce: hello.nonce,
            remoteEpoch: hello.epoch,
            linkID: linkID,
            phase: .handshaking(deadline: now + configuration.listenerHandshakeTimeout),
            ack: ack,
            liveness: LivenessMonitor(configuration: configuration.liveness, now: now),
            isMigration: false,
            nextHeartbeatAt: now
        )
        link.supersedesPrimary = supersedes
        link.liveness.isLocalInBackground = !isAppActive
        link.liveness.isRemoteInBackground = header.isSenderInBackground
        links[id] = link
        flows[id]?.peer = remote
        unboundFlows.removeAll { $0 == id }
        if !isNewEpoch {
            peers[remote]?.remoteEpoch = hello.epoch
            peers[remote]?.nextDialAt = nil
        }
        log("HELLO from \(remote) epoch \(hello.epoch) seq \(hello.dialSequence) on \(id): link \(linkID)"
            + (supersedes ? " (replaces unhealthy link)" : "")
            + (isNewEpoch ? " (new epoch: replaces the old instance once confirmed)" : ""))
        emit(.send(makeDatagram(.helloAck(ack), linkID: linkID), on: id))
        if let context = keyContext(for: link) {
            emit(.bindFlow(id, context))
        }
        resolve(remote, lostReason: .remoteBye(.replaced), now: now)
    }

    private mutating func rejectHandshake(on id: FlowID, reason: ByeReason, peer remote: PeerID, now: MonotonicTime) {
        emit(.send(makeDatagram(.bye(reason), linkID: 0), on: id))
        retireFlow(id, linger: true, now: now)
        markIncompatible(remote, reason: reason)
    }

    private mutating func markIncompatible(_ remote: PeerID, reason: ByeReason) {
        switch reason {
        case .authenticationFailed:
            emitEvent(.warning(.pairingMismatch(remote)))
            if peers[remote] != nil {
                peers[remote]?.compatibility = .pairingMismatch
                peers[remote]?.isManualOverride = false
                peers[remote]?.nextDialAt = nil
                if let advert = peers[remote]?.advert { emitEvent(.peerDiscovered(advert)) }
            }
        case .incompatibleVersion:
            emitEvent(.warning(.incompatibleVersion(remote)))
            if peers[remote] != nil {
                peers[remote]?.compatibility = .incompatibleVersion
                peers[remote]?.isManualOverride = false
                peers[remote]?.nextDialAt = nil
                if let advert = peers[remote]?.advert { emitEvent(.peerDiscovered(advert)) }
            }
        default:
            break
        }
    }

    private mutating func ensurePeer(_ id: PeerID, now: MonotonicTime) -> PeerRecord {
        if let peer = peers[id] { return peer }
        let peer = PeerRecord(id: id, displayName: DisplayName.fallback, compatibility: .compatible,
                              backoff: configuration.backoff, controlRetryInterval: configuration.controlRetryInterval)
        log("\(id) dialled us before discovery reported it")
        return peer
    }

    /// Takes the authoritative name and version from a verified HELLO / HELLO_ACK.
    private mutating func adopt(_ hello: NetHello, into peer: inout PeerRecord) {
        let before = peer.advert
        let isNew = peers[peer.id] == nil
        peer.displayName = DisplayName.sanitized(hello.displayName)
        peer.appVersion = hello.appVersion
        peer.protocolVersion = Int(hello.protocolVersion)
        peer.compatibility = .compatible
        if isNew || peer.advert != before {
            emitEvent(.peerDiscovered(peer.advert))
        }
    }

    /// The peer is a new app instance: every flow and all session state of the old one is stale.
    /// Handshakes that already carry the new epoch belong to the new instance and are kept. Call
    /// `resolve` right after.
    mutating func peerRestarted(_ remote: PeerID, newEpoch: UInt32, keeping keep: FlowID?, now: MonotonicTime) {
        guard var peer = peers[remote] else { return }
        log("\(remote) restarted (epoch \(peer.remoteEpoch.map(String.init) ?? "?") -> \(newEpoch))")
        for link in links(of: remote) where link.flow != keep && link.remoteEpoch != newEpoch {
            links[link.flow] = nil
            retireFlow(link.flow, linger: false, now: now)
        }
        if let primary = peer.primary, links[primary] == nil, let since = peer.linkUpSince {
            // The next link is a new instance's, not a continuation of this one: `resolve` reports a
            // fresh link-up (not a resumption) instead of silently swapping the primary.
            peer.backoff.linkWentDown(upFor: now - since)
            peer.linkUpSince = nil
        }
        peer.remoteEpoch = newEpoch
        peer.controlOut.removeAll()
        peer.controlIn.reset()
        peer.forgetRoundTripState()
        peers[remote] = peer
    }

    // MARK: - HELLO_ACK (dialer side)

    private mutating func receivedHelloAck(_ ack: NetHelloAck, on flow: FlowRecord, now: MonotonicTime) {
        let id = flow.id
        guard var link = links[id], link.isLocalDialer, link.isHandshaking else { return }
        guard ack.echoNonce == link.localNonce else {
            log("\(id): HELLO_ACK with a foreign nonce ignored")
            return
        }
        let responder = ack.responder
        guard responder.peerID == link.peer else {
            attemptFailed(link, reason: "answered by \(responder.peerID) instead (stale endpoint)", now: now)
            return
        }
        guard authenticator.isValidAuthenticationTag(responder.authenticationTag, for: ack.authenticatedBytes) else {
            log("HELLO_ACK from \(link.peer) failed authentication: pairing codes differ")
            emit(.send(makeDatagram(.bye(.authenticationFailed), linkID: 0), on: id))
            markIncompatible(link.peer, reason: .authenticationFailed)
            attemptFailed(link, reason: "authentication failed", now: now, reschedule: false, countsAsFailedDial: false)
            return
        }
        guard responder.protocolVersion == configuration.protocolVersion, ack.linkID != 0 else {
            emit(.send(makeDatagram(.bye(.incompatibleVersion), linkID: 0), on: id))
            markIncompatible(link.peer, reason: .incompatibleVersion)
            attemptFailed(link, reason: "incompatible protocol v\(responder.protocolVersion)", now: now,
                          reschedule: false, countsAsFailedDial: false)
            return
        }
        guard var peer = peers[link.peer] else { return }
        adopt(responder, into: &peer)
        peers[link.peer] = peer
        if let known = peer.remoteEpoch, known != responder.epoch {
            peerRestarted(link.peer, newEpoch: responder.epoch, keeping: id, now: now)
        }
        peers[link.peer]?.remoteEpoch = responder.epoch
        link.remoteNonce = responder.nonce
        link.remoteEpoch = responder.epoch
        link.linkID = ack.linkID
        link.nextHelloAt = nil
        link.phase = .established(since: now)
        link.liveness = LivenessMonitor(configuration: configuration.liveness, now: now)
        link.liveness.isLocalInBackground = !isAppActive
        links[id] = link
        log("link \(ack.linkID) to \(link.peer) up on \(id) (we dialled)")
        if let context = keyContext(for: link) {
            emit(.bindFlow(id, context))
        }
        // The listener counts the link as up on our first sealed datagram, so send one now.
        sendHeartbeat(id, now: now)
        resolve(link.peer, lostReason: .remoteBye(.replaced), now: now)
    }

    // MARK: - Datagrams on a link

    private mutating func receivedOnLink(_ datagram: NetDatagram, on id: FlowID, now: MonotonicTime) {
        guard var link = links[id] else { return }
        if link.isLocalDialer, link.isHandshaking {
            // Before HELLO_ACK only a plaintext refusal can arrive.
            if case .bye(let reason) = datagram.payload, datagram.linkID == 0 {
                handshakeRefused(link, reason: reason, now: now)
            }
            return
        }
        guard datagram.isSealed, datagram.linkID == link.linkID, datagram.senderEpoch == link.remoteEpoch else {
            return
        }
        link.liveness.recordReceive(at: now)
        link.liveness.isRemoteInBackground = datagram.isSenderInBackground
        let becameEstablished = link.isHandshaking
        if becameEstablished {
            link.phase = .established(since: now)
            link.nextHeartbeatAt = now
            log("link \(link.linkID) to \(link.peer) up on \(id) (they dialled)")
        }
        let peerID = link.peer
        links[id] = link
        if becameEstablished {
            if let epoch = link.remoteEpoch, let known = peers[peerID]?.remoteEpoch, known != epoch {
                // The sealed datagram proves the new-epoch HELLO was fresh: now the old instance goes.
                peerRestarted(peerID, newEpoch: epoch, keeping: id, now: now)
                peers[peerID]?.nextDialAt = nil
            }
            resolve(peerID, lostReason: .remoteBye(.replaced), now: now)
            // `resolve` may have closed this very flow as a losing duplicate.
            guard links[id] != nil else { return }
        }
        updateRemoteStatus(datagram.status, from: peerID)

        switch datagram.payload {
        case .heartbeat(let beat):
            receivedHeartbeat(beat, from: peerID, now: now)
        case .control(let sequence, let message):
            send(.controlAck(sequence: sequence), on: link)
            if peers[peerID]?.controlIn.shouldDeliver(sequence) == true {
                emitEvent(.control(message, from: peerID))
            }
        case .controlAck(let sequence):
            peers[peerID]?.controlOut.acknowledge(sequence)
        case .bye(let reason):
            log("bye(\(reason)) from \(peerID) on \(id)")
            links[id] = nil
            retireFlow(id, linger: false, now: now)
            switch reason {
            case .userDisconnect:
                peers[peerID]?.suppression = .remote
                peers[peerID]?.isManualOverride = false
            case .authenticationFailed, .incompatibleVersion:
                markIncompatible(peerID, reason: reason)
            default:
                break
            }
            resolve(peerID, lostReason: .remoteBye(reason), now: now)
        case .audio, .hello, .helloAck:
            break
        }
        updateReportedState(peerID, now: now)
    }

    private mutating func handshakeRefused(_ link: LinkRecord, reason: ByeReason, now: MonotonicTime) {
        log("dial \(link.peer) on \(link.flow) refused: bye(\(reason))")
        switch reason {
        case .duplicate, .replaced:
            let hasOther = links(of: link.peer).contains { $0.flow != link.flow }
            attemptFailed(link, reason: "refused as duplicate", now: now, reschedule: !hasOther, countsAsFailedDial: false)
        case .authenticationFailed, .incompatibleVersion:
            markIncompatible(link.peer, reason: reason)
            attemptFailed(link, reason: "refused: \(reason)", now: now, reschedule: false, countsAsFailedDial: false)
            if peers[link.peer]?.primary == nil, !hasHandshakingLink(link.peer) {
                setReportedState(link.peer, .disconnected(.remoteBye(reason)))
            }
        case .userDisconnect:
            peers[link.peer]?.suppression = .remote
            peers[link.peer]?.isManualOverride = false
            attemptFailed(link, reason: "peer disconnected on purpose", now: now, reschedule: false, countsAsFailedDial: false)
            if peers[link.peer]?.primary == nil, !hasHandshakingLink(link.peer) {
                setReportedState(link.peer, .disconnected(.remoteBye(reason)))
            }
        case .stopped, .other:
            attemptFailed(link, reason: "refused: \(reason)", now: now)
        }
    }

    private mutating func receivedHeartbeat(_ beat: NetHeartbeat, from peerID: PeerID, now: MonotonicTime) {
        guard var peer = peers[peerID] else { return }
        peer.lastRemoteHeartbeat = (beat.sequence, now)
        // A saturated echo delay (a peer that held the echo for over 65.5 s) cannot give a true sample.
        if beat.echoSequence != 0, beat.echoDelayMs != UInt16.max {
            let echoedAt = now.milliseconds >= UInt64(beat.echoDelayMs) ? now.milliseconds - UInt64(beat.echoDelayMs) : 0
            if peer.roundTrip.receivePong(ControlMessage.Ping(id: beat.echoSequence, sentAtMs: 0), nowMs: echoedAt) != nil {
                peer.hasUnreportedRoundTrip = true
            }
        }
        peers[peerID] = peer
    }

    private mutating func updateRemoteStatus(_ status: RemoteStatus, from peerID: PeerID) {
        guard peers[peerID]?.reportedStatus != status else { return }
        peers[peerID]?.reportedStatus = status
        emitEvent(.remoteStatus(status, from: peerID))
    }

    mutating func undecodable(_ error: NetDatagramError, on id: FlowID, now: MonotonicTime) {
        guard var flow = flows[id], flow.closingDeadline == nil else { return }
        flow.undecodableCount += 1
        let count = flow.undecodableCount
        flows[id] = flow
        if case .unsupportedVersion(let version) = error, count == 1, let peer = flow.peer {
            log("\(id): datagram with wire version \(version) from \(peer)")
            emitEvent(.warning(.incompatibleVersion(peer)))
        } else if count == 1 || count % 100 == 0 {
            log("\(id): undecodable datagram #\(count): \(error)")
        }
    }

    mutating func sendCompleted(on id: FlowID, success: Bool, now: MonotonicTime) {
        guard links[id]?.isEstablished == true else { return }
        if success {
            links[id]?.liveness.recordSendSuccess(at: now)
        } else {
            links[id]?.liveness.recordSendError(at: now)
        }
    }

    // MARK: - Local control and status

    mutating func sendControl(_ message: ControlMessage, now: MonotonicTime) {
        for id in knownPeers {
            guard let peer = peers[id], peer.suppression == nil,
                  peer.primary != nil || hasHandshakingLink(id) else { continue }
            peers[id]?.controlOut.enqueue(message)
            flushControl(id, now: now)
        }
    }

    mutating func flushControl(_ id: PeerID, now: MonotonicTime) {
        guard let flow = peers[id]?.primary, let link = links[flow], link.isEstablished,
              let due = peers[id]?.controlOut.due(at: now) else { return }
        for item in due {
            send(.control(sequence: item.sequence, message: item.message), on: link)
        }
    }

    mutating func updateLocalStatus(_ status: RemoteStatus, now: MonotonicTime) {
        guard status != localStatus else { return }
        localStatus = status
        // Status rides in every header; push it out now instead of waiting for the next heartbeat.
        for id in knownPeers {
            if let flow = peers[id]?.primary, links[flow]?.isEstablished == true {
                sendHeartbeat(flow, now: now)
            }
        }
    }
}
