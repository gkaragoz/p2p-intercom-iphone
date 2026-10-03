import XCTest
@testable import IntercomCore

/// The peer's capability word must reach the controller through `PeerAdvert`, from the TXT record
/// first and from the verified HELLO / HELLO_ACK once there is one.
final class LinkCapabilityTests: XCTestCase {
    private let multiRate = IntercomProtocol.Network.Capability.multiRateAudio
    private var net: SimNetwork!

    override func setUp() {
        super.setUp()
        net = SimNetwork()
    }

    private func record(for id: PeerID, capabilities: UInt32) -> DiscoveryRecord {
        DiscoveryRecord(peerID: id, displayName: "Phone", keyTag: "", capabilities: capabilities)
    }

    private func adverts(of node: SimNode, for peer: PeerID) -> [PeerAdvert] {
        node.events.compactMap {
            if case .peerDiscovered(let advert) = $0.event, advert.id == peer { return advert }
            return nil
        }
    }

    private func isConnected(_ node: SimNode, to peer: PeerID) -> Bool {
        if case .connected? = node.machine.linkState(of: peer) { return node.audioRoutes[peer] != nil }
        return false
    }

    // MARK: - PeerAdvert

    func testPeerAdvertDefaultsToNoCapabilities() {
        let advert = PeerAdvert(id: SimNetwork.highID, displayName: "Phone", protocolVersion: 2, compatibility: .compatible)
        XCTAssertEqual(advert.capabilities, 0, "an advert built without a capability word must read as a legacy peer")
        XCTAssertFalse(advert.supportsMultiRateAudio)
    }

    func testMultiRateFlagFollowsItsBitOnly() {
        var advert = PeerAdvert(id: SimNetwork.highID, displayName: "Phone", protocolVersion: 2,
                                compatibility: .compatible, capabilities: multiRate)
        XCTAssertTrue(advert.supportsMultiRateAudio)
        advert.capabilities = ~multiRate
        XCTAssertFalse(advert.supportsMultiRateAudio, "unknown bits from a newer build must not count as multi-rate support")
    }

    // MARK: - TXT record path

    func testTxtRecordWithTheBitIsReportedAsMultiRateCapable() {
        let node = net.addNode(SimNetwork.lowID, seed: 1)
        node.handle(.start)
        node.handle(.peerDiscovered(record(for: SimNetwork.highID, capabilities: multiRate)))
        let advert = adverts(of: node, for: SimNetwork.highID).last
        XCTAssertEqual(advert?.capabilities, multiRate)
        XCTAssertEqual(advert?.supportsMultiRateAudio, true, "the TXT `c` entry is the only source before a handshake")
    }

    func testTxtRecordWithoutTheBitIsReportedAsLegacy() {
        let node = net.addNode(SimNetwork.lowID, seed: 1)
        node.handle(.start)
        node.handle(.peerDiscovered(record(for: SimNetwork.highID, capabilities: 0)))
        let advert = adverts(of: node, for: SimNetwork.highID).last
        XCTAssertEqual(advert?.capabilities, 0)
        XCTAssertEqual(advert?.supportsMultiRateAudio, false)
    }

    func testChangedTxtRecordUpdatesCapabilitiesAndReemitsDiscovery() {
        let node = net.addNode(SimNetwork.lowID, seed: 1)
        node.handle(.start)
        node.handle(.peerDiscovered(record(for: SimNetwork.highID, capabilities: 0)))
        XCTAssertEqual(adverts(of: node, for: SimNetwork.highID).count, 1)

        node.handle(.peerDiscovered(record(for: SimNetwork.highID, capabilities: 0)))
        XCTAssertEqual(adverts(of: node, for: SimNetwork.highID).count, 1,
                       "an unchanged re-report must not be reported as a change")

        node.handle(.peerDiscovered(record(for: SimNetwork.highID, capabilities: multiRate)))
        XCTAssertEqual(adverts(of: node, for: SimNetwork.highID).count, 2, "a changed record is a new advert")
        XCTAssertEqual(adverts(of: node, for: SimNetwork.highID).last?.supportsMultiRateAudio, true)

        node.handle(.peerDiscovered(record(for: SimNetwork.highID, capabilities: 0)))
        XCTAssertEqual(adverts(of: node, for: SimNetwork.highID).count, 3)
        XCTAssertEqual(adverts(of: node, for: SimNetwork.highID).last?.supportsMultiRateAudio, false,
                       "a peer downgraded to a legacy build must lose the flag again")
    }

