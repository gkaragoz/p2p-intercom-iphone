import Foundation

// Discovery, user commands, flow lifecycle and outbound dialling.
extension LinkStateMachine {
    // MARK: - Discovery

    mutating func peerDiscovered(_ record: DiscoveryRecord, now: MonotonicTime) {
        guard record.peerID != configuration.localID else { return }
        let compatibility = record.compatibility(localProtocolVersion: Int(configuration.protocolVersion),
                                                 localKeyTag: configuration.keyTag)
        let id = record.peerID
        guard var peer = peers[id] else {
            var peer = PeerRecord(id: id, displayName: record.displayName, compatibility: compatibility,
                                  backoff: configuration.backoff, controlRetryInterval: configuration.controlRetryInterval)
            peer.protocolVersion = record.protocolVersion
            peer.lastRecord = record
            peer.isAdvertised = true
            peer.isDialable = true
            if canDial(peer) {
                peer.nextDialAt = now + LinkArbiter.dialDelay(local: configuration.localID, remote: id,
                                                              holdoff: configuration.dialHoldoff)
            }
            peers[id] = peer
            log("discovered \(id) \"\(record.displayName)\" v\(record.protocolVersion) \(compatibility)")
            emitEvent(.peerDiscovered(peer.advert))
            setReportedState(id, .discovered)
            return
        }
        let before = peer.advert
        let wasAdvertised = peer.isAdvertised
        peer.isAdvertised = true
        peer.isDialable = true
        if peer.isParked {
            // Back in the browser: dial on the normal schedule again, starting now.
            log("\(id) advertised again: no longer parked")
            peer.isParked = false
            peer.nextDialAt = nil
        }
        if peer.lastRecord != record {
            // Only a changed record may overrule what a handshake found out about the peer.
            peer.lastRecord = record
            peer.compatibility = compatibility
            peer.protocolVersion = record.protocolVersion
            if peer.appVersion == nil {
                peer.displayName = record.displayName
            }
        }
        if peer.primary == nil, !hasHandshakingLink(id), peer.nextDialAt == nil, canDial(peer) {
            peer.nextDialAt = now + LinkArbiter.dialDelay(local: configuration.localID, remote: id,
                                                          holdoff: configuration.dialHoldoff)
        }
        peers[id] = peer
        if !wasAdvertised || peer.advert != before {
            log("rediscovered \(id) \(peer.compatibility)")
            emitEvent(.peerDiscovered(peer.advert))
        }
    }

    mutating func peerLost(_ id: PeerID, now: MonotonicTime) {
        guard var peer = peers[id], peer.isAdvertised else { return }
        peer.isAdvertised = false
        log("browser lost \(id)\(peer.hasBeenLinked ? " (still redialled)" : "")")
        emitEvent(.peerLost(id))
        if !peer.hasBeenLinked, links(of: id).isEmpty {
            peers[id] = nil
        } else {
            peers[id] = peer
        }
    }

    // MARK: - User commands

    mutating func connect(_ id: PeerID, now: MonotonicTime) {
        guard var peer = peers[id] else {
            log("connect \(id) ignored: unknown peer")
            return
        }
        peer.suppression = nil
        peer.isManualOverride = true
        peer.isParked = false
        peer.backoff.reset()
        peer.consecutiveFailedDials = 0
        peer.clearInterfaceAvoidance()
        peer.nextDialAt = now
        peers[id] = peer
        log("connect \(id) requested")
        if !peer.isDialable {
            log("connect \(id): no advertised endpoint yet, waiting for discovery or the peer's dial")
        }
    }

