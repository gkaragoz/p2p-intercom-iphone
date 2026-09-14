import Foundation

// Link selection, reported state, timers, heartbeats and the browser policy.
extension LinkStateMachine {
    // MARK: - Link selection

    /// Re-evaluates a peer's links after any change: applies supersede marks, closes losing
    /// duplicates, picks the primary and reports up/down transitions.
    mutating func resolve(_ id: PeerID, lostReason: DisconnectReason, now: MonotonicTime) {
        guard peers[id] != nil else { return }
        let oldPrimary = peers[id]?.primary
        var established = links(of: id).filter { $0.isEstablished }

        if let superseding = established.first(where: { $0.supersedesPrimary }) {
            links[superseding.flow]?.supersedesPrimary = false
            if let old = oldPrimary, old != superseding.flow, let oldLink = links[old] {
                log("link \(superseding.linkID) replaces unhealthy link \(oldLink.linkID) to \(id)")
                send(.bye(.replaced), on: oldLink)
                links[old] = nil
                retireFlow(old, linger: true, now: now)
            }
            established = links(of: id).filter { $0.isEstablished }
        }

        let local = configuration.localID
        let best = established.max { a, b in
            LinkArbiter.isPreferred(candidate(for: b), over: candidate(for: a), local: local, remote: id)
        }
        if let best {
            for other in established where other.flow != best.flow {
                let sameDialer = other.isLocalDialer == best.isLocalDialer
                let reason: ByeReason = sameDialer ? .replaced : .duplicate
                log("closing link \(other.linkID) to \(id) on \(other.flow): bye(\(reason)), keeping \(best.flow)")
                send(.bye(reason), on: other)
                links[other.flow] = nil
                retireFlow(other.flow, linger: true, now: now)
            }
        }

        guard var peer = peers[id] else { return }
        peer.primary = best?.flow
        if best?.flow != oldPrimary {
            emit(.setAudioRoute(id, best.map { AudioRoute(flow: $0.flow, linkID: $0.linkID) }))
        }

        if let best {
            guard peer.linkUpSince == nil else {
                peers[id] = peer
                updateReportedState(id, now: now)
                return
            }
            let isResumption = peer.lastLinkedEpoch != nil && peer.lastLinkedEpoch == best.remoteEpoch
            peer.linkUpSince = now
            peer.hasBeenLinked = true
            peer.lastLinkedEpoch = best.remoteEpoch
            peer.dialsSinceLinkUp = 0
            peer.consecutiveFailedDials = 0
            peer.consecutiveHandshakeTimeouts = 0
            peer.infrastructureTimeouts.removeAll()
            peer.prohibitedDialTimeouts = 0
            // A link that did not come from a dial avoiding an interface (an inbound flow, or a plain
            // dial) proves the network works: stop dialling around it. A dial that only succeeded
            // because it avoided the interface keeps the block for the next reconnect.
            if let prohibited = peer.prohibitedInterfaceName, flows[best.flow]?.prohibitedInterfaceName == nil {
                log("link to \(id) came up without avoiding \(prohibited): allowing it again")
                peer.prohibitedInterfaceName = nil
            }
            peer.isManualOverride = false
            peer.isParked = false
            peer.nextDialAt = nil
            peer.controlOut.expediteAll()
            // The controller forgets the remote status when a link goes down; report it afresh on the
            // new link even if the value happens to equal what the previous link last carried.
            peer.reportedStatus = nil
            peers[id] = peer
            hasReportedLocalNetworkDenied = false
            let path = flows[best.flow]?.path ?? .unknown
            log("\(id) connected via \(path)\(isResumption ? " (resumed same instance)" : "")")
            setReportedState(id, .connected(path: path, isResumption: isResumption), force: true)
            flushControl(id, now: now)
            return
        }

        if let since = peer.linkUpSince {
            peer.backoff.linkWentDown(upFor: now - since)
            peer.linkUpSince = nil
            // Done here, not at the next link-up: the dialer sends its first heartbeat before `resolve`.
            peer.forgetRoundTripState()
        }
        peers[id] = peer
        // A replacement handshake is under way; report the outcome of that instead of flickering.
        guard !hasHandshakingLink(id) else { return }
        if !peer.hasBeenLinked, !peer.isDialable {
            // Only ever seen through a HELLO that never completed: nothing to redial, nothing to show.
            peers[id] = nil
            return
        }
        if let state = peer.reportedState, Self.isUp(state) {
            log("\(id) disconnected: \(lostReason)")
            setReportedState(id, .disconnected(lostReason))
        }
        scheduleReconnect(id, now: now)
    }

