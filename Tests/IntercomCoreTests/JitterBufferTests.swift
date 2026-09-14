import XCTest
@testable import IntercomCore

final class JitterBufferTests: XCTestCase {
    private let frameSize = 4

    /// Frames of 4 samples at 200 Hz are 20 ms long, like the real 320 samples at 16 kHz, so the
    /// millisecond settings keep their meaning while the expected outputs stay readable.
    private func makeBuffer(target: Int = 3, max: Int = 6, resync: Int = 200) -> JitterBuffer {
        var config = JitterBuffer.Configuration()
        config.frameSize = frameSize
        config.sampleRate = 200
        config.targetDelayFrames = target
        config.maxDelayFrames = max
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

    func testFramesShortOfTheTargetPlayAfterATargetOfSilence() {
        // A spurt shorter than the target: the sender stops after two frames.
        let buffer = makeBuffer(target: 3)
        buffer.push(packet(0))
        buffer.push(packet(1))
        for _ in 0..<3 {
            XCTAssertEqual(buffer.pull(count: frameSize), frame(0))
            XCTAssertEqual(buffer.currentState, .buffering)
        }
        XCTAssertEqual(buffer.pull(count: frameSize), frame(1), "one target of silence later, the queue plays")
        XCTAssertEqual(buffer.pull(count: frameSize), frame(2))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(0))
        let stats = buffer.statistics
        XCTAssertEqual(stats.played, 2)
        XCTAssertEqual(stats.underruns, 1)
        XCTAssertEqual(stats.state, .buffering)
        XCTAssertEqual(stats.bufferedFrames, 0)
    }

    func testANewPacketRestartsTheIdleWait() {
        let buffer = makeBuffer(target: 3)
        buffer.push(packet(0))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(0) + frame(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(0) + frame(0), "the wait counts from the newest packet")
        XCTAssertEqual(buffer.currentState, .buffering)
        buffer.push(packet(2))
        XCTAssertEqual(buffer.currentState, .playing, "the target is reached by the push as before")
        XCTAssertEqual(buffer.pull(count: frameSize * 3), frame(1) + frame(2) + frame(3))
    }

