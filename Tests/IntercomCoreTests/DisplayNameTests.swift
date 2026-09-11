import XCTest
@testable import IntercomCore

final class DisplayNameTests: XCTestCase {
    func testTrimsWhitespaceAndFallsBack() {
        XCTAssertEqual(DisplayName.sanitized("  Gökhan  "), "Gökhan")
        XCTAssertEqual(DisplayName.sanitized("   "), DisplayName.fallback)
        XCTAssertEqual(DisplayName.sanitized(""), DisplayName.fallback)
    }

    func testTruncatesToUTF8Limit() {
        let long = String(repeating: "ş", count: 100) // 2 bytes each
        let result = DisplayName.sanitized(long)
        XCTAssertLessThanOrEqual(result.utf8.count, DisplayName.maxUTF8Bytes)
        XCTAssertEqual(result.count, 31)
        XCTAssertEqual(DisplayName.sanitized(String(repeating: "a", count: 63)).utf8.count, 63)
    }
}
