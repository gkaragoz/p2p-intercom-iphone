import XCTest
@testable import IntercomCore

final class ReplayWindowTests: XCTestCase {
    func testAcceptsNewRejectsDuplicates() {
        var window = ReplayWindow()
        XCTAssertTrue(window.insert(10))
        XCTAssertFalse(window.insert(10))
        XCTAssertTrue(window.insert(11))
        XCTAssertTrue(window.insert(9), "moderate reordering is fine")
        XCTAssertFalse(window.insert(9))
        XCTAssertEqual(window.highest, 11)
    }

    func testWindowEdgeAndTooOld() {
        var window = ReplayWindow()
        window.insert(100)
        XCTAssertTrue(window.wouldAccept(100 - 63))
        XCTAssertFalse(window.wouldAccept(100 - 64), "older than the window counts as seen")
        XCTAssertTrue(window.insert(37))
        XCTAssertFalse(window.insert(37))
    }

    func testLargeJumpClearsHistory() {
        var window = ReplayWindow()
        for counter in 0..<64 { window.insert(UInt64(counter)) }
        XCTAssertTrue(window.insert(1_000))
        XCTAssertTrue(window.wouldAccept(999))
        XCTAssertFalse(window.wouldAccept(10))
        XCTAssertFalse(window.insert(1_000))
    }

    func testWouldAcceptDoesNotRecord() {
        var window = ReplayWindow()
        XCTAssertTrue(window.wouldAccept(5))
        XCTAssertTrue(window.wouldAccept(5))
        XCTAssertTrue(window.insert(5))
        XCTAssertFalse(window.wouldAccept(5))
        window.reset()
        XCTAssertTrue(window.wouldAccept(5))
        XCTAssertNil(window.highest)
    }

    func testMatchesReferenceModel() {
        var rng = SplitMix64(seed: 5)
        var window = ReplayWindow()
        var seen = Set<UInt64>()
        var highest: UInt64 = 0
        for _ in 0..<5_000 {
            let counter = highest + 5 >= 40 ? highest + 5 - rng.next() % 40 : rng.next() % 45
            let expected = !seen.contains(counter) && (seen.isEmpty || counter + 64 > highest)
            XCTAssertEqual(window.insert(counter), expected, "counter \(counter) highest \(highest)")
            if expected {
                seen.insert(counter)
                highest = max(highest, counter)
            }
        }
    }
}

final class ReconnectBackoffTests: XCTestCase {
    func testNetworkScheduleWithoutJitter() {
        var backoff = ReconnectBackoff(schedule: .init(delays: [0, 0.25, 0.5, 1, 2], jitter: 0, stableLinkDuration: 5))
        var rng = SplitMix64(seed: 1)
        let delays = (0..<8).map { _ in backoff.nextDelay(using: &rng) }
        XCTAssertEqual(delays, [0, 0.25, 0.5, 1, 2, 2, 2, 2])
    }

    func testJitterStaysWithinTwentyPercentAndNeverStops() {
        var backoff = ReconnectBackoff(schedule: .network)
        var rng = SplitMix64(seed: 42)
        XCTAssertEqual(backoff.nextDelay(using: &rng), 0, "the first retry after a stable link is immediate")
        var sawBelow = false
        var sawAbove = false
        for attempt in 1..<10_000 {
            let nominal = [0, 0.25, 0.5, 1, 2][min(attempt, 4)]
            let delay = backoff.nextDelay(using: &rng)
            XCTAssertGreaterThanOrEqual(delay, nominal * 0.8)
            XCTAssertLessThanOrEqual(delay, nominal * 1.2)
            XCTAssertLessThanOrEqual(delay, backoff.maximumDelay)
            if attempt > 4 {
                sawBelow = sawBelow || delay < 2
                sawAbove = sawAbove || delay > 2
            }
        }
        XCTAssertTrue(sawBelow && sawAbove, "jitter must spread both ways")
        XCTAssertEqual(backoff.maximumDelay, 2.4, accuracy: 1e-9)
    }

