import XCTest
@testable import IntercomCore

final class PeerElectionTests: XCTestCase {
    private func initiate(_ localToken: String, _ remoteToken: String?, _ localName: String, _ remoteName: String) -> Bool {
        PeerElection.shouldInitiate(localToken: localToken, remoteToken: remoteToken,
                                    localTieBreaker: localName, remoteTieBreaker: remoteName)
    }

    func testExactlyOneSideInitiatesWithDistinctNames() {
        XCTAssertTrue(initiate("9f2a", "0b1c", "Anna", "Berk"))
        XCTAssertFalse(initiate("0b1c", "9f2a", "Berk", "Anna"))
    }

    func testTokensBreakTiesBetweenEqualNames() {
        XCTAssertTrue(initiate("0b1c-token", "9f2a-token", "iPhone", "iPhone"))
        XCTAssertFalse(initiate("9f2a-token", "0b1c-token", "iPhone", "iPhone"))
    }

    func testMissingRemoteTokenStillUsesDeterministicTieBreak() {
        // One phone lacks the other's token (stale discovery info); both must still agree.
        let lowSide = initiate("zzz", nil, "Anna", "Berk")
        let highSide = initiate("aaa", "zzz", "Berk", "Anna")
        XCTAssertTrue(lowSide)
        XCTAssertFalse(highSide)
        XCTAssertFalse(initiate("aaa", nil, "Berk", "Anna"))
        XCTAssertFalse(initiate("aaa", "", "Berk", "Anna"), "an empty token must not force an invitation")
    }

    func testWithoutAnyTieBreakTheLocalSideInvites() {
        XCTAssertTrue(initiate("zzz", nil, "iPhone", "iPhone"))
        XCTAssertTrue(initiate("zzz", "", "", "Berk"))
    }

    func testEqualTokensAndNamesDoNotInitiate() {
        XCTAssertFalse(initiate("same", "same", "iPhone", "iPhone"))
    }

    func testTokensAreUniqueAndLowercase() {
        let tokens = Set((0..<100).map { _ in PeerElection.makeToken() })
        XCTAssertEqual(tokens.count, 100)
        XCTAssertTrue(tokens.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty })
    }
}
