import XCTest
@testable import IntercomCore

final class LatencyProfileTests: XCTestCase {
    func testBalancedReproducesTheOriginalEstimatorBounds() {
        let original = PlayoutDelayEstimator.Configuration.default
        XCTAssertEqual(LatencyProfile.balanced.playoutFloorMs, original.floorMs,
                       "balanced must keep the estimator floor the app shipped with")
        XCTAssertEqual(LatencyProfile.balanced.playoutCeilingMs, original.ceilingMs)
        XCTAssertEqual(LatencyProfile.balanced.playoutMarginMs, original.marginMs)
        XCTAssertEqual(LatencyProfile.balanced.ioBufferDuration, 0.010, accuracy: 1e-12,
                       "10 ms was the preferred I/O buffer before profiles existed")
        XCTAssertEqual(LatencyProfile.default, .balanced)
    }

    func testProfilesTradeDelayForRobustnessInOrder() {
        let fast = LatencyProfile.fast, balanced = LatencyProfile.balanced, safe = LatencyProfile.safe
        XCTAssertLessThan(fast.playoutFloorMs, balanced.playoutFloorMs)
        XCTAssertLessThan(balanced.playoutFloorMs, safe.playoutFloorMs)
        XCTAssertLessThan(fast.playoutCeilingMs, balanced.playoutCeilingMs)
        XCTAssertLessThan(balanced.playoutCeilingMs, safe.playoutCeilingMs)
        XCTAssertLessThan(fast.playoutMarginMs, balanced.playoutMarginMs)
        XCTAssertLessThan(balanced.playoutMarginMs, safe.playoutMarginMs)
        XCTAssertLessThan(fast.ioBufferDuration, balanced.ioBufferDuration)
        XCTAssertLessThan(balanced.ioBufferDuration, safe.ioBufferDuration)
        XCTAssertEqual(LatencyProfile.allCases, [.fast, .balanced, .safe], "the picker lists them fastest first")
    }

    func testEveryProfileSurvivesEstimatorNormalization() {
        for profile in LatencyProfile.allCases {
            var configuration = PlayoutDelayEstimator.Configuration()
            configuration.floorMs = profile.playoutFloorMs
            configuration.ceilingMs = profile.playoutCeilingMs
            configuration.marginMs = profile.playoutMarginMs
            XCTAssertEqual(configuration.normalized(), configuration,
                           "\(profile): the bounds must be in range and ordered, or the estimator would silently clamp them")
        }
    }
}
