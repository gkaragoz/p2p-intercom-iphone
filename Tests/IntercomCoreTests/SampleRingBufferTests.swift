import XCTest
@testable import IntercomCore

final class SampleRingBufferTests: XCTestCase {
    func testWriteAndReadWrapAround() {
        var ring = SampleRingBuffer(capacity: 5)
        XCTAssertEqual(ring.write([1, 2, 3, 4]), 4)
        XCTAssertEqual(ring.read(count: 3), [1, 2, 3])
        XCTAssertEqual(ring.write([5, 6, 7, 8]), 4)
        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.read(count: 10), [4, 5, 6, 7, 8])
        XCTAssertTrue(ring.isEmpty)
    }

    func testWriteRefusesOverflow() {
        var ring = SampleRingBuffer(capacity: 3)
        XCTAssertEqual(ring.write([1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(ring.availableSpace, 0)
        XCTAssertEqual(ring.write([9]), 0)
        XCTAssertEqual(ring.read(count: 3), [1, 2, 3])
    }

    func testSilenceAndDrop() {
        var ring = SampleRingBuffer(capacity: 8)
        ring.write([1, 2])
        XCTAssertEqual(ring.writeSilence(3), 3)
        ring.drop(1)
        XCTAssertEqual(ring.read(count: 4), [2, 0, 0, 0])
        ring.drop(100)
        XCTAssertTrue(ring.isEmpty)
    }

    func testReadIntoPointerReportsCount() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([7, 8])
        var output = [Int16](repeating: 99, count: 4)
        let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        XCTAssertEqual(read, 2)
        XCTAssertEqual(output, [7, 8, 99, 99])
    }

    func testRemoveAll() {
        var ring = SampleRingBuffer(capacity: 4)
        ring.write([1, 2, 3])
        ring.removeAll()
        XCTAssertEqual(ring.count, 0)
        XCTAssertEqual(ring.availableSpace, 4)
    }
}
