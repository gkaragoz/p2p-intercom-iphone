import XCTest
@testable import IntercomCore

final class FrameChunkerTests: XCTestCase {
    func testProducesFixedSizeFramesAcrossBufferBoundaries() {
        var chunker = FrameChunker(frameSize: 4)
        XCTAssertEqual(chunker.append([1, 2, 3]), [])
        XCTAssertEqual(chunker.bufferedCount, 3)
        XCTAssertEqual(chunker.append([4, 5, 6, 7, 8, 9]), [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(chunker.bufferedCount, 1)
        XCTAssertEqual(chunker.append([10, 11, 12]), [[9, 10, 11, 12]])
        XCTAssertEqual(chunker.bufferedCount, 0)
    }

    func testAppendFromPointer() {
        var chunker = FrameChunker(frameSize: 2)
        let samples: [Int16] = [1, 2, 3]
        let frames = samples.withUnsafeBufferPointer { chunker.append($0) }
        XCTAssertEqual(frames, [[1, 2]])
        XCTAssertEqual(chunker.bufferedCount, 1)
    }

    func testFlushPadsWithSilence() {
        var chunker = FrameChunker(frameSize: 4)
        XCTAssertNil(chunker.flush())
        _ = chunker.append([7])
        XCTAssertEqual(chunker.flush(), [7, 0, 0, 0])
        XCTAssertEqual(chunker.bufferedCount, 0)
    }

    func testReset() {
        var chunker = FrameChunker(frameSize: 4)
        _ = chunker.append([1, 2])
        chunker.reset()
        XCTAssertEqual(chunker.bufferedCount, 0)
        XCTAssertEqual(chunker.append([3, 4, 5, 6]), [[3, 4, 5, 6]])
    }

    func testLargeBufferIsSplitIntoManyFrames() {
        var chunker = FrameChunker(frameSize: IntercomProtocol.frameSamples)
        let input = [Int16](repeating: 5, count: 4096)
        let frames = chunker.append(input)
        XCTAssertEqual(frames.count, 4096 / IntercomProtocol.frameSamples)
        XCTAssertEqual(chunker.bufferedCount, 4096 % IntercomProtocol.frameSamples)
        XCTAssertTrue(frames.allSatisfy { $0.count == IntercomProtocol.frameSamples })
    }
}