    mutating func disconnectAll(now: MonotonicTime) {
        log("disconnect all requested")
        for id in knownPeers {
            guard var peer = peers[id] else { continue }
            for link in links(of: id) {
                if link.isEstablished || !link.isLocalDialer {
                    send(.bye(.userDisconnect), on: link)
                }
                links[link.flow] = nil
                retireFlow(link.flow, linger: false, now: now)
            }
            if peer.primary != nil {
                peer.primary = nil
                emit(.setAudioRoute(id, nil))
            }
            peer.suppression = .local
            peer.isManualOverride = false
            peer.nextDialAt = nil
            peer.linkUpSince = nil
            peer.forgetRoundTripState()
            peer.controlOut.removeAll()
            let wasUp = peer.reportedState.map(Self.isUp) ?? false
            let wasConnecting: Bool
            if case .connecting? = peer.reportedState { wasConnecting = true } else { wasConnecting = false }
            if wasUp || wasConnecting {
                peer.reportedState = .disconnected(.userRequested)
                emitEvent(.linkStateChanged(id, .disconnected(.userRequested)))
            }
            peers[id] = peer
        }
    }

    // MARK: - Flow lifecycle

    mutating func inboundFlow(_ id: FlowID, now: MonotonicTime) {
        guard flows[id] == nil else { return }
        flows[id] = FlowRecord(id: id, isOutbound: false, peer: nil, createdAt: now, isReady: true)
        unboundFlows.append(id)
        if unboundFlows.count > configuration.maxUnboundFlows, let oldest = unboundFlows.first {
            log("too many unbound inbound flows; cancelling \(oldest)")
            retireFlow(oldest, linger: false, now: now)
        }
    }

    mutating func flowReady(_ id: FlowID, now: MonotonicTime) {
        guard flows[id] != nil else { return }
        let wasReady = flows[id]?.isReady ?? false
        flows[id]?.isReady = true
        flows[id]?.isLocalNetworkDenied = false
        if hasReportedLocalNetworkDenied {
            // The permission check can fail while the alert is still up; a ready flow proves access.
            hasReportedLocalNetworkDenied = false
            log("\(id) ready: Local Network access works now")
            emitEvent(.warningCleared(.localNetworkDenied))
        }
        guard var link = links[id] else { return }
        if link.isEstablished {
            if !link.isViable {
                link.isViable = true
                links[id] = link
                updateReportedState(link.peer, now: now)
            }
            return
        }
        guard link.isLocalDialer, !wasReady, let peer = peers[link.peer] else { return }
        let timeouts = configuration.handshakeTimeouts
        let timeout = timeouts[min(peer.consecutiveHandshakeTimeouts, timeouts.count - 1)]
        link.phase = .handshaking(deadline: now + timeout)
        link.nextHelloAt = now + configuration.helloRetryInterval
        links[id] = link
        log("\(id) ready; HELLO to \(link.peer) (timeout \(timeout)s)")
        sendHello(on: link)
    }

    mutating func flowWaiting(_ id: FlowID, localNetworkDenied: Bool, now: MonotonicTime) {
        guard flows[id] != nil else { return }
        flows[id]?.isLocalNetworkDenied = localNetworkDenied
        if localNetworkDenied, !hasReportedLocalNetworkDenied {
            hasReportedLocalNetworkDenied = true
            log("\(id) waiting: Local Network permission denied")
            emitEvent(.warning(.localNetworkDenied))
        }
        if let link = links[id], link.isEstablished {
            links[id]?.isViable = false
            log("\(id) waiting on an up link: suspect")
            updateReportedState(link.peer, now: now)
        }
    }

    mutating func flowFailed(_ id: FlowID, reason: String, now: MonotonicTime) {
        guard flows[id] != nil else { return }
        guard let link = links[id] else {
            log("\(id) failed before binding: \(reason)")
            retireFlow(id, linger: false, now: now)
            return
        }
        if link.isEstablished {
            log("\(id) to \(link.peer) failed: \(reason)")
            links[id] = nil
            retireFlow(id, linger: false, now: now)
            resolve(link.peer, lostReason: .transportError(reason), now: now)
        } else if link.isLocalDialer {
            attemptFailed(link, reason: "flow failed: \(reason)", now: now)
        } else {
            links[id] = nil
            retireFlow(id, linger: false, now: now)
            resolve(link.peer, lostReason: .transportError(reason), now: now)
        }
    }

