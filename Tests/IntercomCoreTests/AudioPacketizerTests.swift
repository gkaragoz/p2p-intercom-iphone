import Foundation
import XCTest
@testable import IntercomCore

final class AudioPacketizerTests: XCTestCase {
    private let frameSize = 320

    /// A frame whose samples all carry `marker`, so each packet's origin is visible.
    private func frame(_ marker: Int) -> [Int16] {
        [Int16](repeating: Int16(marker), count: frameSize)
    }

    private let send = TransmitGate.Decision(shouldSend: true, didChange: false, isVoiceDetected: true)
    private let skip = TransmitGate.Decision(shouldSend: false, didChange: false, isVoiceDetected: false)

    private func opening(preRoll: Int) -> TransmitGate.Decision {
        TransmitGate.Decision(shouldSend: true, didChange: true, isVoiceDetected: true, preRollFrames: preRoll)
    }

    func testSentFramesAreNumberedContiguouslyAndStampedWithCaptureTime() {
        var packetizer = AudioPacketizer(preRollCapacity: 2)
        var sent: [AudioPacket] = []
        for capture in 0..<10 {
            // Sends frames 0-2 and 6-9; 3-5 are captured but not sent.
            let decision = (3..<6).contains(capture) ? skip : send
            sent += packetizer.process(frame(capture), decision: decision)
        }
        XCTAssertEqual(sent.map(\.sequence), Array(0..<7))
        XCTAssertEqual(sent.map(\.timestamp), [0, 1, 2, 6, 7, 8, 9].map { UInt32($0 * frameSize) },
                       "the sample clock runs for unsent frames too, so pauses are visible to the receiver")
        XCTAssertEqual(sent.map { Int($0.samples[0]) }, [0, 1, 2, 6, 7, 8, 9])
        XCTAssertEqual(packetizer.nextSequence, 7)
        XCTAssertEqual(packetizer.sampleClock, UInt32(10 * frameSize))
    }

    func testPreRollIsSentOldestFirstBeforeTheOpeningFrame() {
        var packetizer = AudioPacketizer(preRollCapacity: 2)
        XCTAssertEqual(packetizer.process(frame(0), decision: send).count, 1)
        for capture in 1...5 {
            XCTAssertEqual(packetizer.process(frame(capture), decision: skip), [])
        }
        XCTAssertEqual(packetizer.bufferedPreRollFrames, 2, "only the most recent frames are kept")
        let packets = packetizer.process(frame(6), decision: opening(preRoll: 2))
        XCTAssertEqual(packets.map { Int($0.samples[0]) }, [4, 5, 6])
        XCTAssertEqual(packets.map(\.sequence), [1, 2, 3], "contiguous with the previous spurt")
        XCTAssertEqual(packets.map(\.timestamp), [4, 5, 6].map { UInt32($0 * frameSize) }, "true capture times")
        XCTAssertEqual(packetizer.bufferedPreRollFrames, 0)

        // The next frame is a plain one; sent frames never come back as pre-roll.
        XCTAssertEqual(packetizer.process(frame(7), decision: send).map(\.sequence), [4])
    }

    func testPreRollIsLimitedToWhatTheDecisionAsksAndWhatIsBuffered() {
        var packetizer = AudioPacketizer(preRollCapacity: 3)
        _ = packetizer.process(frame(0), decision: skip)
        XCTAssertEqual(packetizer.process(frame(1), decision: opening(preRoll: 3)).map { Int($0.samples[0]) }, [0, 1],
                       "only one frame was available")
        for capture in 2...6 {
            _ = packetizer.process(frame(capture), decision: skip)
        }
        XCTAssertEqual(packetizer.process(frame(7), decision: opening(preRoll: 1)).map { Int($0.samples[0]) }, [6, 7])
        XCTAssertEqual(packetizer.bufferedPreRollFrames, 0, "unused older frames are dropped with the rest")

        var noPreRoll = AudioPacketizer(preRollCapacity: 0)
        _ = noPreRoll.process(frame(0), decision: skip)
        XCTAssertEqual(noPreRoll.bufferedPreRollFrames, 0)
        XCTAssertEqual(noPreRoll.process(frame(1), decision: opening(preRoll: 2)).count, 1)
    }

