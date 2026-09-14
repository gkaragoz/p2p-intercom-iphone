import XCTest
@testable import IntercomCore

final class LinkStateMachineTests: XCTestCase {
    private var net: SimNetwork!
    private var low: SimNode!
    private var high: SimNode!

    override func setUp() {
        super.setUp()
        net = SimNetwork()
    }

    private func makePair(lowAuth: HelloAuthenticator = UnauthenticatedHello(),
                          highAuth: HelloAuthenticator = UnauthenticatedHello(),
                          configure: (inout LinkStateMachine.Configuration) -> Void = { _ in }) {
        low = net.addNode(SimNetwork.lowID, seed: 1, authenticator: lowAuth, configure: configure)
        high = net.addNode(SimNetwork.highID, seed: 2, authenticator: highAuth, configure: configure)
    }

    private func startBoth(discoverMutually: Bool = true) {
        low.handle(.start)
        high.handle(.start)
        if discoverMutually {
            low.handle(.peerDiscovered(high.record))
            high.handle(.peerDiscovered(low.record))
        }
    }

    private func isConnected(_ node: SimNode, to peer: PeerID) -> Bool {
        if case .connected? = node.machine.linkState(of: peer) { return node.audioRoutes[peer] != nil }
        return false
    }

    private var bothConnected: Bool {
        isConnected(low, to: high.id) && isConnected(high, to: low.id)
    }

    /// Both primaries are the two ends of the same UDP flow.
    private func assertPrimariesPaired(file: StaticString = #filePath, line: UInt = #line) {
        guard let lowRoute = low.machine.audioRoute(for: high.id),
              let highRoute = high.machine.audioRoute(for: low.id) else {
            return XCTFail("missing audio route", file: file, line: line)
        }
        XCTAssertEqual(low.routes[lowRoute.flow]?.remoteFlow, highRoute.flow, file: file, line: line)
        XCTAssertEqual(lowRoute.linkID, highRoute.linkID, file: file, line: line)
        XCTAssertEqual(low.audioRoutes[high.id], lowRoute, file: file, line: line)
        XCTAssertEqual(high.audioRoutes[low.id], highRoute, file: file, line: line)
    }