    mutating func flowPathChanged(_ id: FlowID, path: LinkPath, interfaceName: String?, now: MonotonicTime) {
        guard let flow = flows[id], flow.path != path || flow.interfaceName != interfaceName else { return }
        flows[id]?.path = path
        flows[id]?.interfaceName = interfaceName
        log("\(id) path \(path) via \(interfaceName ?? "?")")
        if let peer = links[id]?.peer, peers[peer]?.primary == id {
            updateReportedState(peer, now: now)
        }
    }

    mutating func betterPathAvailable(_ id: FlowID, now: MonotonicTime) {
        guard let link = links[id], link.isEstablished, let peer = peers[link.peer], peer.primary == id else { return }
        guard link.isLocalDialer else {
            log("\(id) better path available, but the peer dialled this link; leaving migration to it")
            return
        }
        guard !hasOutboundHandshake(link.peer) else { return }
        if let last = peer.lastMigrationAt, now - last < configuration.migrationInterval { return }
        peers[link.peer]?.lastMigrationAt = now
        log("\(id) better path available: dialling a replacement flow (make-before-break)")
        dial(link.peer, isMigration: true, now: now)
    }

    // MARK: - Dialling

    /// Opens flows for every peer whose dial time has come.
    mutating func serviceDials(now: MonotonicTime) {
        for id in knownPeers {
            guard let peer = peers[id], let at = peer.nextDialAt, at <= now else { continue }
            guard canDial(peer), peer.primary == nil else {
                peers[id]?.nextDialAt = nil
                continue
            }
            guard !hasHandshakingLink(id) else { continue }
            dial(id, isMigration: false, now: now)
        }
    }

    mutating func dial(_ id: PeerID, isMigration: Bool, now: MonotonicTime) {
        guard var peer = peers[id] else { return }
        let flowID = makeFlowID()
        dialSequence &+= 1
        // A migration runs next to a working link, so it may try the avoided interface again: a failure
        // costs nothing, and a success moves the link back off the fallback path.
        let prohibited = isMigration ? nil : peer.prohibitedInterfaceName
        var flow = FlowRecord(id: flowID, isOutbound: true, peer: id, createdAt: now, isReady: false)
        flow.prohibitedInterfaceName = prohibited
        flows[flowID] = flow
        links[flowID] = LinkRecord(
            flow: flowID,
            peer: id,
            isLocalDialer: true,
            dialSequence: dialSequence,
            localNonce: randomNonZeroUInt32(),
            linkID: 0,
            phase: .handshaking(deadline: now + configuration.flowReadyTimeout),
            liveness: LivenessMonitor(configuration: configuration.liveness, now: now),
            isMigration: isMigration,
            nextHeartbeatAt: now
        )
        peer.nextDialAt = nil
        if !isMigration {
            peer.dialsSinceLinkUp += 1
        }
        peers[id] = peer
        log("dial \(id) on \(flowID) seq \(dialSequence)" + (prohibited.map { " avoiding \($0)" } ?? "")
            + (isMigration ? " (migration)" : " attempt \(peer.dialsSinceLinkUp)"))
        emit(.openFlow(flowID, to: id, prohibitedInterfaceName: prohibited))
        if !isMigration, peer.primary == nil {
            setReportedState(id, .connecting(attempt: peer.dialsSinceLinkUp))
        }
    }

    mutating func sendHello(on link: LinkRecord) {
        var hello = localHello(nonce: link.localNonce, dialSequence: link.dialSequence)
        hello.authenticationTag = authenticator.authenticationTag(for: hello.helloAuthenticatedBytes)
        emit(.send(makeDatagram(.hello(hello), linkID: 0), on: link.flow))
    }

