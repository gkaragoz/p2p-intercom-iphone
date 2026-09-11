import XCTest
@testable import IntercomCore

final class PeerElectionTests: XCTestCase {
    func testExactlyOneSideInitiates() {
        let a = "0b1c-token"
        let b = "9f2a-token"
        XCTAssertTrue(PeerElection.shouldInitiate(localToken: a, remoteToken: b))
        XCTAssertFalse(PeerElection.shouldInitiate(localToken: b, remoteToken: a))
    }

    func testMissingRemoteTokenMeansInitiate() {
        XCTAssertTrue(PeerElection.shouldInitiate(localToken: "zzz", remoteToken: nil))
        XCTAssertTrue(PeerElection.shouldInitiate(localToken: "zzz", remoteToken: ""))
    }

    func testEqualTokensDoNotInitiate() {
        XCTAssertFalse(PeerElection.shouldInitiate(localToken: "same", remoteToken: "same"))
    }

    func testTokensAreUniqueAndLowercase() {
        let tokens = Set((0..<100).map { _ in PeerElection.makeToken() })
        XCTAssertEqual(tokens.count, 100)
        XCTAssertTrue(tokens.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty })
    }
}
