import XCTest
@testable import IntercomCore

final class VoiceActivityDetectorTests: XCTestCase {
    func testActivatesAboveThresholdAndHoldsForHangover() {
        var detector = VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 2)
        XCTAssertFalse(detector.process(levelDB: -50))
        XCTAssertTrue(detector.process(levelDB: -30))
        XCTAssertTrue(detector.process(levelDB: -50), "first hangover frame")
        XCTAssertTrue(detector.process(levelDB: -50), "second hangover frame")
        XCTAssertFalse(detector.process(levelDB: -50))
    }

    func testLoudFrameDuringHangoverRearmsIt() {
        var detector = VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 2)
        detector.process(levelDB: -30)
        detector.process(levelDB: -50)
        detector.process(levelDB: -30)
        XCTAssertTrue(detector.process(levelDB: -50))
        XCTAssertTrue(detector.process(levelDB: -50))
        XCTAssertFalse(detector.process(levelDB: -50))
    }

    func testZeroHangoverDropsImmediately() {
        var detector = VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 0)
        XCTAssertTrue(detector.process(levelDB: -40))
        XCTAssertFalse(detector.process(levelDB: -41))
    }

    func testReset() {
        var detector = VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 5)
        detector.process(levelDB: 0)
        detector.reset()
        XCTAssertFalse(detector.isActive)
        XCTAssertFalse(detector.process(levelDB: -80))
    }
}
