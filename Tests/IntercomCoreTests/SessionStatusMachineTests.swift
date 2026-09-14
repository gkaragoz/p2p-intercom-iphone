import Foundation
import XCTest
@testable import IntercomCore

final class SessionStatusMachineTests: XCTestCase {
    private let peer = PeerID(rawValue: "00000000-0000-0000-0000-000000000002")
    private let other = PeerID(rawValue: "00000000-0000-0000-0000-000000000003")
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Drives the machine with a synthetic clock; wall-clock dates follow the monotonic one.
    private struct Harness {
        var machine = SessionStatusMachine()
        var now = MonotonicTime(seconds: 100)
        let origin: Date

        var date: Date { origin.addingTimeInterval(now.seconds) }

        @discardableResult
        mutating func send(_ input: SessionStatusMachine.Input) -> [SessionStatusMachine.Effect] {
            machine.handle(input, now: now, date: date)
        }

        /// Advances the clock in one-second ticks, collecting every effect.
        @discardableResult
        mutating func advance(_ seconds: Int) -> [SessionStatusMachine.Effect] {
            var effects: [SessionStatusMachine.Effect] = []
            for _ in 0..<seconds {
                now += 1
                effects += send(.tick)
            }
            return effects
        }
    }

    private func makeRunning(appActive: Bool = true) -> Harness {
        var harness = Harness(origin: origin)
        harness.send(.started(appActive: appActive))
        harness.send(.audioStateChanged(.running))
        harness.send(.peerNamed(peer, "Zeynep"))
        return harness
    }

    private func cues(_ effects: [SessionStatusMachine.Effect]) -> [CueTone] {
        effects.compactMap { if case .playCue(let cue) = $0 { return cue } else { return nil } }
    }

    private func notices(_ effects: [SessionStatusMachine.Effect]) -> [SessionNotice] {
        effects.compactMap { if case .postNotice(let notice) = $0 { return notice } else { return nil } }
    }

    private func removals(_ effects: [SessionStatusMachine.Effect]) -> [SessionNotice.Slot] {
        effects.compactMap { if case .removeNotice(let slot) = $0 { return slot } else { return nil } }
    }

    func testIdleUntilStartedThenSearchingConnectingConnected() {
        var harness = Harness(origin: origin)
        XCTAssertEqual(harness.machine.status, .idle)
        harness.send(.linkStateChanged(peer, .connecting(attempt: 1)))
        XCTAssertEqual(harness.machine.status, .idle, "events before start are ignored")

        harness.send(.started(appActive: true))
        XCTAssertEqual(harness.machine.status, .searching)
        harness.send(.peerNamed(peer, "Zeynep"))
        harness.send(.linkStateChanged(peer, .discovered))
        XCTAssertEqual(harness.machine.status, .searching)
        harness.send(.linkStateChanged(peer, .connecting(attempt: 2)))
        XCTAssertEqual(harness.machine.status, .connecting(attempt: 2))

        let upDate = harness.date
        let effects = harness.send(.linkStateChanged(peer, .connected(path: .peerToPeerWiFi, isResumption: false)))
        XCTAssertEqual(cues(effects), [.connected])
        XCTAssertEqual(harness.machine.status, .connected(since: upDate, path: .peerToPeerWiFi))
        XCTAssertEqual(harness.machine.linkPath, .peerToPeerWiFi)
        XCTAssertEqual(harness.machine.lastPeerName, "Zeynep")

        harness.send(.stopped)
        XCTAssertEqual(harness.machine.status, .idle)
        XCTAssertNil(harness.machine.linkPath)
        XCTAssertEqual(harness.machine.lastPeerName, "Zeynep", "the last peer name survives a stop")
    }

