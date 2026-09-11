import XCTest
@testable import IntercomCore

final class SequenceNumberTests: XCTestCase {
    func testDistance() {
        XCTAssertEqual(SequenceNumber.distance(from: 0, to: 0), 0)
        XCTAssertEqual(SequenceNumber.distance(from: 0, to: 1), 1)
        XCTAssertEqual(SequenceNumber.distance(from: 1, to: 0), -1)
        XCTAssertEqual(SequenceNumber.distance(from: 65_535, to: 0), 1)
        XCTAssertEqual(SequenceNumber.distance(from: 0, to: 65_535), -1)
        XCTAssertEqual(SequenceNumber.distance(from: 65_530, to: 5), 11)
        XCTAssertEqual(SequenceNumber.distance(from: 100, to: 32_867), 32_767)
        XCTAssertEqual(SequenceNumber.distance(from: 100, to: 32_868), -32_768)
    }

    func testIsNewer() {
        XCTAssertTrue(SequenceNumber.isNewer(1, than: 0))
        XCTAssertTrue(SequenceNumber.isNewer(0, than: 65_535))
        XCTAssertFalse(SequenceNumber.isNewer(65_535, than: 0))
        XCTAssertFalse(SequenceNumber.isNewer(5, than: 5))
    }
}