    // MARK: - Reported state

    mutating func updateReportedState(_ id: PeerID, now: MonotonicTime) {
        guard let peer = peers[id], let flow = peer.primary, let link = links[flow], link.isEstablished else { return }
        let desired: LinkState
        if health(of: link, now: now) == .alive {
            desired = .connected(path: flows[flow]?.path ?? .unknown, isResumption: true)
        } else {
            desired = .suspect
        }
        // Only a path change is news while connected; the resumption flag matters on link-up only.
        if case .connected(let path, _)? = peer.reportedState, case .connected(let newPath, _) = desired, path == newPath {
            return
        }
        if desired == .suspect, peer.reportedState != .suspect {
            log("\(id) suspect: silent for \(String(format: "%.2f", link.liveness.silence(at: now)))s")
        }
        setReportedState(id, desired)
    }

    mutating func setReportedState(_ id: PeerID, _ state: LinkState, force: Bool = false) {
        guard peers[id] != nil, force || peers[id]?.reportedState != state else { return }
        peers[id]?.reportedState = state
        emitEvent(.linkStateChanged(id, state))
    }

    // MARK: - Timers

    mutating func tick(now: MonotonicTime) {
        for id in flows.keys.sorted() {
            if let deadline = flows[id]?.closingDeadline, deadline <= now {
                flows[id] = nil
                emit(.cancelFlow(id))
            }
        }
        for id in unboundFlows {
            if let flow = flows[id], now - flow.createdAt >= configuration.unboundFlowTimeout {
                log("\(id): no valid HELLO within \(configuration.unboundFlowTimeout)s; cancelling")
                retireFlow(id, linger: false, now: now)
            }
        }

        for flowID in links.keys.sorted() {
            guard let link = links[flowID], link.isHandshaking, case .handshaking(let deadline) = link.phase else { continue }
            if link.isLocalDialer {
                guard let flow = flows[flowID] else { continue }
                if !flow.isReady {
                    if !flow.isLocalNetworkDenied, now >= deadline {
                        attemptFailed(link, reason: "flow not ready within \(configuration.flowReadyTimeout)s", now: now)
                    }
                    continue
                }
                if now >= deadline {
                    handshakeTimedOut(link, now: now)
                } else if let next = link.nextHelloAt, now >= next {
                    sendHello(on: link)
                    let retry = configuration.helloRetryInterval
                    let following = next + retry > now ? next + retry : now + retry
                    links[flowID]?.nextHelloAt = following
                }
            } else if now >= deadline {
                log("\(flowID): \(link.peer) never confirmed link \(link.linkID); dropping")
                links[flowID] = nil
                retireFlow(flowID, linger: false, now: now)
                resolve(link.peer, lostReason: .timeout, now: now)
            }
        }

        for flowID in links.keys.sorted() {
            guard let link = links[flowID], link.isEstablished else { continue }
            let health = health(of: link, now: now)
            if health == .dead {
                let silence = String(format: "silent for %.2fs", link.liveness.silence(at: now))
                let why = link.liveness.hasPersistentSendErrors(at: now)
                    ? "\(link.liveness.sendErrorCount) sends failing, \(silence)"
                    : silence
                log("link \(link.linkID) to \(link.peer) on \(flowID) dead: \(why)")
                links[flowID] = nil
                retireFlow(flowID, linger: false, now: now)
                resolve(link.peer, lostReason: .timeout, now: now)
                continue
            }
            if now >= link.nextHeartbeatAt {
                sendHeartbeat(flowID, now: now)
            }
            if peers[link.peer]?.primary == flowID {
                updateReportedState(link.peer, now: now)
            }
        }

        for id in knownPeers {
            flushControl(id, now: now)
            reportRoundTripIfDue(id, now: now)
        }
    }