    func testTailAfterAnUnderrunPlaysOneTargetLate() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: frameSize * 3), frame(1) + frame(2) + frame(0))
        XCTAssertEqual(buffer.statistics.underruns, 1)
        // The last frame of the sentence arrives after the underrun, then the sender releases.
        buffer.push(packet(2))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(0) + frame(0))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(3))
        XCTAssertEqual(buffer.statistics.played, 3)
        XCTAssertEqual(buffer.statistics.bufferedFrames, 0)
    }

    func testLeftoversOfAShortSpurtDoNotPlayAheadOfTheNextSpurt() {
        let buffer = makeBuffer(target: 3)
        // Spurt A: two frames, short of the target.
        buffer.push(packet(0))
        buffer.push(packet(1))
        // One second of render pulls with nothing arriving.
        let pause = (0..<50).flatMap { _ in buffer.pull(count: frameSize) }
        XCTAssertEqual(pause.filter { $0 != 0 }, frame(1) + frame(2), "spurt A played during the pause")
        XCTAssertEqual(buffer.statistics.bufferedFrames, 0)
        // Spurt B: contiguous sequence numbers, sample clock jumped by the pause.
        let jump = UInt32(60 * frameSize)
        for sequence: UInt16 in 2...4 {
            let samples = [Int16](repeating: 100 + Int16(sequence), count: frameSize)
            buffer.push(AudioPacket(sequence: sequence, timestamp: UInt32(sequence) * UInt32(frameSize) + jump,
                                    samples: samples))
        }
        XCTAssertEqual(buffer.statistics.resyncs, 0)
        XCTAssertEqual(buffer.pull(count: frameSize), [Int16](repeating: 102, count: frameSize),
                       "spurt B starts with its own first frame")
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

    func testLostEndOfBurstIsSkippedWhenPlayoutResumes() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(1) + frame(2))
        // Packet 2, the last of the burst, was lost; the buffer runs dry.
        XCTAssertEqual(buffer.pull(count: frameSize), frame(0))
        XCTAssertEqual(buffer.statistics.underruns, 1)
        buffer.push(packet(3))
        buffer.push(packet(4))
        // Resuming must not conceal the lost frame first: that silence would be permanent delay.
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(4) + frame(5))
        let stats = buffer.statistics
        XCTAssertEqual(stats.concealed, 0)
        XCTAssertEqual(stats.skippedOnResume, 1)
        XCTAssertEqual(stats.played, 4)
    }

    func testLossInsideAPlayingStreamIsStillConcealed() {
        let buffer = makeBuffer(target: 3)
        buffer.push(packet(0))
        buffer.push(packet(1))
        buffer.push(packet(2))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(1))
        buffer.push(packet(4))
        XCTAssertEqual(buffer.pull(count: frameSize * 3), frame(2) + frame(3) + frame(0))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(5))
        XCTAssertEqual(buffer.statistics.concealed, 1)
        XCTAssertEqual(buffer.statistics.skippedOnResume, 0)
    }

    func testOverflowSkipsMissingFramesBeforeDroppingRealOnes() {
        let buffer = makeBuffer(target: 1, max: 4)
        buffer.push(packet(0))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(1))
        // 1 is missing; 2 is queued; 5 makes the span 1...5 = 5 > 4.
        buffer.push(packet(2))
        buffer.push(packet(5))
        XCTAssertEqual(buffer.statistics.overflowDropped, 0, "skipping the missing frame 1 is enough")
        XCTAssertEqual(buffer.pull(count: frameSize * 4), frame(3) + frame(0) + frame(0) + frame(6))
        XCTAssertEqual(buffer.statistics.concealed, 2)
    }

    func testStatisticsReportTargetAndDepthInMilliseconds() {
        let buffer = makeBuffer(target: 3)
        XCTAssertEqual(buffer.statistics.targetDelayMs, 60)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.statistics.depthMs, 40)
        buffer.push(packet(2))
        _ = buffer.pull(count: 2)
        let stats = buffer.statistics
        XCTAssertEqual(stats.state, .playing)
        XCTAssertEqual(stats.depthMs, 50, "half a frame played")
        XCTAssertEqual(stats.bufferedFrames, 2)
    }

    func testRenderLockContentionOutputsSilenceAndIsCounted() {
        let buffer = makeBuffer(target: 1)
        buffer.push(packet(0))
        buffer.push(packet(1))
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            buffer.withStateLockHeldForTesting {
                holding.signal()
                release.wait()
            }
            finished.signal()
        }
        holding.wait()
        var output = [Int16](repeating: 99, count: frameSize)
        let real = output.withUnsafeMutableBufferPointer { buffer.pull(into: $0) }
        XCTAssertEqual(real, 0)
        XCTAssertEqual(output, frame(0), "a contended pull must never leave stale data in the output")
        release.signal()
        finished.wait()

        // Nothing was consumed by the missed cycle, and the miss is reported by the next pull.
        XCTAssertEqual(buffer.pull(count: frameSize), frame(1))
        XCTAssertEqual(buffer.statistics.renderLockMisses, 1)
        XCTAssertEqual(buffer.statistics.played, 1)
    }

    func testGrowingTheCapWhilePlayingReallocatesAndRecovers() {
        let buffer = makeBuffer(target: 2, max: 4)
        buffer.push(packet(0))
        buffer.push(packet(1))
        XCTAssertEqual(buffer.pull(count: frameSize), frame(1))
        var config = buffer.configuration
        config.maxDelayFrames = 40
        buffer.configuration = config
        XCTAssertEqual(buffer.configuration.maxDelayFrames, 40)
        XCTAssertEqual(buffer.currentState, .buffering, "queued frames lived in the old storage")
        for sequence in 2..<30 {
            buffer.push(packet(UInt16(sequence)))
        }
        XCTAssertEqual(buffer.statistics.overflowDropped, 0)
        XCTAssertEqual(buffer.pull(count: frameSize * 2), frame(3) + frame(4))
    }

    func testAdaptiveConfigurationKeepsTheCapAboveTheCeiling() {
        var config = JitterBuffer.Configuration()
        config.adaptiveTarget = true
        config.maxDelayFrames = 3
        let normalized = config.normalized()
        XCTAssertGreaterThanOrEqual(normalized.maxDelayFrames, 12, "200 ms ceiling = 10 frames + 2")
        XCTAssertEqual(normalized.playoutDelay.frameSamples, normalized.frameSize)
        XCTAssertEqual(normalized.playoutDelay.sampleRate, normalized.sampleRate)
    }

    func testResetClearsEverything() {
        let buffer = makeBuffer(target: 1)
        buffer.push(packet(0))
        _ = buffer.pull(count: frameSize)
        buffer.reset()
        var expected = JitterBuffer.Statistics()
        expected.targetDelayMs = 20
        XCTAssertEqual(buffer.statistics, expected)
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
        huge.trimPatienceMs = Int.max
        huge.voicedTrimPatienceMs = Int.min
        huge.crossfadeSamples = Int.max
        huge.silenceThresholdDB = .nan
        huge.resyncDistance = Int.max
        let clamped = huge.normalized()
        XCTAssertEqual(clamped.frameSize, AudioPacket.maxSamples)
        XCTAssertEqual(clamped.targetDelayFrames, 500)
        XCTAssertEqual(clamped.maxDelayFrames, 1_000)
        XCTAssertGreaterThan(clamped.resyncDistance, clamped.maxDelayFrames)
        XCTAssertEqual(clamped.trimPatienceMs, 60_000)
        XCTAssertEqual(clamped.voicedTrimPatienceMs, 0)
        XCTAssertEqual(clamped.crossfadeSamples, clamped.frameSize)
        XCTAssertEqual(clamped.silenceThresholdDB, -50)
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

    func testConfigurationChangesWhilePullingAreSafe() {
        // Storage is swapped under the lock and freed after it; a pull must never see freed memory.
        let buffer = makeBuffer(target: 2, max: 6)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for sequence in 0..<3_000 {
                buffer.push(self.packet(UInt16(truncatingIfNeeded: sequence)))
                if sequence % 50 == 0 {
                    var config = buffer.configuration
                    config.maxDelayFrames = config.maxDelayFrames == 6 ? 40 : 6
                    config.adaptiveTarget = sequence % 100 == 0
                    buffer.configuration = config
                }
                if sequence % 700 == 0 {
                    buffer.reset()
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            var output = [Int16](repeating: 0, count: 3)
            for _ in 0..<6_000 {
                output.withUnsafeMutableBufferPointer { pointer in
                    let real = buffer.pull(into: pointer)
                    XCTAssertTrue((0...3).contains(real))
                    // Every sample is silence or a frame value written by push: never garbage.
                    for sample in pointer where sample < 0 || sample > 3_001 {
                        XCTFail("unexpected sample \(sample)")
                    }
                }
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        _ = buffer.statistics
    }

    func testStatisticsReportTheAdaptiveTargetAndJitter() {
        var config = JitterBuffer.Configuration()
        config.adaptiveTarget = true
        let buffer = JitterBuffer(configuration: config)
        XCTAssertEqual(buffer.statistics.targetDelayMs, 40, "starts at the floor")
        let start = MonotonicTime(seconds: 100)
        func push(_ sequence: Int, lateMs: Double) {
            let packet = AudioPacket(sequence: UInt16(sequence), timestamp: UInt32(sequence * 320),
                                     samples: [Int16](repeating: 100, count: 320))
            buffer.push(packet, arrival: start + (Double(sequence) * 0.020 + lateMs / 1_000))
        }
        for sequence in 0..<10 { push(sequence, lateMs: 0) }
        push(10, lateMs: 60)
        let stats = buffer.statistics
        XCTAssertEqual(stats.jitterMs, 60)
        XCTAssertEqual(stats.targetDelayMs, 100, "60 ms + frame + pull + margin")
        buffer.reset()
        XCTAssertEqual(buffer.statistics.targetDelayMs, 40, "reset forgets the delay history")
        XCTAssertEqual(buffer.statistics.jitterMs, 0)
    }
}