    func testSuspectStaysConnectedAndPathChangesKeepSince() {
        var harness = makeRunning()
        let upDate = harness.date
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.advance(3)
        let suspect = harness.send(.linkStateChanged(peer, .suspect))
        XCTAssertTrue(cues(suspect).isEmpty)
        XCTAssertEqual(harness.machine.status, .connected(since: upDate, path: .wifiNetwork))

        let recovered = harness.send(.linkStateChanged(peer, .connected(path: .peerToPeerWiFi, isResumption: true)))
        XCTAssertTrue(cues(recovered).isEmpty, "a hiccup the link survives plays nothing")
        XCTAssertEqual(harness.machine.status, .connected(since: upDate, path: .peerToPeerWiFi))
    }

    func testUnexpectedLossReconnectsWithCuesAndNoNoticeInForeground() {
        var harness = makeRunning()
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.advance(10)

        let lostDate = harness.date
        let lost = harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        XCTAssertEqual(cues(lost), [.lost])
        XCTAssertEqual(harness.machine.status, .reconnecting(since: lostDate, attempt: 0))
        XCTAssertNil(harness.machine.linkPath)
        XCTAssertEqual(harness.machine.lastPeerName, "Zeynep")

        harness.send(.linkStateChanged(peer, .connecting(attempt: 3)))
        XCTAssertEqual(harness.machine.status, .reconnecting(since: lostDate, attempt: 3))
        XCTAssertTrue(notices(harness.advance(20)).isEmpty, "no notifications while the app is active")

        let back = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: true)))
        XCTAssertEqual(cues(back), [.reconnected])
        XCTAssertTrue(notices(back).isEmpty)
        XCTAssertEqual(harness.machine.status, .connected(since: harness.date, path: .wifiNetwork))
    }

    func testBackgroundLossNoticeAfterGraceReplacedByReconnected() {
        var harness = makeRunning(appActive: false)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.linkStateChanged(peer, .disconnected(.timeout)))

        XCTAssertTrue(notices(harness.advance(2)).isEmpty, "inside the grace period")
        XCTAssertEqual(notices(harness.advance(1)), [.connectionLost(peerName: "Zeynep")])
        XCTAssertTrue(notices(harness.advance(10)).isEmpty, "posted once")

        let back = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        XCTAssertEqual(notices(back), [.reconnected(peerName: "Zeynep")])
        XCTAssertEqual(SessionNotice.reconnected(peerName: nil).slot, SessionNotice.connectionLost(peerName: nil).slot,
                       "the reconnected notice replaces the lost one")
        XCTAssertEqual(cues(back), [.reconnected])
    }

    func testQuickBackgroundReconnectPostsNothing() {
        var harness = makeRunning(appActive: false)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        var effects = harness.advance(2)
        effects += harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: true)))
        effects += harness.advance(10)
        XCTAssertTrue(notices(effects).isEmpty)
        XCTAssertEqual(cues(effects), [.reconnected])
    }

    func testBecomingActiveRemovesNoticesAndDoesNotRepeatThem() {
        var harness = makeRunning(appActive: false)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        XCTAssertEqual(notices(harness.advance(4)).count, 1)

        let active = harness.send(.appActiveChanged(true))
        XCTAssertEqual(Set(removals(active)), [.link, .audio])
        harness.send(.appActiveChanged(false))
        XCTAssertTrue(notices(harness.advance(10)).isEmpty, "the user saw this loss in the app")
        let back = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: true)))
        XCTAssertTrue(notices(back).isEmpty, "nothing to replace")
    }

    func testLossSeenInTheAppIsNotAnnouncedWhenTheAppLeaves() {
        var harness = makeRunning(appActive: true)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        var effects = harness.advance(10)
        effects += harness.send(.appActiveChanged(false))
        effects += harness.advance(10)
        XCTAssertTrue(notices(effects).isEmpty, "the user watched this loss in the app")
        XCTAssertEqual(harness.machine.status, .reconnecting(since: harness.origin.addingTimeInterval(100), attempt: 0))

        let back = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: true)))
        XCTAssertTrue(notices(back).isEmpty, "nothing to replace")
        XCTAssertEqual(cues(back), [.reconnected])

        // A new loss while in the background is news again.
        harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        XCTAssertEqual(notices(harness.advance(3)), [.connectionLost(peerName: "Zeynep")])
    }

    func testDeliberateEndingsDoNotReconnectOrNotify() {
        for reason: DisconnectReason in [.userRequested, .remoteBye(.userDisconnect)] {
            var harness = makeRunning(appActive: false)
            harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
            let ended = harness.send(.linkStateChanged(peer, .disconnected(reason)))
            // Nothing redials after a Disconnect: the status must not claim to be searching.
            XCTAssertEqual(harness.machine.status, .disconnected(byPeer: reason != .userRequested), "\(reason)")
            XCTAssertEqual(cues(ended), reason == .userRequested ? [] : [.lost], "\(reason)")
            XCTAssertTrue(notices(harness.advance(10)).isEmpty, "\(reason)")
            XCTAssertEqual(harness.machine.status, .disconnected(byPeer: reason != .userRequested), "\(reason)")

            // Tapping Connect (here or there) dials again.
            harness.send(.linkStateChanged(peer, .connecting(attempt: 1)))
            XCTAssertEqual(harness.machine.status, .connecting(attempt: 1), "\(reason)")
            let again = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
            XCTAssertEqual(cues(again), [.connected], "\(reason)")
        }

        // Refused again after Connect on the side that did not disconnect: still disconnected by the peer.
        var refused = makeRunning()
        refused.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        refused.send(.linkStateChanged(peer, .disconnected(.remoteBye(.userDisconnect))))
        refused.send(.linkStateChanged(peer, .connecting(attempt: 1)))
        refused.send(.linkStateChanged(peer, .disconnected(.remoteBye(.userDisconnect))))
        XCTAssertEqual(refused.machine.status, .disconnected(byPeer: true))

        // Another peer that can still be dialled automatically keeps it searching.
        var withOther = makeRunning()
        withOther.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        withOther.send(.linkStateChanged(other, .discovered))
        withOther.send(.linkStateChanged(peer, .disconnected(.userRequested)))
        XCTAssertEqual(withOther.machine.status, .searching)

        // Mismatches are explained by their warning, not by "disconnected".
        var mismatch = makeRunning()
        mismatch.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        mismatch.send(.linkStateChanged(peer, .disconnected(.remoteBye(.incompatibleVersion))))
        XCTAssertEqual(mismatch.machine.status, .searching)

        var restarted = makeRunning(appActive: false)
        restarted.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        restarted.send(.transportRestarted)
        XCTAssertEqual(restarted.machine.status, .searching)
        XCTAssertTrue(notices(restarted.advance(10)).isEmpty)
        let again = restarted.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        XCTAssertEqual(cues(again), [.connected])
    }

    func testDeliberateEndingLearnedWhileReconnectingEndsTheEpisode() {
        // Background: the loss notice is posted, then the peer's Disconnect arrives late.
        var harness = makeRunning(appActive: false)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.linkStateChanged(peer, .disconnected(.transportError("dropped"))))
        harness.send(.linkStateChanged(peer, .connecting(attempt: 2)))
        XCTAssertEqual(notices(harness.advance(4)), [.connectionLost(peerName: "Zeynep")])

        let ended = harness.send(.linkStateChanged(peer, .disconnected(.remoteBye(.userDisconnect))))
        XCTAssertEqual(removals(ended), [.link], "the lost notice goes away")
        XCTAssertTrue(cues(ended).isEmpty, "the lost cue already played")
        XCTAssertEqual(harness.machine.status, .disconnected(byPeer: true))
        XCTAssertTrue(notices(harness.advance(10)).isEmpty)
        let again = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        XCTAssertEqual(cues(again), [.connected], "a new episode, not a reconnect")
        XCTAssertTrue(notices(again).isEmpty)

        // Foreground, no notice: only the status changes. Another peer's ending leaves the episode alone.
        var active = makeRunning()
        active.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        active.send(.linkStateChanged(peer, .disconnected(.timeout)))
        active.send(.linkStateChanged(other, .disconnected(.userRequested)))
        if case .reconnecting = active.machine.status {} else {
            XCTFail("expected reconnecting, got \(active.machine.status)")
        }
        let quiet = active.send(.linkStateChanged(peer, .disconnected(.userRequested)))
        XCTAssertTrue(removals(quiet).isEmpty)
        XCTAssertEqual(active.machine.status, .disconnected(byPeer: false))

        // A transport error while redialling is not deliberate.
        var redialling = makeRunning()
        redialling.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        redialling.send(.linkStateChanged(peer, .disconnected(.timeout)))
        redialling.send(.linkStateChanged(peer, .disconnected(.transportError("handshake failed"))))
        if case .reconnecting = redialling.machine.status {} else {
            XCTFail("expected reconnecting, got \(redialling.machine.status)")
        }
    }

    func testOnlyTheLastLinkDroppingCountsAsLoss() {
        var harness = makeRunning()
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        let second = harness.send(.linkStateChanged(other, .connected(path: .peerToPeerWiFi, isResumption: false)))
        XCTAssertTrue(cues(second).isEmpty, "already connected")
        XCTAssertEqual(harness.machine.linkPath, .wifiNetwork, "the oldest link is the primary")

        let firstDown = harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        XCTAssertTrue(cues(firstDown).isEmpty)
        XCTAssertEqual(harness.machine.linkPath, .peerToPeerWiFi)
        XCTAssertEqual(cues(harness.send(.linkStateChanged(other, .disconnected(.timeout)))), [.lost])
        if case .reconnecting = harness.machine.status {} else {
            XCTFail("expected reconnecting, got \(harness.machine.status)")
        }
    }

    func testAudioInterruptionDominatesAndNotifiesInBackground() {
        var harness = makeRunning(appActive: false)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))

        harness.send(.audioStateChanged(.interrupted))
        XCTAssertEqual(harness.machine.status, .audioInterrupted(needsForeground: false))
        XCTAssertEqual(harness.machine.linkPath, .wifiNetwork, "the link itself is still up")
        XCTAssertTrue(notices(harness.advance(4)).isEmpty, "an interruption may end on its own")
        XCTAssertEqual(notices(harness.advance(1)), [.audioPaused])

        harness.send(.audioStateChanged(.recovering(attempt: 1)))
        XCTAssertTrue(notices(harness.advance(10)).isEmpty, "posted once")
        let running = harness.send(.audioStateChanged(.running))
        XCTAssertEqual(removals(running), [.audio])
        XCTAssertEqual(harness.machine.status, .connected(since: harness.origin.addingTimeInterval(100), path: .wifiNetwork))
    }

    func testNeedsForegroundNotifiesAtOnce() {
        var harness = makeRunning(appActive: false)
        harness.send(.audioStateChanged(.interrupted))
        let effects = harness.send(.audioStateChanged(.needsForeground))
        XCTAssertEqual(notices(effects), [.audioPaused])
        XCTAssertEqual(harness.machine.status, .audioInterrupted(needsForeground: true))

        let active = harness.send(.appActiveChanged(true))
        XCTAssertTrue(removals(active).contains(.audio))
        harness.send(.audioStateChanged(.recovering(attempt: 1)))
        harness.send(.audioStateChanged(.running))
        XCTAssertEqual(harness.machine.status, .searching)
    }

    func testForegroundInterruptionDoesNotNotify() {
        var harness = makeRunning(appActive: true)
        harness.send(.audioStateChanged(.interrupted))
        XCTAssertTrue(notices(harness.advance(20)).isEmpty)
    }

    func testWarningsClearOnConnectAndWifiHintNeedsDelay() {
        var harness = makeRunning()
        harness.send(.transportWarning(.localNetworkDenied))
        XCTAssertEqual(harness.machine.warning, .localNetworkDenied)
        harness.send(.transportWarning(.listenerFailed("x")))
        XCTAssertEqual(harness.machine.warning, .localNetworkDenied, "transient failures are not warnings")
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        XCTAssertNil(harness.machine.warning)

        harness.send(.linkStateChanged(peer, .disconnected(.remoteBye(.authenticationFailed))))
        XCTAssertEqual(harness.machine.warning, .pairingMismatch(peer))
        XCTAssertEqual(harness.machine.status, .searching, "a pairing mismatch does not reconnect")

        harness.send(.stopped)
        XCTAssertNil(harness.machine.warning)

        harness.send(.wifiAvailabilityChanged(false))
        XCTAssertNil(harness.machine.warning, "not running")
        harness.send(.started(appActive: true))
        harness.advance(4)
        XCTAssertNil(harness.machine.warning)
        harness.advance(1)
        XCTAssertEqual(harness.machine.warning, .wifiOff)
        harness.send(.transportWarning(.incompatibleVersion(other)))
        XCTAssertEqual(harness.machine.warning, .versionMismatch(other), "explicit warnings win over the hint")
        harness.send(.linkStateChanged(peer, .connected(path: .peerToPeerWiFi, isResumption: false)))
        XCTAssertNil(harness.machine.warning, "a link proves the radio works")
        harness.send(.linkStateChanged(peer, .disconnected(.userRequested)))
        XCTAssertNil(harness.machine.warning, "the hint waits again")
        harness.advance(5)
        XCTAssertEqual(harness.machine.warning, .wifiOff)
        harness.send(.wifiAvailabilityChanged(true))
        XCTAssertNil(harness.machine.warning)
    }

    func testLocalNetworkWarningIsWithdrawnWhenAccessWorks() {
        var harness = makeRunning()
        harness.send(.wifiAvailabilityChanged(false))
        harness.send(.transportWarning(.localNetworkDenied))
        harness.advance(6)
        XCTAssertEqual(harness.machine.warning, .localNetworkDenied)
        harness.send(.transportWarningCleared(.localNetworkDenied))
        XCTAssertEqual(harness.machine.warning, .wifiOff, "the hint the denied warning was hiding shows again")

        harness.send(.wifiAvailabilityChanged(true))
        harness.send(.transportWarning(.pairingMismatch(other)))
        harness.send(.transportWarningCleared(.localNetworkDenied))
        XCTAssertEqual(harness.machine.warning, .pairingMismatch(other), "a clear only withdraws that warning")
    }

    func testStopRemovesNoticesAndForgetsTheEpisode() {
        var harness = makeRunning(appActive: false)
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.linkStateChanged(peer, .disconnected(.timeout)))
        harness.advance(4)
        let stopped = harness.send(.stopped)
        XCTAssertEqual(Set(removals(stopped)), [.link, .audio])
        XCTAssertTrue(harness.send(.stopped).isEmpty, "stop is idempotent")

        harness.send(.started(appActive: false))
        harness.send(.audioStateChanged(.running))
        XCTAssertEqual(harness.machine.status, .searching)
        XCTAssertTrue(notices(harness.advance(10)).isEmpty)
        let connected = harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        XCTAssertEqual(cues(connected), [.connected], "a new run starts a new episode")
    }

    func testRenameOfLastPeerUpdatesName() {
        var harness = makeRunning()
        harness.send(.linkStateChanged(peer, .connected(path: .wifiNetwork, isResumption: false)))
        harness.send(.peerNamed(other, "Gökhan"))
        XCTAssertEqual(harness.machine.lastPeerName, "Zeynep")
        harness.send(.peerNamed(peer, "Zeynep's iPhone"))
        XCTAssertEqual(harness.machine.lastPeerName, "Zeynep's iPhone")
    }
}