    // MARK: - HELLO path

    func testHandshakeReportsEachSidesOwnCapabilities() {
        let low = net.addNode(SimNetwork.lowID, seed: 1) { $0.capabilities = self.multiRate }
        let high = net.addNode(SimNetwork.highID, seed: 2) { $0.capabilities = 0 }
        low.handle(.start)
        high.handle(.start)
        // Both TXT records stay silent, so the only way to learn the bit is the handshake.
        low.handle(.peerDiscovered(record(for: high.id, capabilities: 0)))
        high.handle(.peerDiscovered(record(for: low.id, capabilities: 0)))
        net.run(for: 2, until: { self.isConnected(low, to: high.id) && self.isConnected(high, to: low.id) })
        XCTAssertTrue(isConnected(low, to: high.id) && isConnected(high, to: low.id))

        let seenByHigh = adverts(of: high, for: low.id).last
        XCTAssertEqual(seenByHigh?.capabilities, multiRate)
        XCTAssertEqual(seenByHigh?.supportsMultiRateAudio, true, "the legacy side must learn the bit from HELLO")

        let seenByLow = adverts(of: low, for: high.id).last
        XCTAssertEqual(seenByLow?.capabilities, 0)
        XCTAssertEqual(seenByLow?.supportsMultiRateAudio, false, "the capable side must see the peer as legacy")
    }

    func testHelloOverrulesAStaleTxtRecord() {
        let low = net.addNode(SimNetwork.lowID, seed: 1) { $0.capabilities = 0 }
        let high = net.addNode(SimNetwork.highID, seed: 2) { $0.capabilities = self.multiRate }
        low.handle(.start)
        high.handle(.start)
        // Each TXT record claims the opposite of what the phone will say in its HELLO.
        low.handle(.peerDiscovered(record(for: high.id, capabilities: 0)))
        high.handle(.peerDiscovered(record(for: low.id, capabilities: multiRate)))
        net.run(for: 2, until: { self.isConnected(low, to: high.id) && self.isConnected(high, to: low.id) })
        XCTAssertTrue(isConnected(low, to: high.id) && isConnected(high, to: low.id))

        XCTAssertEqual(adverts(of: low, for: high.id).last?.supportsMultiRateAudio, true,
                       "HELLO_ACK must add the bit the TXT record lacked")
        XCTAssertEqual(adverts(of: high, for: low.id).last?.supportsMultiRateAudio, false,
                       "HELLO must remove the bit the TXT record wrongly claimed")

        // An unchanged re-report of the stale record must not undo the handshake verdict.
        high.handle(.peerDiscovered(record(for: low.id, capabilities: multiRate)))
        XCTAssertEqual(adverts(of: high, for: low.id).last?.supportsMultiRateAudio, false)
    }

    func testPeerKnownOnlyFromItsHelloCarriesItsCapabilities() {
        let low = net.addNode(SimNetwork.lowID, seed: 1) { $0.capabilities = 0 }
        let high = net.addNode(SimNetwork.highID, seed: 2) { $0.capabilities = self.multiRate }
        low.handle(.start)
        high.handle(.start)
        // Only the higher side discovers the lower one; the lower side meets it through its HELLO.
        high.handle(.peerDiscovered(record(for: low.id, capabilities: 0)))
        net.run(for: 3, until: { self.isConnected(low, to: high.id) && self.isConnected(high, to: low.id) })
        XCTAssertTrue(isConnected(low, to: high.id) && isConnected(high, to: low.id))

        let seenByLow = adverts(of: low, for: high.id)
        XCTAssertFalse(seenByLow.isEmpty, "a peer that dialled before discovery must still be reported")
        XCTAssertEqual(seenByLow.last?.supportsMultiRateAudio, true)
    }
}