    private mutating func handshakeTimedOut(_ link: LinkRecord, now: MonotonicTime) {
        guard var peer = peers[link.peer] else { return }
        if !link.isMigration {
            peer.consecutiveHandshakeTimeouts += 1
            // Failed dials that avoided an interface are counted in `attemptFailed`, whatever the cause.
            if let flow = flows[link.flow], flow.prohibitedInterfaceName == nil,
               flow.path == .wifiNetwork, let name = flow.interfaceName {
                let threshold = configuration.handshakeTimeoutsBeforeProhibitingInterface
                let count = (peer.infrastructureTimeouts[name] ?? 0) + 1
                peer.infrastructureTimeouts[name] = count
                if count >= threshold {
                    log("\(count) handshake timeouts via \(name): next dial avoids it (black-holed network?)")
                    peer.prohibitedInterfaceName = name
                    peer.prohibitedDialTimeouts = 0
                    peer.infrastructureTimeouts[name] = 0
                }
            }
        }
        peers[link.peer] = peer
        attemptFailed(link, reason: "no HELLO_ACK", now: now)
    }

    // MARK: - Heartbeats

    mutating func sendHeartbeat(_ flowID: FlowID, now: MonotonicTime) {
        guard let link = links[flowID], link.isEstablished, var peer = peers[link.peer] else { return }
        let ping = peer.roundTrip.makePing(nowMs: now.milliseconds)
        var echoSequence: UInt32 = 0
        var echoDelayMs: UInt16 = 0
        // An echo held too long for its 16-bit millisecond delay would yield a wrong sample: send none.
        if let last = peer.lastRemoteHeartbeat, now - last.receivedAt < Double(UInt16.max) / 1_000 {
            echoSequence = last.sequence
            echoDelayMs = UInt16(min(Double(UInt16.max - 1), max(0, ((now - last.receivedAt) * 1_000).rounded())))
        }
        peers[link.peer] = peer
        let beat = NetHeartbeat(sequence: ping.id, sentMs: UInt32(truncatingIfNeeded: now.milliseconds),
                                echoSequence: echoSequence, echoDelayMs: echoDelayMs)
        send(.heartbeat(beat), on: link)
        let interval = link.liveness.localHeartbeatInterval
        var next = link.nextHeartbeatAt > now ? now + interval : link.nextHeartbeatAt + interval
        if next <= now {
            next = now + interval
        }
        links[flowID]?.nextHeartbeatAt = next
    }

    private mutating func reportRoundTripIfDue(_ id: PeerID, now: MonotonicTime) {
        guard let peer = peers[id], peer.hasUnreportedRoundTrip, peer.primary != nil,
              let rtt = peer.roundTrip.smoothedRTTMs else { return }
        if let last = peer.lastRoundTripReportAt, now - last < configuration.roundTripReportInterval { return }
        peers[id]?.hasUnreportedRoundTrip = false
        peers[id]?.lastRoundTripReportAt = now
        emitEvent(.roundTrip(id, ms: rtt))
    }

    // MARK: - Browser policy

    /// Browse while any wanted peer lacks a healthy link; stop once all have been healthy for a
    /// while, because an ongoing peer-to-peer browse degrades the live link (TN3213). The listener
    /// keeps advertising the whole time so a restarted peer can always dial back.
    mutating func updateBrowser(now: MonotonicTime) {
        guard isRunning else { return }
        let wanted = peers.values.filter {
            $0.suppression == nil && !$0.isParked
                && ($0.hasBeenLinked || ($0.isAdvertised && $0.compatibility == .compatible))
        }
        let healthy = !wanted.isEmpty && wanted.allSatisfy { hasHealthyPrimary($0, now: now) }
        if healthy {
            let since = browserHealthySince ?? now
            browserHealthySince = since
            if isBrowserRunning, now - since >= configuration.browserIdleAfterHealthy {
                log("links healthy for \(configuration.browserIdleAfterHealthy)s: stopping browser")
                emit(.stopBrowser)
                isBrowserRunning = false
            }
        } else {
            browserHealthySince = nil
            if !isBrowserRunning {
                log("starting browser")
                emit(.startBrowser)
                isBrowserRunning = true
            }
        }
    }

    mutating func restartBrowser(now: MonotonicTime) {
        browserHealthySince = nil
        if !isBrowserRunning {
            log("starting browser")
            emit(.startBrowser)
            isBrowserRunning = true
        }
    }
}