    func testDiscontinuityDropsPreRollAndJumpsTheClock() {
        var packetizer = AudioPacketizer(preRollCapacity: 2)
        _ = packetizer.process(frame(0), decision: send)
        _ = packetizer.process(frame(1), decision: skip)
        _ = packetizer.process(frame(2), decision: skip)
        packetizer.markDiscontinuity()
        XCTAssertEqual(packetizer.bufferedPreRollFrames, 0)
        let packets = packetizer.process(frame(3), decision: opening(preRoll: 2))
        XCTAssertEqual(packets.count, 1, "frames from before the discontinuity are never sent")
        XCTAssertEqual(packets[0].sequence, 1)
        XCTAssertEqual(packets[0].timestamp, UInt32(3 * frameSize + AudioPacketizer.discontinuitySamples))

        var discarded = AudioPacketizer(preRollCapacity: 2)
        _ = discarded.process(frame(0), decision: skip)
        discarded.discardPreRoll()
        XCTAssertEqual(discarded.bufferedPreRollFrames, 0)
        XCTAssertEqual(discarded.sampleClock, UInt32(frameSize), "discardPreRoll keeps the clock")
    }

    func testReceiverSeesADiscontinuityAsANewTalkSpurt() {
        var packetizer = AudioPacketizer()
        var estimator = PlayoutDelayEstimator()
        var arrivalMs = 1_000.0
        func deliver(_ packets: [AudioPacket]) -> [Double] {
            packets.map { estimator.record(sequence: $0.sequence, timestamp: $0.timestamp,
                                           arrival: MonotonicTime(nanoseconds: UInt64(arrivalMs * 1_000_000))) }
        }
        for capture in 0..<50 {
            _ = deliver(packetizer.process(frame(capture), decision: send))
            arrivalMs += 20
        }
        // Capture stops for 150 ms (an engine rebuild): no frames, so no clock advance by itself.
        packetizer.markDiscontinuity()
        arrivalMs += 150
        let delays = deliver(packetizer.process(frame(50), decision: send))
        XCTAssertEqual(delays, [0])
        XCTAssertEqual(estimator.spurtCount, 2)
    }

    func testWrapAround() {
        var packetizer = AudioPacketizer(preRollCapacity: 2, initialSequence: 65_535, initialSampleClock: UInt32.max - 100)
        let first = packetizer.process(frame(0), decision: send)
        let second = packetizer.process(frame(1), decision: send)
        XCTAssertEqual(first[0].sequence, 65_535)
        XCTAssertEqual(second[0].sequence, 0)
        XCTAssertEqual(first[0].timestamp, UInt32.max - 100)
        XCTAssertEqual(second[0].timestamp, UInt32(frameSize - 101))
    }

    func testGateAndPacketizerTogetherSendPreRollInOrder() {
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 2))
        var packetizer = AudioPacketizer(preRollCapacity: gate.preRollFrames)
        // Levels per captured frame: loud, then quiet long enough to close, then loud again.
        let levels: [Float] = [-10, -60, -60, -60, -60, -60, -60, -10, -10]
        var sent: [AudioPacket] = []
        for (capture, level) in levels.enumerated() {
            sent += packetizer.process(frame(capture), decision: gate.evaluate(levelDB: level))
        }
        // 0 sent; 1-2 hangover; 3-6 unsent; 7 opens with pre-roll 5, 6.
        XCTAssertEqual(sent.map { Int($0.samples[0]) }, [0, 1, 2, 5, 6, 7, 8])
        XCTAssertEqual(sent.map(\.sequence), Array(0..<7))
        XCTAssertEqual(sent.map(\.timestamp), sent.map { UInt32(Int($0.samples[0]) * frameSize) })
    }
}