    func testResetOnlyAfterStableLink() {
        var backoff = ReconnectBackoff(schedule: .init(delays: [0, 1, 2], jitter: 0, stableLinkDuration: 5))
        var rng = SplitMix64(seed: 1)
        _ = backoff.nextDelay(using: &rng)
        _ = backoff.nextDelay(using: &rng)
        backoff.linkWentDown(upFor: 4.9)
        XCTAssertEqual(backoff.nominalNextDelay, 2, "a flapping link keeps escalating")
        backoff.linkWentDown(upFor: 5)
        XCTAssertEqual(backoff.nominalNextDelay, 0)
        _ = backoff.nextDelay(using: &rng)
        backoff.reset()
        XCTAssertEqual(backoff.failures, 0)
    }

    func testMultipeerScheduleAndDegenerateInput() {
        var mc = ReconnectBackoff(schedule: .multipeer)
        var rng = SplitMix64(seed: 9)
        let first = mc.nextDelay(using: &rng)
        XCTAssertTrue((0.8...1.2).contains(first))
        var empty = ReconnectBackoff(schedule: .init(delays: [], jitter: 5, stableLinkDuration: 1))
        XCTAssertEqual(empty.nextDelay(using: &rng), 0)
        XCTAssertEqual(empty.schedule.jitter, 1)
    }

    func testSeededGeneratorIsDeterministic() {
        var a = SplitMix64(seed: 123)
        var b = SplitMix64(seed: 123)
        XCTAssertEqual((0..<10).map { _ in a.next() }, (0..<10).map { _ in b.next() })
        var c = SplitMix64(seed: 124)
        XCTAssertNotEqual(a.next(), c.next())
    }
}

final class LivenessMonitorTests: XCTestCase {
    private let t0 = MonotonicTime(seconds: 50)

    func testForegroundThresholds() {
        let monitor = LivenessMonitor(now: t0)
        XCTAssertEqual(monitor.suspectAfter, 0.6, accuracy: 1e-9)
        XCTAssertEqual(monitor.deadAfter, 2.0, accuracy: 1e-9)
        XCTAssertEqual(monitor.health(at: t0 + 0.59), .alive)
        XCTAssertEqual(monitor.health(at: t0 + 0.61), .suspect)
        XCTAssertEqual(monitor.health(at: t0 + 1.99), .suspect)
        XCTAssertEqual(monitor.health(at: t0 + 2.0), .dead)
    }

    func testBackgroundOnEitherSideRelaxesThresholds() {
        var monitor = LivenessMonitor(now: t0)
        monitor.isLocalInBackground = true
        XCTAssertEqual(monitor.localHeartbeatInterval, 0.5)
        XCTAssertEqual(monitor.suspectAfter, 1.5, accuracy: 1e-9)
        XCTAssertEqual(monitor.deadAfter, 3.0, accuracy: 1e-9)
        monitor.isLocalInBackground = false
        monitor.isRemoteInBackground = true
        XCTAssertEqual(monitor.localHeartbeatInterval, 0.2, "our own cadence follows our own state")
        XCTAssertEqual(monitor.deadAfter, 3.0, accuracy: 1e-9)
    }

    func testHeartbeatsKeepItAliveAndLossIsDeadWithinTwoSeconds() {
        var monitor = LivenessMonitor(now: t0)
        var now = t0
        for _ in 0..<50 {
            now += 0.2
            monitor.recordReceive(at: now)
            XCTAssertEqual(monitor.health(at: now + 0.1), .alive)
        }
        let lastHeard = now
        while monitor.health(at: now) != .dead {
            now += 0.05
        }
        XCTAssertLessThanOrEqual(now - lastHeard, 2.0 + 1e-9)
    }

    func testReceiveNeverMovesBackwards() {
        var monitor = LivenessMonitor(now: t0 + 1)
        monitor.recordReceive(at: t0)
        XCTAssertEqual(monitor.lastReceivedAt, t0 + 1)
    }

