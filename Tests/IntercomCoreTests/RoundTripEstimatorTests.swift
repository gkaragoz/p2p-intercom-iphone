import XCTest
@testable import IntercomCore

final class RoundTripEstimatorTests: XCTestCase {
    func testMeasuresAndSmooths() {
        var estimator = RoundTripEstimator()
        estimator.smoothing = 0.5
        let first = estimator.makePing(nowMs: 1000)
        XCTAssertEqual(estimator.receivePong(first, nowMs: 1040), 40)
        XCTAssertEqual(estimator.smoothedRTTMs, 40)
        let second = estimator.makePing(nowMs: 2000)
        XCTAssertEqual(estimator.receivePong(second, nowMs: 2020), 20)
        XCTAssertEqual(estimator.lastRTTMs, 20)
        XCTAssertEqual(estimator.smoothedRTTMs, 30)
    }

    func testUnknownOrRepeatedPongIsIgnored() {
        var estimator = RoundTripEstimator()
        let ping = estimator.makePing(nowMs: 10)
        XCTAssertNil(estimator.receivePong(.init(id: 999, sentAtMs: 0), nowMs: 20))
        XCTAssertEqual(estimator.receivePong(ping, nowMs: 20), 10)
        XCTAssertNil(estimator.receivePong(ping, nowMs: 30))
    }

    func testOldOutstandingPingsAreForgotten() {
        var estimator = RoundTripEstimator()
        estimator.maxOutstanding = 2
        let first = estimator.makePing(nowMs: 1)
        _ = estimator.makePing(nowMs: 2)
        _ = estimator.makePing(nowMs: 3)
        XCTAssertNil(estimator.receivePong(first, nowMs: 10))
    }

    func testClockGoingBackwardsDoesNotTrap() {
        var estimator = RoundTripEstimator()
        let ping = estimator.makePing(nowMs: 100)
        XCTAssertEqual(estimator.receivePong(ping, nowMs: 50), 0)
    }

    func testIDsAreDistinct() {
        var estimator = RoundTripEstimator()
        let ids = (0..<20).map { _ in estimator.makePing(nowMs: 0).id }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testReset() {
        var estimator = RoundTripEstimator()
        let ping = estimator.makePing(nowMs: 0)
        _ = estimator.receivePong(ping, nowMs: 5)
        estimator.reset()
        XCTAssertNil(estimator.lastRTTMs)
        XCTAssertNil(estimator.smoothedRTTMs)
    }
}