    /// An outbound handshake did not complete.
    mutating func attemptFailed(_ link: LinkRecord, reason: String, now: MonotonicTime,
                                reschedule: Bool = true, countsAsFailedDial: Bool = true) {
        let avoided = flows[link.flow]?.prohibitedInterfaceName
        links[link.flow] = nil
        retireFlow(link.flow, linger: false, now: now)
        guard var peer = peers[link.peer] else { return }
        log("dial \(link.peer) on \(link.flow) failed: \(reason)")
        // A failed migration is harmless while the old link still carries audio; if that link died
        // meanwhile, this was the last hope and the normal reconnect path must take over.
        if link.isMigration, peer.primary != nil {
            return
        }
        // Every failure of a dial around an interface counts (not ready, flow failed, no HELLO_ACK), so
        // a wrong black-hole verdict cannot outlive a couple of attempts.
        if !link.isMigration, let avoided, peer.prohibitedInterfaceName == avoided {
            peer.prohibitedDialTimeouts += 1
            if peer.prohibitedDialTimeouts >= configuration.handshakeTimeoutsBeforeProhibitingInterface {
                log("dialling around \(avoided) did not help either; allowing it again")
                peer.prohibitedInterfaceName = nil
                peer.prohibitedDialTimeouts = 0
            }
        }
        if countsAsFailedDial, !link.isMigration {
            peer.consecutiveFailedDials += 1
            let failures = peer.consecutiveFailedDials
            // Rebuilds are global: while another peer's link is healthy they would only churn the
            // listener and browser that link depends on, for the sake of a peer that may be gone.
            let isOtherLinkHealthy = hasHealthyLink(toPeerOtherThan: link.peer, now: now)
            if isOtherLinkHealthy {
                if failures % configuration.failedDialsPerBrowserRebuild == 0
                    || failures % configuration.failedDialsPerListenerRebuild == 0 {
                    log("\(failures) failed dials to \(link.peer): no rebuild while another link is healthy")
                }
            } else {
                if failures % configuration.failedDialsPerBrowserRebuild == 0 {
                    log("\(failures) failed dials to \(link.peer): rebuilding browser")
                    emit(.rebuildBrowser)
                    isBrowserRunning = true
                    browserHealthySince = nil
                }
                if failures % configuration.failedDialsPerListenerRebuild == 0 {
                    log("\(failures) failed dials to \(link.peer): rebuilding listener")
                    emit(.rebuildListener)
                }
            }
            // With nothing else working, never give up on a peer; with another healthy link, a peer
            // the browser dropped and that keeps failing is most likely gone for good.
            if !peer.isParked, isOtherLinkHealthy, !peer.isAdvertised, !peer.isManualOverride,
               failures >= configuration.failedDialsBeforeParking {
                log("\(link.peer) not advertised, \(failures) dials failed: parked, redial every "
                    + "\(configuration.parkedRedialInterval)s")
                peer.isParked = true
            }
        }
        peers[link.peer] = peer
        guard peer.primary == nil, !hasHandshakingLink(link.peer) else { return }
        if !peer.hasBeenLinked, !peer.isAdvertised, links(of: link.peer).isEmpty {
            // Lost by the browser while this first dial was in flight (`peerLost` kept it only for the
            // dial): nothing left to redial. Report it gone so the UI stops showing it as connecting.
            log("dropping \(link.peer): no longer advertised and never linked")
            if case .connecting? = peer.reportedState {
                setReportedState(link.peer, .discovered)
            }
            peers[link.peer] = nil
            emitEvent(.peerLost(link.peer))
            return
        }
        if let state = peer.reportedState, Self.isUp(state) {
            setReportedState(link.peer, .disconnected(.timeout))
        }
        if reschedule {
            scheduleReconnect(link.peer, now: now)
        }
    }

    /// Plans the next dial for a peer without a link, following backoff and the dial holdoff.
    mutating func scheduleReconnect(_ id: PeerID, now: MonotonicTime) {
        guard var peer = peers[id], peer.primary == nil, !hasHandshakingLink(id), canDial(peer) else { return }
        let backoff = peer.isParked ? configuration.parkedRedialInterval : peer.backoff.nextDelay(using: &rng)
        let holdoff = peer.isManualOverride ? 0 : LinkArbiter.dialDelay(local: configuration.localID, remote: id,
                                                                         holdoff: configuration.dialHoldoff)
        peer.nextDialAt = now + backoff + holdoff
        peers[id] = peer
        log("next dial to \(id) in " + String(format: "%.2f", backoff + holdoff) + "s")
    }
}