    func testContinuousSendErrorsAreDeadAfterThreeHundredMilliseconds() {
        var monitor = LivenessMonitor(now: t0)
        // Nothing arrives any more: the interface is gone.
        let silent = t0 + monitor.suspectAfter
        monitor.recordSendError(at: silent)
        XCTAssertEqual(monitor.health(at: silent + 0.5), .suspect, "a single failure is not yet persistent")
        monitor.recordSendError(at: silent + 0.2)
        XCTAssertFalse(monitor.hasPersistentSendErrors(at: silent + 0.2))
        monitor.recordSendError(at: silent + 0.3)
        XCTAssertTrue(monitor.hasPersistentSendErrors(at: silent + 0.3))
        XCTAssertEqual(monitor.health(at: silent + 0.3), .dead)
        monitor.recordSendSuccess(at: silent + 0.35)
        monitor.recordReceive(at: silent + 0.35)
        XCTAssertEqual(monitor.health(at: silent + 0.4), .alive)

        // Two failures are never a run, however far apart.
        monitor.recordSendError(at: silent + 1)
        monitor.recordSendError(at: silent + 2)
        XCTAssertFalse(monitor.hasPersistentSendErrors(at: silent + 2))
    }

    func testSendErrorBurstWhileThePeerIsStillHeardIsNotDeadYet() {
        var background = LivenessMonitor(now: t0)
        background.isLocalInBackground = true
        // Heartbeats both ways every 0.5 s; ours fail, the peer's keep arriving.
        var now = t0
        for beat in 1...3 {
            now = t0 + 0.5 * Double(beat)
            background.recordReceive(at: now)
            background.recordSendError(at: now)
            XCTAssertEqual(background.health(at: now + 0.05), .alive, "failures spanning \(0.5 * Double(beat - 1)) s")
        }
        now += 0.5
        background.recordReceive(at: now)
        background.recordSendError(at: now)
        XCTAssertEqual(background.health(at: now), .dead, "the run spans the 1.5 s suspect threshold")

        var foreground = LivenessMonitor(now: t0)
        for beat in 1...3 {
            foreground.recordReceive(at: t0 + 0.2 * Double(beat))
            foreground.recordSendError(at: t0 + 0.2 * Double(beat))
        }
        XCTAssertEqual(foreground.health(at: t0 + 0.65), .alive)
        foreground.recordSendError(at: t0 + 0.8)
        XCTAssertEqual(foreground.health(at: t0 + 0.8), .dead, "one-way failure still dies within ~0.6 s")
    }

    func testMultipeerConfiguration() {
        let monitor = LivenessMonitor(configuration: .multipeer, now: t0)
        XCTAssertEqual(monitor.deadAfter, 4, accuracy: 1e-9)
        XCTAssertEqual(monitor.health(at: t0 + 3.9), .suspect)

        var failing = LivenessMonitor(configuration: .multipeer, now: t0)
        failing.recordSendError(at: t0 + 1)
        failing.recordSendError(at: t0 + 2)
        XCTAssertEqual(failing.health(at: t0 + 2), .dead, "two failed pings a second apart once pongs stopped")
    }
}

final class LinkArbiterTests: XCTestCase {
    private let low = PeerID(rawValue: "00000000-0000-0000-0000-00000000000a")
    private let high = PeerID(rawValue: "00000000-0000-0000-0000-00000000000b")

    func testLowerIDDialsImmediatelyHigherHoldsOff() {
        XCTAssertTrue(LinkArbiter.isPreferredDialer(local: low, remote: high))
        XCTAssertFalse(LinkArbiter.isPreferredDialer(local: high, remote: low))
        XCTAssertEqual(LinkArbiter.dialDelay(local: low, remote: high), 0)
        XCTAssertEqual(LinkArbiter.dialDelay(local: high, remote: low), 0.75)
    }

    func testUUIDStringOrderMatchesByteOrder() {
        let uuids = (0..<200).map { _ in UUID() }
        let byString = uuids.map { PeerID(installID: $0) }.sorted()
        let byBytes = uuids.sorted { a, b in
            withUnsafeBytes(of: a.uuid) { ra in withUnsafeBytes(of: b.uuid) { rb in ra.lexicographicallyPrecedes(rb) } }
        }.map { PeerID(installID: $0) }
        XCTAssertEqual(byString, byBytes)
    }