    private func connectPair() {
        makePair()
        startBoth()
        net.run(for: 2, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
    }

    private func disconnects(_ node: SimNode, peer: PeerID) -> [LinkState] {
        node.linkEvents(for: peer).filter {
            if case .disconnected = $0 { return true }
            return false
        }
    }

    // MARK: - Establishment

    func testLowerIDDialsImmediatelyAndBothConnect() {
        makePair()
        startBoth()
        let start = net.now
        net.run(for: 2, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        XCTAssertLessThan(net.now - start, 0.2)
        XCTAssertEqual(low.opened.count, 1)
        XCTAssertEqual(high.opened.count, 0, "the higher ID must hold off while the lower one dials")
        XCTAssertEqual(low.lastLinkState(for: high.id), .connected(path: .peerToPeerWiFi, isResumption: false))
        XCTAssertEqual(high.lastLinkState(for: low.id), .connected(path: .unknown, isResumption: false))
        assertPrimariesPaired()
        net.run(for: 5)
        XCTAssertTrue(bothConnected)
        XCTAssertEqual(low.opened.count, 1)
        XCTAssertEqual(high.opened.count, 0)
        XCTAssertTrue(disconnects(low, peer: high.id).isEmpty)
    }

    func testHandshakeNamesAndCompatibilityAreReported() {
        connectPair()
        let adverts = high.events.compactMap { entry -> PeerAdvert? in
            if case .peerDiscovered(let advert) = entry.event { return advert }
            return nil
        }
        XCTAssertEqual(adverts.last?.displayName, low.machine.configuration.displayName)
        XCTAssertEqual(adverts.last?.compatibility, .compatible)
    }

    func testAsymmetricDiscoveryHigherSideDialsAfterHoldoff() {
        makePair()
        startBoth(discoverMutually: false)
        high.handle(.peerDiscovered(low.record))
        net.run(for: 0.7)
        XCTAssertTrue(high.opened.isEmpty)
        XCTAssertFalse(bothConnected)
        net.run(for: 1, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        XCTAssertEqual(high.opened.count, 1)
        XCTAssertTrue(low.opened.isEmpty)
        assertPrimariesPaired()
        // The lower side never discovered the higher one, yet accepted it as a peer.
        XCTAssertTrue(low.events.contains { if case .peerDiscovered(let a) = $0.event { return a.id == high.id }; return false })
    }

    func testSimultaneousDialConvergesOnFlowDialledByLowerID() {
        makePair { $0.dialHoldoff = 0 }
        startBoth()
        net.run(for: 3)
        XCTAssertTrue(bothConnected)
        XCTAssertEqual(low.opened.count, 1)
        XCTAssertEqual(high.opened.count, 1)
        assertPrimariesPaired()
        let lowPrimary = low.machine.audioRoute(for: high.id)!.flow
        XCTAssertTrue(low.opened.contains { $0.flow == lowPrimary }, "the lower ID's dial must win")
        XCTAssertEqual(low.machine.links.count, 1)
        XCTAssertEqual(high.machine.links.count, 1)
        XCTAssertTrue(disconnects(low, peer: high.id).isEmpty)
        XCTAssertTrue(disconnects(high, peer: low.id).isEmpty)
        net.run(for: 3)
        XCTAssertTrue(bothConnected)
        assertPrimariesPaired()
    }

    func testSimultaneousDialWithDelayedHelloStillConverges() {
        makePair { $0.dialHoldoff = 0 }
        net.latency = 0.3
        startBoth()
        net.run(for: 6)
        XCTAssertTrue(bothConnected)
        assertPrimariesPaired()
        XCTAssertEqual(low.machine.links.count, 1)
        XCTAssertEqual(high.machine.links.count, 1)
    }

    func testLostHellosAreRetransmitted() {
        makePair()
        var dropped = 0
        net.dropFilter = { _, datagram in
            if datagram.type == .hello, dropped < 2 {
                dropped += 1
                return true
            }
            return false
        }
        startBoth()
        net.run(for: 2, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(low.opened.count, 1, "retransmission, not a redial")
        XCTAssertGreaterThanOrEqual(low.sent.filter { $0.datagram.type == .hello }.count, 3)
    }

    // MARK: - Liveness and reconnect

    func testHeartbeatLossIsDeadWithinTwoSecondsAndReconnectResumes() {
        connectPair()
        net.run(for: 1)
        net.isPartitioned = true
        let cut = net.now
        net.run(for: 5, until: { !self.disconnects(self.low, peer: self.high.id).isEmpty })
        let detection = net.now - cut
        XCTAssertLessThanOrEqual(detection, 2.1, "dead must be declared within ~2 s")
        XCTAssertGreaterThanOrEqual(detection, 1.8)
        let states = low.linkEvents(for: high.id)
        XCTAssertTrue(states.contains(.suspect), "suspect must be reported before dead")
        XCTAssertEqual(disconnects(low, peer: high.id), [.disconnected(.timeout)])
        XCTAssertNil(low.audioRoutes[high.id])

        net.run(for: 1)
        net.isPartitioned = false
        net.run(for: 6, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        for (node, peer) in [(low!, high.id), (high!, low.id)] {
            if case .connected(_, let resumed)? = node.lastLinkState(for: peer) {
                XCTAssertTrue(resumed, "same app instance on both ends: jitter/RTT state must be kept")
            } else {
                XCTFail("not connected")
            }
        }
        assertPrimariesPaired()
    }

    func testReconnectNeverGivesUpAndDelaysStayCapped() {
        connectPair()
        net.isPartitioned = true
        let cut = net.now
        net.run(for: 60)
        let dials = low.opened.dropFirst().map { $0.flow }
        let times = low.sent.filter { entry in dials.contains(entry.flow) && entry.datagram.type == .hello }
        XCTAssertGreaterThan(dials.count, 12, "must keep dialling for the whole outage")
        // Gap between the first HELLOs of consecutive dials: handshake timeout (≤ 2 s) + backoff (≤ 2.4 s).
        var firstHello: [FlowID: MonotonicTime] = [:]
        for entry in times where firstHello[entry.flow] == nil {
            firstHello[entry.flow] = entry.time
        }
        let ordered = dials.compactMap { firstHello[$0] }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(b - a, 2 + 2.4 + 0.15)
        }
        XCTAssertGreaterThan(ordered.last! - cut, 55, "still dialling at the end of the outage")
        net.isPartitioned = false
        net.run(for: 6, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
    }

    func testPeerRestartReplacesLinkBeforeLivenessTimeout() {
        connectPair()
        net.run(for: 1)
        let oldEpoch = high.machine.configuration.localEpoch
        high = net.restart(SimNetwork.highID, seed: 99)
        XCTAssertNotEqual(high.machine.configuration.localEpoch, oldEpoch)
        high.handle(.start)
        high.handle(.peerDiscovered(low.record))
        let restartTime = net.now
        let lowEventsBefore = low.events.count
        net.run(for: 3, until: {
            self.isConnected(self.high, to: self.low.id) && self.low.events.count > lowEventsBefore
                && self.low.lastLinkState(for: self.high.id) == .connected(path: .unknown, isResumption: false)
        })
        XCTAssertLessThan(net.now - restartTime, 1.5, "replace on the new epoch, not after the 2 s dead timeout")
        XCTAssertTrue(bothConnected)
        assertPrimariesPaired()
        XCTAssertTrue(disconnects(low, peer: high.id).isEmpty, "a restart with a quick redial must not flicker")
    }

    func testReplayedHelloFromOldInstanceDoesNotDropHealthyLink() {
        makePair(lowAuth: KeyedHelloAuthenticator(key: 7), highAuth: KeyedHelloAuthenticator(key: 7))
        startBoth()
        net.run(for: 2, until: { self.bothConnected })
        guard let captured = low.sent.first(where: { $0.datagram.type == .hello })?.datagram else {
            return XCTFail("no HELLO sent")
        }
        // The lower side restarts and links again under a new epoch; the captured HELLO is now stale.
        low = net.restart(SimNetwork.lowID, seed: 77, authenticator: KeyedHelloAuthenticator(key: 7))
        low.handle(.start)
        low.handle(.peerDiscovered(high.record))
        let newEpoch = low.machine.configuration.localEpoch
        net.run(for: 3, until: { self.bothConnected && self.high.machine.peers[self.low.id]?.remoteEpoch == newEpoch })
        XCTAssertTrue(bothConnected)
        net.run(for: 1)
        let route = high.audioRoutes[low.id]
        XCTAssertNotNil(route)
        let eventsBefore = high.events.count

        // An attacker replays the old HELLO from a new source port.
        let replay = high.machine.makeFlowID()
        high.handle(.inboundFlow(replay))
        high.handle(.datagram(captured, on: replay))
        XCTAssertEqual(high.audioRoutes[low.id], route, "audio keeps flowing on the confirmed link")
        XCTAssertEqual(high.machine.peers[low.id]?.remoteEpoch, newEpoch)
        XCTAssertTrue(bothConnected)

        net.run(for: 2.5)
        XCTAssertTrue(bothConnected)
        XCTAssertEqual(high.audioRoutes[low.id], route)
        XCTAssertTrue(high.cancelled.contains(replay), "the unconfirmed handshake times out")
        XCTAssertEqual(high.machine.links.count, 1)
        let later = high.events.dropFirst(eventsBefore).compactMap { entry -> LinkState? in
            if case .linkStateChanged(_, let state) = entry.event { return state }
            return nil
        }
        XCTAssertTrue(later.isEmpty, "no disconnect, no new link-up: \(later)")
    }

    func testLowerSideRestartDialsImmediately() {
        connectPair()
        net.run(for: 1)
        low = net.restart(SimNetwork.lowID, seed: 77)
        low.handle(.start)
        low.handle(.peerDiscovered(high.record))
        let restartTime = net.now
        let highEventsBefore = high.events.count
        // The old link stays primary on the higher side until the new flow carries a sealed datagram.
        net.run(for: 3, until: {
            self.bothConnected && self.high.events.count > highEventsBefore
                && self.high.lastLinkState(for: self.low.id) == .connected(path: .unknown, isResumption: false)
        })
        XCTAssertLessThan(net.now - restartTime, 0.3)
        assertPrimariesPaired()
        XCTAssertEqual(high.machine.links.count, 1)
    }

    func testStopSendsByeSoPeerReactsAtOnceAndReconnectsWhenItReturns() {
        connectPair()
        low.handle(.stop)
        net.run(for: 0.1)
        XCTAssertEqual(disconnects(high, peer: low.id), [.disconnected(.remoteBye(.stopped))])
        XCTAssertEqual(low.lastLinkState(for: high.id), .disconnected(.stopped))
        net.run(for: 3)
        XCTAssertFalse(high.opened.isEmpty, "the peer keeps trying while the other phone is away")
        low.handle(.start)
        low.handle(.peerDiscovered(high.record))
        net.run(for: 4, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
    }

    func testPersistentSendErrorsKillLinkQuickly() {
        connectPair()
        low.failSends = true
        let start = net.now
        net.run(for: 3, until: { !self.disconnects(self.low, peer: self.high.id).isEmpty })
        XCTAssertLessThan(net.now - start, 1.0)
    }

    func testBackgroundPeerSlowsHeartbeatsAndGetsLongerDeadline() {
        connectPair()
        high.handle(.setAppActive(false))
        net.run(for: 1)
        let window = net.now
        net.run(for: 2)
        let beats = high.sent.filter { $0.time > window && $0.datagram.type == .heartbeat }
        XCTAssertLessThanOrEqual(beats.count, 5)
        XCTAssertGreaterThanOrEqual(beats.count, 3)
        XCTAssertTrue(beats.allSatisfy { $0.datagram.isSenderInBackground })
        net.isPartitioned = true
        let cut = net.now
        net.run(for: 6, until: { !self.disconnects(self.low, peer: self.high.id).isEmpty })
        let lastHeard = high.sent.last { $0.time <= cut && $0.datagram.type == .heartbeat }!.time
        XCTAssertEqual(net.now - lastHeard, 3, accuracy: 0.1, "3 s dead deadline while the peer is in the background")
    }

    func testForegroundResetsBackoffAndRedialsSoon() {
        connectPair()
        high.handle(.stop)
        net.run(for: 20)
        // Wait for a moment between attempts where the capped backoff still has a while to go.
        net.run(for: 10, until: {
            guard self.low.machine.links.isEmpty, let next = self.low.machine.peers[self.high.id]?.nextDialAt else { return false }
            return next - self.net.now > 1
        })
        let dialsBefore = low.opened.count
        low.handle(.setAppActive(false))
        low.handle(.setAppActive(true))
        net.run(for: 0.1)
        XCTAssertGreaterThan(low.opened.count, dialsBefore)
    }

    // MARK: - Browser and listener policy

    func testBrowserStopsAfterHealthyLinkAndRestartsWhenSuspect() {
        connectPair()
        net.run(for: 2.5)
        XCTAssertTrue(low.browserRunning)
        net.run(for: 1)
        XCTAssertFalse(low.browserRunning)
        XCTAssertFalse(high.browserRunning)
        XCTAssertTrue(low.listenerRunning, "the listener keeps advertising")
        net.isPartitioned = true
        net.run(for: 0.8)
        XCTAssertTrue(low.browserRunning, "suspect link must restart the browser")
    }

    func testBrowserRebuiltAfterThreeFailedDialsAndListenerAfterSix() {
        makePair()
        low.handle(.start)
        low.handle(.peerDiscovered(high.record)) // `high` never starts: every dial times out.
        net.run(for: 40)
        let failures = low.opened.count - low.machine.links.count
        XCTAssertGreaterThanOrEqual(failures, 6)
        XCTAssertEqual(low.browserRebuilds, failures / 3)
        XCTAssertEqual(low.listenerRebuilds, failures / 6)
    }

    // MARK: - Extra peers

    private static let thirdID = PeerID(installID: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)

    private func dials(_ node: SimNode, to peer: PeerID) -> Int {
        node.opened.filter { $0.peer == peer }.count
    }

    func testVanishedExtraPeerIsParkedWithoutChurningTheHealthyLink() {
        connectPair()
        let third = net.addNode(Self.thirdID, seed: 3)
        third.handle(.start)
        low.handle(.peerDiscovered(third.record))
        third.handle(.peerDiscovered(low.record))
        net.run(for: 3, until: { self.isConnected(self.low, to: third.id) })
        XCTAssertTrue(isConnected(low, to: third.id))

        // The third install goes away for good (deleted app, quit simulator): silence, then Bonjour removal.
        third.isRunning = false
        low.handle(.peerLost(third.id))
        let browserRebuilds = low.browserRebuilds
        let listenerRebuilds = low.listenerRebuilds
        net.run(for: 60)
        XCTAssertTrue(bothConnected, "the real partner's link is untouched")
        XCTAssertEqual(low.machine.peers[third.id]?.isParked, true)
        XCTAssertFalse(low.browserRunning, "a parked peer does not keep the browser running")
        let dialsBefore = dials(low, to: third.id)
        net.run(for: 60)
        XCTAssertGreaterThanOrEqual(dials(low, to: third.id) - dialsBefore, 1, "still tried now and then")
        XCTAssertLessThanOrEqual(dials(low, to: third.id) - dialsBefore, 2)
        XCTAssertEqual(low.browserRebuilds, browserRebuilds)
        XCTAssertEqual(low.listenerRebuilds, listenerRebuilds)
        XCTAssertFalse(low.browserRunning)
        XCTAssertTrue(bothConnected)
        XCTAssertTrue(disconnects(low, peer: high.id).isEmpty)

        // It comes back: rediscovery dials right away.
        let back = net.restart(Self.thirdID, seed: 33)
        back.handle(.start)
        back.handle(.peerDiscovered(low.record))
        low.handle(.peerDiscovered(back.record))
        net.run(for: 3, until: { self.isConnected(self.low, to: back.id) && self.isConnected(back, to: self.low.id) })
        XCTAssertTrue(isConnected(low, to: back.id))
        XCTAssertEqual(low.machine.peers[back.id]?.isParked, false)
        XCTAssertTrue(bothConnected)
    }

    func testVanishedPeerIsStillRedialledNormallyWhenNoOtherLinkWorks() {
        connectPair()
        high.isRunning = false
        low.handle(.peerLost(high.id))
        net.run(for: 60)
        XCTAssertEqual(low.machine.peers[high.id]?.isParked, false)
        XCTAssertGreaterThan(dials(low, to: high.id), 10)
        XCTAssertGreaterThan(low.browserRebuilds, 0, "discovery is rebuilt when nothing works")
    }

    func testPeerLostDuringItsFirstDialIsDroppedWhenTheDialFails() {
        connectPair()
        let third = net.addNode(Self.thirdID, seed: 3) // Never started: the dial cannot complete.
        low.handle(.peerDiscovered(third.record))
        net.run(for: 0.1)
        XCTAssertEqual(dials(low, to: third.id), 1)
        low.handle(.peerLost(third.id))
        XCTAssertNotNil(low.machine.peers[third.id], "kept while its dial is in flight")
        net.run(for: 30)
        XCTAssertNil(low.machine.peers[third.id])
        XCTAssertEqual(dials(low, to: third.id), 1, "not redialled")
        XCTAssertEqual(low.lastLinkState(for: third.id), .discovered, "no longer shown as connecting")
        let lostEvents = low.events.filter { if case .peerLost(third.id) = $0.event { return true }; return false }
        XCTAssertEqual(lostEvents.count, 2, "reported lost again once it is really dropped")
        XCTAssertEqual(low.browserRebuilds, 0)
        XCTAssertEqual(low.listenerRebuilds, 0)
        XCTAssertTrue(bothConnected)
    }

    // MARK: - Control and status

    func testControlMessageDeliveredExactlyOnceDespiteLostAcks() {
        connectPair()
        var droppedAcks = 0
        net.dropFilter = { _, datagram in
            if datagram.type == .controlAck, droppedAcks < 3 {
                droppedAcks += 1
                return true
            }
            return false
        }
        let message = ControlMessage.talkState(.init(isTalking: true, isMuted: false))
        low.handle(.sendControl(message))
        net.run(for: 2)
        let delivered = high.events.filter { if case .control(message, from: low.id) = $0.event { return true }; return false }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(droppedAcks, 3)
        XCTAssertGreaterThanOrEqual(low.sent.filter { $0.datagram.type == .control }.count, 4)
        XCTAssertTrue(low.machine.peers[high.id]!.controlOut.pending.isEmpty)
    }

    func testLocalStatusReachesPeerWithoutWaitingForHeartbeat() {
        connectPair()
        net.run(for: 0.3)
        let status = RemoteStatus(isTalking: true, isMuted: false, mode: .pushToTalk, isAudioPaused: false)
        low.handle(.updateLocalStatus(status))
        net.run(for: 0.02)
        XCTAssertTrue(high.events.contains { $0.event == .remoteStatus(status, from: low.id) })
    }

    func testRemoteStatusIsReportedAgainAfterReconnect() {
        connectPair()
        let status = RemoteStatus(isTalking: false, isMuted: true, mode: .voiceActivated, isAudioPaused: false)
        low.handle(.updateLocalStatus(status))
        net.run(for: 0.5)
        let statusEvents = { self.high.events.filter { $0.event == .remoteStatus(status, from: self.low.id) }.count }
        XCTAssertEqual(statusEvents(), 1)

        // The controller forgets the peer's status on disconnect, so an unchanged value must be re-sent.
        net.isPartitioned = true
        net.run(for: 5, until: { !self.disconnects(self.high, peer: self.low.id).isEmpty })
        net.isPartitioned = false
        net.run(for: 6, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        net.run(for: 0.5)
        XCTAssertEqual(statusEvents(), 2)
    }

    func testRoundTripAfterLongOutageIgnoresPingsOfTheOldLink() {
        connectPair()
        low.handle(.setAppActive(false))
        high.handle(.setAppActive(false))
        net.run(for: 2)
        // The lower side's direction fades first, so the higher side's last pings are never echoed;
        // then the phones are apart for two minutes.
        net.dropFilter = { from, _ in from === self.low }
        net.run(for: 6, until: { !self.disconnects(self.high, peer: self.low.id).isEmpty })
        XCTAssertFalse(disconnects(high, peer: low.id).isEmpty)
        net.dropFilter = nil
        net.isPartitioned = true
        // The lower side redials first on its return; its first heartbeat carries the echo it still holds.
        high.reportFlowsReady = false
        net.run(for: 120)
        XCTAssertFalse(disconnects(low, peer: high.id).isEmpty)
        net.isPartitioned = false
        let heal = net.now
        net.run(for: 10, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        high.reportFlowsReady = true
        if let route = low.machine.audioRoute(for: high.id) {
            XCTAssertTrue(low.opened.contains { $0.flow == route.flow }, "the lower side dialled the new link")
        }
        net.run(for: 5)
        for node in [low!, high!] {
            let samples = node.events.filter { $0.time >= heal }.compactMap { entry -> Double? in
                if case .roundTrip(_, let ms) = entry.event { return ms }
                return nil
            }
            XCTAssertFalse(samples.isEmpty)
            for ms in samples {
                XCTAssertLessThan(ms, 1_000, "\(node.machine.configuration.displayName): stale echo matched")
            }
        }
    }

    func testRoundTripTimeIsMeasuredFromHeartbeats() {
        connectPair()
        net.run(for: 2)
        let samples = low.events.compactMap { entry -> Double? in
            if case .roundTrip(_, let ms) = entry.event { return ms }
            return nil
        }
        XCTAssertFalse(samples.isEmpty)
        for ms in samples {
            XCTAssertEqual(ms, 10, accuracy: 2.5)
        }
        let spacing = low.events.filter { if case .roundTrip = $0.event { return true }; return false }.map { $0.time }
        for (a, b) in zip(spacing, spacing.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.99, "RTT reports are rate limited")
        }
    }

    // MARK: - User commands and security

    func testDisconnectAllSuppressesReconnectOnBothSidesUntilConnect() {
        connectPair()
        low.handle(.disconnectAll)
        net.run(for: 0.1)
        XCTAssertEqual(low.lastLinkState(for: high.id), .disconnected(.userRequested))
        XCTAssertEqual(high.lastLinkState(for: low.id), .disconnected(.remoteBye(.userDisconnect)))
        let lowDials = low.opened.count
        let highDials = high.opened.count
        net.run(for: 10)
        XCTAssertEqual(low.opened.count, lowDials)
        XCTAssertEqual(high.opened.count, highDials)
        XCTAssertFalse(bothConnected)

        low.handle(.connect(high.id))
        net.run(for: 2, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
    }

    func testPeerCanDialBackAfterItWasToldByeUserDisconnect() {
        connectPair()
        high.handle(.disconnectAll)
        net.run(for: 1)
        XCTAssertFalse(bothConnected)
        high.handle(.connect(low.id))
        net.run(for: 3, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
    }

    func testPairingMismatchWarnsBothSidesAndStopsDialling() {
        makePair(lowAuth: KeyedHelloAuthenticator(key: 1), highAuth: KeyedHelloAuthenticator(key: 2))
        startBoth()
        net.run(for: 5)
        XCTAssertFalse(bothConnected)
        XCTAssertTrue(low.events.contains { $0.event == .warning(.pairingMismatch(high.id)) })
        XCTAssertTrue(high.events.contains { $0.event == .warning(.pairingMismatch(low.id)) })
        XCTAssertEqual(low.opened.count, 1, "no automatic redial with a different pairing code")
        XCTAssertLessThanOrEqual(high.opened.count, 1)
    }

    func testMatchingAuthenticatorsConnect() {
        makePair(lowAuth: KeyedHelloAuthenticator(key: 7), highAuth: KeyedHelloAuthenticator(key: 7))
        startBoth()
        net.run(for: 2, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
    }

    func testDifferentKeyTagIsNotDialledAutomatically() {
        makePair()
        low.handle(.start)
        let stranger = DiscoveryRecord(peerID: high.id, displayName: "Stranger", keyTag: "deadbeef")
        low.handle(.peerDiscovered(stranger))
        net.run(for: 3)
        XCTAssertTrue(low.opened.isEmpty)
        XCTAssertTrue(low.events.contains {
            if case .peerDiscovered(let advert) = $0.event { return advert.compatibility == .pairingMismatch }
            return false
        })
    }

    func testIncompatibleVersionIsRefusedExplicitly() {
        low = net.addNode(SimNetwork.lowID, seed: 1)
        high = net.addNode(SimNetwork.highID, seed: 2) { $0.protocolVersion = 3 }
        low.handle(.start)
        high.handle(.start)
        high.handle(.peerDiscovered(low.record))
        low.handle(.peerDiscovered(DiscoveryRecord(peerID: high.id, displayName: "new", keyTag: "")))
        net.run(for: 3)
        XCTAssertFalse(bothConnected)
        XCTAssertTrue(high.events.contains { $0.event == .warning(.incompatibleVersion(low.id)) })
    }

    // MARK: - Paths

    func testBetterPathMigrationSwitchesFlowsWithoutDisconnect() {
        connectPair()
        net.run(for: 1)
        let oldFlow = low.machine.audioRoute(for: high.id)!.flow
        let eventsBefore = low.events.count
        low.handle(.flowBetterPathAvailable(oldFlow))
        net.run(for: 2)
        XCTAssertTrue(bothConnected)
        let newFlow = low.machine.audioRoute(for: high.id)!.flow
        XCTAssertNotEqual(newFlow, oldFlow)
        assertPrimariesPaired()
        XCTAssertTrue(low.cancelled.contains(oldFlow))
        let later = low.events.dropFirst(eventsBefore).compactMap { entry -> LinkState? in
            if case .linkStateChanged(_, let state) = entry.event { return state }
            return nil
        }
        XCTAssertFalse(later.contains { if case .disconnected = $0 { return true }; return $0 == .suspect })
        XCTAssertEqual(low.machine.links.count, 1)
        XCTAssertEqual(high.machine.links.count, 1)
    }

    func testMigrationThatOutlivesDeadPrimaryFallsBackToReconnect() {
        connectPair()
        let oldFlow = low.machine.audioRoute(for: high.id)!.flow
        low.reportFlowsReady = false // the replacement flow never becomes ready
        low.handle(.flowBetterPathAvailable(oldFlow))
        net.isPartitioned = true
        net.run(for: 2.5)
        XCTAssertTrue(disconnects(low, peer: high.id).isEmpty, "the pending replacement defers the verdict")
        net.run(for: 1)
        XCTAssertEqual(disconnects(low, peer: high.id), [.disconnected(.timeout)])
        low.reportFlowsReady = true
        net.isPartitioned = false
        net.run(for: 8, until: { self.bothConnected })
        XCTAssertTrue(bothConnected)
        assertPrimariesPaired()
    }

    func testBlackHoledInfrastructureInterfaceIsAvoidedAfterTwoTimeouts() {
        makePair()
        low.reportedPath = (.wifiNetwork, "en0")
        // Client isolation: replies never come back unless the dial avoided en0.
        net.dropFilter = { [unowned self] node, _ in
            node === self.high && self.low.opened.last?.prohibited == nil
        }
        startBoth()
        high.handle(.stop) // Only the lower side dials in this scenario.
        high.handle(.start)
        net.run(for: 10, until: { self.isConnected(self.low, to: self.high.id) })
        XCTAssertTrue(isConnected(low, to: high.id))
        XCTAssertEqual(low.opened.prefix(2).map { $0.prohibited }, [nil, nil])
        XCTAssertEqual(low.opened.last?.prohibited, "en0")
    }

    func testWrongBlackHoleVerdictDoesNotPreventReconnect() {
        connectPair()
        for node in [low!, high!] {
            node.reportedPath = (.wifiNetwork, "en0")
            // Out of peer-to-peer range: a dial around en0 never finds a route.
            node.reportProhibitedFlowsReady = false
        }
        // A stall long enough for HELLO timeouts on en0 on both sides (e.g. the access point hangs).
        net.isPartitioned = true
        net.run(for: 9)
        XCTAssertTrue(low.opened.contains { $0.prohibited == "en0" })
        XCTAssertTrue(high.opened.contains { $0.prohibited == "en0" })
        net.isPartitioned = false
        let healed = net.now
        net.run(for: 15, until: { self.bothConnected })
        XCTAssertTrue(bothConnected, "en0 works again; avoiding it must not stop reconnects")
        XCTAssertLessThan(net.now - healed, 12)
        assertPrimariesPaired()
        for (node, peer) in [(low!, high.id), (high!, low.id)] {
            XCTAssertNil(node.machine.peers[peer]?.prohibitedInterfaceName, "a link over en0 lifts the verdict")
        }
    }

    func testBlackHoleVerdictIsClearedByConnectAndSkippedByMigration() {
        makePair()
        low.reportedPath = (.wifiNetwork, "en0")
        net.dropFilter = { [unowned self] node, _ in
            node === self.high && self.low.opened.last?.prohibited == nil
        }
        startBoth()
        high.handle(.stop)
        high.handle(.start)
        net.run(for: 10, until: { self.isConnected(self.low, to: self.high.id) })
        XCTAssertEqual(low.machine.peers[high.id]?.prohibitedInterfaceName, "en0",
                       "the dial that only worked around en0 keeps the verdict")

        let flow = low.machine.audioRoute(for: high.id)!.flow
        low.handle(.flowBetterPathAvailable(flow))
        XCTAssertEqual(low.opened.last?.prohibited, nil, "a migration may try the avoided interface again")
        XCTAssertEqual(low.machine.peers[high.id]?.prohibitedInterfaceName, "en0")

        low.handle(.connect(high.id))
        XCTAssertNil(low.machine.peers[high.id]?.prohibitedInterfaceName)
    }

    func testPathChangeOnPrimaryIsReported() {
        connectPair()
        let flow = low.machine.audioRoute(for: high.id)!.flow
        low.handle(.flowPathChanged(flow, .wifiNetwork, interfaceName: "en0"))
        XCTAssertEqual(low.lastLinkState(for: high.id), .connected(path: .wifiNetwork, isResumption: true))
    }

    // MARK: - Single machine edge cases

    private func makeMachine(_ configure: (inout LinkStateMachine.Configuration) -> Void = { _ in }) -> LinkStateMachine {
        var config = LinkStateMachine.Configuration(localID: SimNetwork.lowID, localEpoch: 5, displayName: "A", appVersion: "1")
        configure(&config)
        return LinkStateMachine(configuration: config, rng: SplitMix64(seed: 3))
    }

    func testUnboundInboundFlowIsCancelledAfterTwoSeconds() {
        var machine = makeMachine()
        var now = MonotonicTime(seconds: 10)
        _ = machine.handle(.start, now: now)
        let flow = machine.makeFlowID()
        _ = machine.handle(.inboundFlow(flow), now: now)
        now += 1.95
        XCTAssertFalse(machine.handle(.tick, now: now).contains(.cancelFlow(flow)))
        now += 0.05
        XCTAssertTrue(machine.handle(.tick, now: now).contains(.cancelFlow(flow)))
        XCTAssertTrue(machine.unboundFlows.isEmpty)
    }

    func testUnboundInboundFlowsAreCapped() {
        var machine = makeMachine { $0.maxUnboundFlows = 8 }
        let now = MonotonicTime(seconds: 10)
        _ = machine.handle(.start, now: now)
        let flows = (0..<9).map { _ in machine.makeFlowID() }
        var effects: [LinkStateMachine.Effect] = []
        for flow in flows {
            effects += machine.handle(.inboundFlow(flow), now: now)
        }
        XCTAssertEqual(effects.filter { if case .cancelFlow = $0 { return true }; return false }, [.cancelFlow(flows[0])])
        XCTAssertEqual(machine.unboundFlows.count, 8)
    }

    func testLocalNetworkDeniedIsReportedOnceAndDoesNotTimeOut() {
        var machine = makeMachine()
        var now = MonotonicTime(seconds: 10)
        _ = machine.handle(.start, now: now)
        let peer = DiscoveryRecord(peerID: SimNetwork.highID, displayName: "B", keyTag: "")
        let effects = machine.handle(.peerDiscovered(peer), now: now)
        guard case .openFlow(let flow, _, _)? = effects.first(where: { if case .openFlow = $0 { return true }; return false }) else {
            return XCTFail("expected an immediate dial")
        }
        var all = machine.handle(.flowWaiting(flow, localNetworkDenied: true), now: now)
        all += machine.handle(.flowWaiting(flow, localNetworkDenied: true), now: now)
        XCTAssertEqual(all.filter { $0 == .event(.warning(.localNetworkDenied)) }.count, 1)
        for _ in 0..<200 {
            now += 0.05
            all += machine.handle(.tick, now: now)
        }
        XCTAssertFalse(all.contains(.cancelFlow(flow)))

        // The user allowed access: the flow becomes ready and the warning is withdrawn, once.
        all = machine.handle(.flowReady(flow), now: now)
        all += machine.handle(.flowReady(flow), now: now)
        XCTAssertEqual(all.filter { $0 == .event(.warningCleared(.localNetworkDenied)) }.count, 1)
    }

    func testUnknownFlowsAndInputsBeforeStartAreIgnored() {
        var machine = makeMachine()
        let now = MonotonicTime(seconds: 1)
        XCTAssertTrue(machine.handle(.tick, now: now).isEmpty)
        _ = machine.handle(.start, now: now)
        let bogus = FlowID(rawValue: 999)
        let datagram = NetDatagram(linkID: 1, senderEpoch: 2, payload: .heartbeat(.init(sequence: 1, sentMs: 0, echoSequence: 0, echoDelayMs: 0)))
        XCTAssertTrue(machine.handle(.datagram(datagram, on: bogus), now: now).isEmpty)
        XCTAssertTrue(machine.handle(.flowReady(bogus), now: now).isEmpty)
        XCTAssertTrue(machine.handle(.flowFailed(bogus, reason: "x"), now: now).isEmpty)
    }

    func testUnsealedDatagramsOnBoundLinkAreIgnored() {
        connectPair()
        let route = high.machine.audioRoute(for: low.id)!
        let forged = NetDatagram(linkID: route.linkID, senderEpoch: low.machine.configuration.localEpoch,
                                 payload: .bye(.userDisconnect), isSealed: false)
        high.handle(.datagram(forged, on: route.flow))
        XCTAssertTrue(bothConnected, "a plaintext bye on an established link must not tear it down")
    }

    func testStartAndStopEmitListenerAndBrowserEffects() {
        var machine = makeMachine()
        let now = MonotonicTime(seconds: 1)
        XCTAssertEqual(machine.handle(.start, now: now).filter { if case .log = $0 { return false }; return true },
                       [.startListener, .startBrowser])
        XCTAssertTrue(machine.handle(.start, now: now).isEmpty)
        XCTAssertEqual(machine.handle(.stop, now: now).filter { if case .log = $0 { return false }; return true },
                       [.stopBrowser, .stopListener])
        XCTAssertFalse(machine.isRunning)
    }
}

final class LinkStateMachineChaosTests: XCTestCase {
    /// Random loss, latency, partitions, restarts and user actions, then a healed network: every run
    /// must converge to exactly one shared link with no leaked flows.
    func testConvergesAfterRandomChaos() {
        for seed in UInt64(1)...40 {
            runChaos(seed: seed)
        }
    }

    private func runChaos(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let net = SimNetwork()
        let holdoff = [0, 0.75, 0.05][Int(rng.next() % 3)]
        var low = net.addNode(SimNetwork.lowID, seed: seed &* 3 &+ 1) { $0.dialHoldoff = holdoff }
        var high = net.addNode(SimNetwork.highID, seed: seed &* 5 &+ 2) { $0.dialHoldoff = holdoff }
        low.handle(.start)
        high.handle(.start)
        if rng.next() % 4 != 0 { low.handle(.peerDiscovered(high.record)) }
        high.handle(.peerDiscovered(low.record))

        var lossPercent: UInt64 = 0
        var blockedSender: PeerID?
        var chaosRNG = SplitMix64(seed: seed &+ 1000)
        net.dropFilter = { node, _ in node.id == blockedSender || chaosRNG.next() % 100 < lossPercent }

        for _ in 0..<30 {
            switch rng.next() % 10 {
            case 0:
                net.isPartitioned.toggle()
            case 1:
                lossPercent = rng.next() % 60
            case 2:
                net.latency = Double(rng.next() % 300) / 1000
            case 3:
                if rng.next() % 2 == 0 {
                    low = net.restart(SimNetwork.lowID, seed: rng.next())
                    low.handle(.start)
                    low.handle(.peerDiscovered(high.record))
                } else {
                    high = net.restart(SimNetwork.highID, seed: rng.next())
                    high.handle(.start)
                    high.handle(.peerDiscovered(low.record))
                }
            case 4:
                let flow = low.machine.audioRoute(for: high.id)?.flow
                if let flow { low.handle(.flowBetterPathAvailable(flow)) }
            case 5:
                high.handle(.setAppActive(rng.next() % 2 == 0))
            case 6:
                low.handle(.pathChanged)
            case 7:
                high.handle(.connect(low.id))
            case 8:
                // One-way reachability: only one direction delivers.
                blockedSender = blockedSender == nil ? (rng.next() % 2 == 0 ? low.id : high.id) : nil
            default:
                break
            }
            net.run(for: Double(rng.next() % 2000) / 1000)
        }

        net.isPartitioned = false
        lossPercent = 0
        blockedSender = nil
        net.latency = 0.005
        low.handle(.setAppActive(true))
        high.handle(.setAppActive(true))
        net.run(for: 6)

        let context = "seed \(seed)"
        guard let lowRoute = low.machine.audioRoute(for: high.id), let highRoute = high.machine.audioRoute(for: low.id) else {
            XCTFail("not converged: \(context)\n" + low.logs.suffix(15).joined(separator: "\n") + "\n--\n" + high.logs.suffix(15).joined(separator: "\n"))
            return
        }
        XCTAssertEqual(low.routes[lowRoute.flow]?.remoteFlow, highRoute.flow, context)
        XCTAssertEqual(lowRoute.linkID, highRoute.linkID, context)
        XCTAssertEqual(low.machine.links.count, 1, context)
        XCTAssertEqual(high.machine.links.count, 1, context)
        XCTAssertEqual(low.machine.flows.count, 1, "leaked flows: \(context)")
        XCTAssertEqual(high.machine.flows.count, 1, "leaked flows: \(context)")
        XCTAssertTrue(low.machine.unboundFlows.isEmpty, context)
        if case .connected? = low.machine.linkState(of: high.id) {} else { XCTFail("low state: \(context)") }
        if case .connected? = high.machine.linkState(of: low.id) {} else { XCTFail("high state: \(context)") }
        let opened = low.opened.count + high.opened.count
        net.run(for: 30)
        XCTAssertEqual(low.opened.count + high.opened.count, opened, "a healthy link must stay quiet: \(context)")
    }
}
