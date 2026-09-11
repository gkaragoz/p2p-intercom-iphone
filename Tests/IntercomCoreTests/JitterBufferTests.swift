import XCTest
@testable import IntercomCore

final class JitterBufferTests: XCTestCase {
    private let frameSize = 4

    private func makeBuffer(target: Int = 3, max: Int = 6, trimPatience: Int = 50, resync: Int = 200) -> JitterBuffer {
        var config = JitterBuffer.Configuration()
        config.frameSize = frameSize
        config.targetDelayFrames = target
        config.maxDelayFrames = max
        config.trimPatiencePulls = trimPatience
        config.resyncDistance = resync
        return JitterBuffer(configuration: config)
    }

    /// A frame whose samples all equal its sequence number, so playback order is observable.
    private func packet(_ sequence: UInt16) -> AudioPacket {
        AudioPacket(sequence: sequence, timestamp: UInt32(sequence) * UInt32(frameSize),
                    samples: [Int16](repeating: Int16(truncatingIfNeeded: Int(sequence) + 1), count: frameSize))
    }

    private func frame(_ value: Int16) -> [Int16] {
        [Int16](repeating: value, count: frameSize)
    }

    func testPrebuffersUntilTargetDepth() {
        let buffer = makeBuffer(target: 3)
        XCTAssertEqual(buffer.currentState, .idle)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.currentState, .buffering)
        XCTAssertEqual(buffer.pull(count: frameSize), frame(0))
        XCTAssertEqual(buffer.statistics.played, 0)
        buffer.push(packet(2))
        XCTAssertEqual(buffer.currentState, .playing)
        XCTAssertEqual(buffer.pull(count: frameSize), frame(1))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(2))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(3))
        XCTAssertEqual(buffer.statistics.played, 3)
        XCTAssertEqual(buffer.statistics.underruns, 0)
    }

    func testPullSizesNotAlignedToFrames() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: 3), [1, 1, 1])
        XCTAssertEqual(buffer.pull(count: 3), [1, 2, 2])
        XCTAssertEqual(buffer.pull(count: 2), [2, 2])
        XCTAssertEqual(buffer.statistics.played, 2)
    }

    func testReordersOutOfOrderPackets() {
        let buffer = makeBuffer(target: 3)
        buffer.push(packet(0))
        buffer.push(packet(2))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: frameSize * 3), frame(1) + frame(2) + frame(3))
        XCTAssertEqual(buffer.statistics.concealed, 0)
    }

    func testConcealsMissingPacketWithSilence() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(1))
        buffer.push(packet(3))
        buffer.push(packet(4))
        XCTAssertEqual(buffer.pull(count: frameSize * 4), frame(1) + frame(2) + frame(0) + frame(4))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(5))
        let stats = buffer.statistics
        XCTAssertEqual(stats.concealed, 1)
        XCTAssertEqual(stats.played, 4)
        XCTAssertEqual(stats.underruns, 0)
    }

    func testLatePacketAfterConcealmentIsDropped() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(2))
        _ = buffer.pull(count: frameSize * 2) // plays 0, conceals 1
        buffer.push(packet(1))
        XCTAssertEqual(buffer.statistics.lateDropped, 1)
        XCTAssertEqual(buffer.pull(count: frameSize), frame(3))
    }

    func testDuplicatesAreIgnored() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.statistics.duplicates, 1)
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(1) + frame(2))
    }

    func testUnderrunFallsBackToBufferingAndResumes() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(1) + frame(2))
        // Nothing left: partial output is padded with silence and the buffer re-arms.
        XCTAssertEqual(buffer.pull(count: frameSize), frame(0))
        XCTAssertEqual(buffer.statistics.underruns, 1)
        XCTAssertEqual(buffer.currentState, .buffering)
        buffer.push(packet(2))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(0), "still buffering with one frame")
        buffer.push(packet(3))
        XCTAssertEqual(buffer.currentState, .playing)
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(3) + frame(4))
    }

    func testPartialUnderrunReturnsRealSampleCount() {
        let buffer = makeBuffer(target: 1)
        buffer.push(packet(0))
        var output = [Int16](repeating: 42, count: frameSize + 2)
        let real = output.withUnsafeMutableBufferPointer { buffer.pull(into: $0) }
        XCTAssertEqual(real, frameSize)
        XCTAssertEqual(output, frame(1) + [0, 0])
    }

    func testOverflowDropsOldestAndSkipsForward() {
        let buffer = makeBuffer(target: 2, max: 4)
        for sequence in 0..<6 {
            buffer.push(packet(UInt16(sequence)))
        }
        XCTAssertEqual(buffer.statistics.overflowDropped, 2)
        XCTAssertEqual(buffer.statistics.bufferedFrames, 4)
        XCTAssertEqual(buffer.pull(count: frameSize * 4), frame(3) + frame(4) + frame(5) + frame(6))
    }

    func testResyncOnSenderRestart() {
        let buffer = makeBuffer(target: 2, resync: 50)
        buffer.push(packet(1000))
        buffer.push(packet(1001))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(1001) + frame(1002))
        // The peer app restarted and begins again at 0.
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.statistics.resyncs, 1)
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(1) + frame(2))
    }

    func testResyncOnHugeForwardJump() {
        let buffer = makeBuffer(target: 2, resync: 50)
        buffer.push(packet(0))
        buffer.push(packet(1))
        buffer.push(packet(500))
        XCTAssertEqual(buffer.statistics.resyncs, 1)
        XCTAssertEqual(buffer.currentState, .buffering)
        buffer.push(packet(501))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(Int16(501)) + frame(Int16(502)))
    }

    func testSequenceWrapAround() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(65_534))
        buffer.push(packet(65_535))
        buffer.push(packet(0))
        buffer.push(packet(1))
        let expected = frame(Int16(truncatingIfNeeded: 65_535)) + frame(Int16(truncatingIfNeeded: 65_536)) + frame(1) + frame(2)
        XCTAssertEqual(buffer.pull(count: frameSize * 4), expected)
        XCTAssertEqual(buffer.statistics.concealed, 0)
        XCTAssertEqual(buffer.statistics.lateDropped, 0)
    }

    func testTrimsPersistentExcessLatency() {
        let buffer = makeBuffer(target: 2, max: 10, trimPatience: 3)
        for sequence in 0..<8 {
            buffer.push(packet(UInt16(sequence)))
        }
        // Keep the queue topped up so it stays deeper than target + 2.
        var next: UInt16 = 8
        for _ in 0..<3 {
            _ = buffer.pull(count: frameSize)
            buffer.push(packet(next))
            next += 1
        }
        XCTAssertEqual(buffer.statistics.trimmed, 1)
        // After trimming, playback skipped exactly one frame.
        let played = buffer.pull(count: frameSize)
        XCTAssertEqual(played, frame(5), "frames 0,1,2 played normally, frame 3 trimmed, frame 4 plays next")
    }

    func testResetClearsEverything() {
        let buffer = makeBuffer(target: 1)
        buffer.push(packet(0))
        _ = buffer.pull(count: frameSize)
        buffer.reset()
        XCTAssertEqual(buffer.statistics, JitterBuffer.Statistics())
        XCTAssertEqual(buffer.currentState, .idle)
        XCTAssertEqual(buffer.pull(count: frameSize), frame(0))
    }

    func testConfigurationIsNormalized() {
        var config = JitterBuffer.Configuration()
        config.targetDelayFrames = 0
        config.maxDelayFrames = 0
        config.resyncDistance = 0
        let normalized = config.normalized()
        XCTAssertEqual(normalized.targetDelayFrames, 1)
        XCTAssertEqual(normalized.maxDelayFrames, 3)
        XCTAssertGreaterThan(normalized.resyncDistance, normalized.maxDelayFrames)

        let buffer = makeBuffer()
        buffer.configuration = config
        XCTAssertEqual(buffer.configuration.targetDelayFrames, 1)

        var huge = JitterBuffer.Configuration()
        huge.frameSize = Int.max
        huge.targetDelayFrames = Int.max
        huge.maxDelayFrames = Int.max
        huge.trimPatiencePulls = Int.max
        huge.resyncDistance = Int.max
        let clamped = huge.normalized()
        XCTAssertEqual(clamped.frameSize, AudioPacket.maxSamples)
        XCTAssertEqual(clamped.targetDelayFrames, 500)
        XCTAssertEqual(clamped.maxDelayFrames, 1_000)
        XCTAssertGreaterThan(clamped.resyncDistance, clamped.maxDelayFrames)
        _ = JitterBuffer(configuration: huge)
    }

    func testZeroLengthPullIsHarmless() {
        let buffer = makeBuffer()
        XCTAssertEqual(buffer.pull(count: 0), [])
    }

    func testConcurrentPushAndPullDoNotCrash() {
        let buffer = makeBuffer(target: 2, max: 8)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for sequence in 0..<2000 {
                buffer.push(self.packet(UInt16(truncatingIfNeeded: sequence)))
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<2000 {
                _ = buffer.pull(count: self.frameSize)
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(buffer.statistics.received, 2000)
    }
}