    func testPreferenceIsSymmetricAndDeterministic() {
        let byLow = LinkArbiter.Candidate(dialer: low, dialSequence: 1)
        let byHighNewer = LinkArbiter.Candidate(dialer: high, dialSequence: 9)
        for (local, remote) in [(low, high), (high, low)] {
            XCTAssertTrue(LinkArbiter.isPreferred(byLow, over: byHighNewer, local: local, remote: remote))
            XCTAssertFalse(LinkArbiter.isPreferred(byHighNewer, over: byLow, local: local, remote: remote))
        }
        let older = LinkArbiter.Candidate(dialer: high, dialSequence: 3)
        XCTAssertTrue(LinkArbiter.isPreferred(byHighNewer, over: older, local: low, remote: high), "same dialer: newest wins")
        XCTAssertFalse(LinkArbiter.isPreferred(older, over: byHighNewer, local: high, remote: low))
    }

    func testInboundHelloDecisions() {
        typealias Link = LinkArbiter.ExistingLink
        // No link yet.
        XCTAssertEqual(LinkArbiter.decideInboundHello(local: low, remote: high, helloEpoch: 1, primary: nil),
                       .accept(supersedesPrimary: false))
        // Peer restarted.
        XCTAssertEqual(LinkArbiter.decideInboundHello(local: low, remote: high, helloEpoch: 2,
                                                      primary: Link(dialer: low, remoteEpoch: 1, health: .alive)),
                       .acceptReplacingRestartedPeer)
        // Same dialer again: migration, newest wins.
        XCTAssertEqual(LinkArbiter.decideInboundHello(local: low, remote: high, helloEpoch: 1,
                                                      primary: Link(dialer: high, remoteEpoch: 1, health: .alive)),
                       .accept(supersedesPrimary: false))
        // Our healthy link dialled by the lower ID wins against the higher ID's dial.
        XCTAssertEqual(LinkArbiter.decideInboundHello(local: low, remote: high, helloEpoch: 1,
                                                      primary: Link(dialer: low, remoteEpoch: 1, health: .alive)),
                       .rejectDuplicate)
        // …but not when it is suspect or dead: the peer gave up on it.
        for health in [LivenessMonitor.Health.suspect, .dead] {
            XCTAssertEqual(LinkArbiter.decideInboundHello(local: low, remote: high, helloEpoch: 1,
                                                          primary: Link(dialer: low, remoteEpoch: 1, health: health)),
                           .accept(supersedesPrimary: true))
        }
        // The higher ID's healthy link loses to the lower ID's dial.
        XCTAssertEqual(LinkArbiter.decideInboundHello(local: high, remote: low, helloEpoch: 1,
                                                      primary: Link(dialer: high, remoteEpoch: 1, health: .alive)),
                       .accept(supersedesPrimary: false))
    }

    func testAbandonOwnDialOnlyWhenPeerWouldWin() {
        XCTAssertTrue(LinkArbiter.shouldAbandonOwnDialOnInboundHello(local: high, remote: low))
        XCTAssertFalse(LinkArbiter.shouldAbandonOwnDialOnInboundHello(local: low, remote: high))
    }
}

final class ControlRetransmitterTests: XCTestCase {
    private let t0 = MonotonicTime(seconds: 7)

    func testRetriesEveryIntervalUntilAcknowledged() {
        var retransmitter = ControlRetransmitter<String>(retryInterval: 0.25)
        let sequence = retransmitter.enqueue("hello")
        XCTAssertEqual(retransmitter.due(at: t0).map { $0.sequence }, [sequence])
        XCTAssertTrue(retransmitter.due(at: t0 + 0.2).isEmpty)
        XCTAssertEqual(retransmitter.due(at: t0 + 0.25).map { $0.message }, ["hello"])
        XCTAssertTrue(retransmitter.acknowledge(sequence))
        XCTAssertFalse(retransmitter.acknowledge(sequence))
        XCTAssertTrue(retransmitter.due(at: t0 + 1).isEmpty)
    }

    func testSequencesIncreaseAndOrderIsPreserved() {
        var retransmitter = ControlRetransmitter<Int>()
        let a = retransmitter.enqueue(1)
        let b = retransmitter.enqueue(2)
        XCTAssertEqual(b, a + 1)
        XCTAssertEqual(retransmitter.due(at: t0).map { $0.message }, [1, 2])
        retransmitter.acknowledge(a)
        retransmitter.expediteAll()
        XCTAssertEqual(retransmitter.due(at: t0 + 0.01).map { $0.message }, [2])
    }

    func testQueueIsBounded() {
        var retransmitter = ControlRetransmitter<Int>(maxPending: 3)
        for value in 0..<5 { retransmitter.enqueue(value) }
        XCTAssertEqual(retransmitter.pending.map { $0.message }, [2, 3, 4])
        XCTAssertEqual(retransmitter.droppedCount, 2)
        retransmitter.removeAll()
        XCTAssertTrue(retransmitter.pending.isEmpty)
    }

    func testDeduplicatorDeliversOnce() {
        var dedupe = ControlDeduplicator()
        XCTAssertTrue(dedupe.shouldDeliver(1))
        XCTAssertFalse(dedupe.shouldDeliver(1))
        XCTAssertTrue(dedupe.shouldDeliver(3))
        XCTAssertTrue(dedupe.shouldDeliver(2))
        dedupe.reset()
        XCTAssertTrue(dedupe.shouldDeliver(1))
    }
}

final class DiscoveryRecordTests: XCTestCase {
    private let uuid = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    func testRoundTripsThroughTXTDictionary() {
        let record = DiscoveryRecord(peerID: PeerID(installID: uuid), displayName: "  Gökhan  ", keyTag: "DEADBEEF", capabilities: 0x1F)
        let txt = record.txtRecord
        XCTAssertEqual(txt["v"], "2")
        XCTAssertEqual(txt["id"], "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")
        XCTAssertEqual(txt["n"], "Gökhan")
        XCTAssertEqual(txt["k"], "deadbeef")
        XCTAssertEqual(txt["c"], "1f")
        XCTAssertEqual(DiscoveryRecord(txtRecord: txt), record)
        XCTAssertTrue(txt.allSatisfy { ($0.key + "=" + $0.value).utf8.count <= 255 })
    }

    func testRequiresVersionAndUUIDButToleratesMissingOptionals() {
        XCTAssertNil(DiscoveryRecord(txtRecord: ["id": uuid.uuidString]))
        XCTAssertNil(DiscoveryRecord(txtRecord: ["v": "2"]))
        XCTAssertNil(DiscoveryRecord(txtRecord: ["v": "x", "id": uuid.uuidString]))
        XCTAssertNil(DiscoveryRecord(txtRecord: ["v": "2", "id": "not-a-uuid"]))
        let minimal = DiscoveryRecord(txtRecord: ["v": "2", "id": uuid.uuidString, "k": "zz", "c": "??"])
        XCTAssertEqual(minimal?.displayName, DisplayName.fallback)
        XCTAssertEqual(minimal?.keyTag, "")
        XCTAssertEqual(minimal?.capabilities, 0)
        XCTAssertNil(minimal?.txtRecord["k"])
    }

    func testCompatibility() {
        let record = DiscoveryRecord(peerID: PeerID(installID: uuid), displayName: "A", keyTag: "0123abcd")
        XCTAssertEqual(record.compatibility(localKeyTag: "0123ABCD"), .compatible)
        XCTAssertEqual(record.compatibility(localKeyTag: "ffffffff"), .pairingMismatch)
        XCTAssertEqual(record.compatibility(localKeyTag: ""), .pairingMismatch)
        XCTAssertEqual(record.compatibility(localProtocolVersion: 3, localKeyTag: "0123abcd"), .incompatibleVersion)
        XCTAssertEqual(record.advert(localKeyTag: "0123abcd").id, record.peerID)
    }

    func testLongNamesAreTruncatedToBonjourLimit() {
        let record = DiscoveryRecord(peerID: PeerID(installID: uuid), displayName: String(repeating: "ş", count: 80), keyTag: "")
        XCTAssertLessThanOrEqual(record.displayName.utf8.count, 63)
    }

    func testServiceTypeValidation() {
        XCTAssertTrue(ServiceTypeValidator.isValid(IntercomProtocol.Network.serviceType))
        XCTAssertTrue(ServiceTypeValidator.isValid("_p2p-intercom._tcp"))
        XCTAssertFalse(ServiceTypeValidator.isValid("_intercom-network._udp"), "more than 15 characters")
        XCTAssertFalse(ServiceTypeValidator.isValid("_-intercom._udp"))
        XCTAssertFalse(ServiceTypeValidator.isValid("_inter--com._udp"))
        XCTAssertFalse(ServiceTypeValidator.isValid("_1234._udp"), "needs a letter")
        XCTAssertFalse(ServiceTypeValidator.isValid("intercom._udp"))
        XCTAssertFalse(ServiceTypeValidator.isValid("_intercom._sctp"))
        XCTAssertFalse(ServiceTypeValidator.isValid("_inter_com._udp"))
    }
}

final class LinkTypesTests: XCTestCase {
    func testPathClassification() {
        XCTAssertEqual(LinkPathClassifier.classify(interfaceName: "awdl0", isWiFi: false, isWired: false), .peerToPeerWiFi)
        XCTAssertEqual(LinkPathClassifier.classify(interfaceName: "llw0", isWiFi: true, isWired: false), .peerToPeerWiFi)
        XCTAssertEqual(LinkPathClassifier.classify(interfaceName: "en0", isWiFi: true, isWired: false), .wifiNetwork)
        XCTAssertEqual(LinkPathClassifier.classify(interfaceName: "en5", isWiFi: false, isWired: true), .wired)
        XCTAssertEqual(LinkPathClassifier.classify(interfaceName: "utun3", isWiFi: false, isWired: false), .other)
        XCTAssertEqual(LinkPathClassifier.classify(interfaceName: nil, isWiFi: false, isWired: false), .unknown)
    }

    func testPeerIDFromInstallID() {
        let uuid = UUID()
        let id = PeerID(installID: uuid)
        XCTAssertEqual(id.rawValue, uuid.uuidString.lowercased())
        XCTAssertEqual(id.installID, uuid)
        XCTAssertNil(PeerID(rawValue: "mc-peer").installID)
    }

    func testByeReasonWireMapping() {
        XCTAssertEqual(ByeReason(wireValue: 3), .authenticationFailed)
        XCTAssertEqual(ByeReason(wireValue: 99), .other)
    }

    func testMonotonicTimeArithmetic() {
        let t = MonotonicTime(seconds: 2)
        XCTAssertEqual(t.nanoseconds, 2_000_000_000)
        XCTAssertEqual((t + 0.5) - t, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t - (t + 1.25), -1.25, accuracy: 1e-9)
        XCTAssertEqual(t + (-5), .zero, "clamps at the origin")
        XCTAssertEqual((MonotonicTime(nanoseconds: .max) + 10).nanoseconds, .max)
        XCTAssertEqual(MonotonicTime(seconds: .nan), .zero)
        XCTAssertEqual(MonotonicTime(seconds: 1.5).milliseconds, 1_500)
        XCTAssertLessThan(t, t + 0.001)
    }

    func testMonotonicClockAdvances() {
        let a = MonotonicTime.now()
        var b = MonotonicTime.now()
        for _ in 0..<1_000 where b == a { b = MonotonicTime.now() }
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testByteReaderExtensions() {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(UInt64(0x0102_0304_0506_0708))
        bytes += [9, 10]
        var reader = ByteReader(bytes)
        XCTAssertEqual(reader.readUInt64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(reader.readBytes(1), [9])
        XCTAssertEqual(reader.readBytes(2), [])
        XCTAssertFalse(reader.isValid)
        var rest = ByteReader([1, 2, 3])
        XCTAssertEqual(rest.readRemainingBytes(), [1, 2, 3])
        XCTAssertEqual(rest.readBytes(-1), [])
        XCTAssertFalse(rest.isValid)
    }
}
