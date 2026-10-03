import Foundation
import XCTest
@testable import IntercomCore

final class TestRecordingTests: XCTestCase {
    private let frameSize = 320

    /// A frame whose samples all carry `marker`, so each frame's share of the recording is visible.
    private func frame(_ marker: Int) -> [Int16] {
        [Int16](repeating: Int16(marker), count: frameSize)
    }

    /// A recording whose samples count up, so any reordering or misalignment shows.
    private let ramp: [Int16] = (0..<1_000).map { Int16(truncatingIfNeeded: $0) }

    /// Drains the packetizer, returning every packet in order.
    private func drain(_ packetizer: inout LoopbackPacketizer) -> [AudioPacket] {
        var packets: [AudioPacket] = []
        while let packet = packetizer.next() {
            packets.append(packet)
        }
        return packets
    }

    // MARK: - TestRecorder

    func testZeroCapacityRecorderIsAlwaysFullAndRefusesEveryFrame() {
        var recorder = TestRecorder(capacity: 0)
        XCTAssertTrue(recorder.isFull)
        XCTAssertEqual(recorder.remaining, 0)
        XCTAssertFalse(recorder.append(frame(1)), "a recorder that was full from the start never *becomes* full")
        XCTAssertEqual(recorder.count, 0)
        XCTAssertTrue(recorder.isFull)
        XCTAssertEqual(recorder.take(), [])
    }

    func testNegativeCapacityIsTreatedAsZero() {
        let recorder = TestRecorder(capacity: -5)
        XCTAssertEqual(recorder.capacity, 0)
        XCTAssertTrue(recorder.isFull)
        XCTAssertEqual(recorder.remaining, 0)
    }

    func testRecorderFillsAcrossFramesAndTruncatesTheFrameThatReachesCapacity() {
        var recorder = TestRecorder(capacity: 800)
        XCTAssertFalse(recorder.isFull)
        XCTAssertEqual(recorder.remaining, 800)

        XCTAssertFalse(recorder.append(frame(1)))
        XCTAssertEqual(recorder.count, 320)
        XCTAssertEqual(recorder.remaining, 480)
        XCTAssertFalse(recorder.append(frame(2)))
        XCTAssertEqual(recorder.count, 640)
        XCTAssertTrue(recorder.append(frame(3)), "the call that fills the recorder reports it")

        XCTAssertTrue(recorder.isFull)
        XCTAssertEqual(recorder.count, 800)
        XCTAssertEqual(recorder.remaining, 0)
        XCTAssertEqual(recorder.samples.count, 800)
        XCTAssertEqual(Array(recorder.samples[0..<320]), frame(1))
        XCTAssertEqual(Array(recorder.samples[320..<640]), frame(2))
        XCTAssertEqual(Array(recorder.samples[640..<800]), [Int16](repeating: 3, count: 160),
                       "the third frame is truncated to the 160 samples that still fit")
    }

    func testAppendingToAFullRecorderIsANoOp() {
        var recorder = TestRecorder(capacity: 800)
        recorder.append(frame(1))
        recorder.append(frame(2))
        XCTAssertTrue(recorder.append(frame(3)))
        let full = recorder.samples

        XCTAssertFalse(recorder.append(frame(4)), "becoming full is reported once, not on every later call")
        XCTAssertEqual(recorder.count, 800)
        XCTAssertEqual(recorder.samples, full, "a full recorder ignores further frames")
        XCTAssertFalse(recorder.append([]), "an empty frame never fills or overfills")
    }

    func testAFrameThatExactlyReachesCapacityFillsTheRecorder() {
        var recorder = TestRecorder(capacity: 640)
        XCTAssertFalse(recorder.append(frame(1)))
        XCTAssertTrue(recorder.append(frame(2)))
        XCTAssertEqual(recorder.samples, frame(1) + frame(2), "nothing is truncated when the frame fits exactly")
        XCTAssertFalse(recorder.append(frame(3)))
        XCTAssertEqual(recorder.count, 640)
    }

    func testTakeReturnsTheRecordingAndLeavesAnEmptyRecorderWithTheSameCapacity() {
        var recorder = TestRecorder(capacity: 800)
        recorder.append(frame(1))
        recorder.append(frame(2))
        recorder.append(frame(3))

        let taken = recorder.take()
        XCTAssertEqual(taken.count, 800)
        XCTAssertEqual(Array(taken[0..<320]), frame(1))
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(recorder.samples, [])
        XCTAssertEqual(recorder.capacity, 800, "take keeps the capacity")
        XCTAssertFalse(recorder.isFull)
        XCTAssertEqual(recorder.remaining, 800)

        XCTAssertFalse(recorder.append(frame(5)), "a taken recorder records again")
        XCTAssertEqual(recorder.count, 320)
        XCTAssertEqual(recorder.samples, frame(5))
        XCTAssertEqual(taken.count, 800, "the taken recording is untouched by the new one")

        XCTAssertEqual(recorder.take(), frame(5))
        XCTAssertEqual(recorder.take(), [], "taking twice yields nothing the second time")
    }

    func testResetClearsTheRecordingAndKeepsTheCapacity() {
        var recorder = TestRecorder(capacity: 800)
        recorder.append(frame(1))
        recorder.append(frame(2))
        recorder.append(frame(3))
        XCTAssertTrue(recorder.isFull)

        recorder.reset()
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(recorder.samples, [])
        XCTAssertEqual(recorder.capacity, 800)
        XCTAssertFalse(recorder.isFull)
        XCTAssertEqual(recorder.remaining, 800)
        XCTAssertFalse(recorder.append(frame(7)), "a reset recorder records again")
        XCTAssertEqual(recorder.samples, frame(7))
    }

    // MARK: - LoopbackPacketizer

    func testRecordingIsSplitIntoWholeFramesWithTheTailZeroPadded() {
        var packetizer = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono16k)
        XCTAssertEqual(packetizer.codec, .pcm16Mono16k)
        XCTAssertEqual(packetizer.packetCount, 4, "1000 samples are three whole 320-sample frames and a 40-sample tail")
        XCTAssertEqual(packetizer.remainingPackets, 4)
        XCTAssertFalse(packetizer.isFinished)
        XCTAssertEqual(packetizer.durationMs, 80)

        let packets = drain(&packetizer)
        XCTAssertEqual(packets.count, 4)
        XCTAssertEqual(packets.map(\.samples.count), [320, 320, 320, 320], "every packet carries a whole 20 ms frame")
        XCTAssertEqual(packets.map(\.sequence), [0, 1, 2, 3])
        XCTAssertEqual(packets.map(\.timestamp), [0, 320, 640, 960])
        XCTAssertTrue(packets.allSatisfy { $0.codec == .pcm16Mono16k })

        XCTAssertEqual(packets[0].samples, Array(ramp[0..<320]))
        XCTAssertEqual(packets[1].samples, Array(ramp[320..<640]))
        XCTAssertEqual(packets[2].samples, Array(ramp[640..<960]))
        XCTAssertEqual(Array(packets[3].samples[0..<40]), Array(ramp[960..<1_000]))
        XCTAssertEqual(Array(packets[3].samples[40..<320]), [Int16](repeating: 0, count: 280),
                       "the partial last frame is padded with silence")

        XCTAssertNil(packetizer.next())
        XCTAssertNil(packetizer.next(), "stays finished")
        XCTAssertTrue(packetizer.isFinished)
        XCTAssertEqual(packetizer.remainingPackets, 0)
    }

    func testRemainingPacketsCountsDownAsPacketsAreTaken() {
        var packetizer = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono16k)
        for expected in stride(from: 4, through: 1, by: -1) {
            XCTAssertEqual(packetizer.remainingPackets, expected)
            XCTAssertFalse(packetizer.isFinished)
            XCTAssertNotNil(packetizer.next())
        }
        XCTAssertEqual(packetizer.remainingPackets, 0)
        XCTAssertTrue(packetizer.isFinished)
    }

    func testFrameSizeFollowsTheCodec() {
        var narrow = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono8k)
        XCTAssertEqual(narrow.packetCount, 7, "1000 samples at 8 kHz are six 160-sample frames and a 40-sample tail")
        XCTAssertEqual(narrow.durationMs, 140)
        let narrowPackets = drain(&narrow)
        XCTAssertEqual(narrowPackets.map(\.samples.count), [Int](repeating: 160, count: 7))
        XCTAssertEqual(narrowPackets.map(\.timestamp), (0..<7).map { UInt32($0 * 160) }, "timestamps advance by the codec's frame")
        XCTAssertTrue(narrowPackets.allSatisfy { $0.codec == .pcm16Mono8k })

        var high = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono24k)
        XCTAssertEqual(high.packetCount, 3, "1000 samples at 24 kHz are two 480-sample frames and a 40-sample tail")
        XCTAssertEqual(drain(&high).map(\.samples.count), [480, 480, 480])

        var highest = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono32k)
        XCTAssertEqual(highest.packetCount, 2, "1000 samples at 32 kHz are one 640-sample frame and a 360-sample tail")
        XCTAssertEqual(highest.durationMs, 40)
        let highestPackets = drain(&highest)
        XCTAssertEqual(highestPackets.map(\.samples.count), [640, 640])
        XCTAssertEqual(highestPackets.map(\.timestamp), [0, 640])
        XCTAssertTrue(highestPackets.allSatisfy { $0.codec == .pcm16Mono32k })
    }

    func testAnExactMultipleOfTheFrameNeedsNoPadding() {
        var packetizer = LoopbackPacketizer(samples: Array(ramp[0..<640]), codec: .pcm16Mono16k)
        XCTAssertEqual(packetizer.packetCount, 2)
        let packets = drain(&packetizer)
        XCTAssertEqual(packets.map(\.samples), [Array(ramp[0..<320]), Array(ramp[320..<640])])
    }

    func testSequenceNumbersWrapLikeTheRealSender() {
        var packetizer = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono16k, initialSequence: 65_534)
        XCTAssertEqual(drain(&packetizer).map(\.sequence), [65_534, 65_535, 0, 1],
                       "the third packet wraps to 0 so the receiver sees a contiguous stream")
    }

    func testTimestampsWrapWithoutTrapping() {
        let start = UInt32.max - 100
        var packetizer = LoopbackPacketizer(samples: ramp, codec: .pcm16Mono16k, initialTimestamp: start)
        XCTAssertEqual(drain(&packetizer).map(\.timestamp), [start, 219, 539, 859],
                       "UInt32.max - 100 + 320 wraps to 219")
    }

    func testEmptyRecordingYieldsNoPackets() {
        var packetizer = LoopbackPacketizer(samples: [], codec: .pcm16Mono16k)
        XCTAssertEqual(packetizer.packetCount, 0)
        XCTAssertEqual(packetizer.remainingPackets, 0)
        XCTAssertEqual(packetizer.durationMs, 0)
        XCTAssertTrue(packetizer.isFinished)
        XCTAssertNil(packetizer.next())
    }

    func testDurationIsTwentyMillisecondsPerPacket() {
        for codec in AudioPacket.Codec.allCases {
            for sampleCount in [0, 1, 159, 160, 161, 1_000, 5 * codec.sampleRate] {
                let packetizer = LoopbackPacketizer(samples: [Int16](repeating: 0, count: sampleCount), codec: codec)
                XCTAssertEqual(packetizer.durationMs, packetizer.packetCount * 20, "\(codec) with \(sampleCount) samples")
            }
            let fiveSeconds = LoopbackPacketizer(samples: [Int16](repeating: 0, count: 5 * codec.sampleRate), codec: codec)
            XCTAssertEqual(fiveSeconds.packetCount, 250, "\(codec): 5 s is 250 packets at any rate")
            XCTAssertEqual(fiveSeconds.durationMs, 5_000)
        }
    }

    func testEveryPacketSurvivesTheWireEncoding() {
        for codec in AudioPacket.Codec.allCases {
            var packetizer = LoopbackPacketizer(samples: ramp, codec: codec, initialSequence: 65_535, initialTimestamp: UInt32.max - 10)
            for packet in drain(&packetizer) {
                XCTAssertEqual(AudioPacket.decode(packet.encoded()), packet, "\(codec) sequence \(packet.sequence)")
            }
        }
    }

    // MARK: - Recorder and packetizer together

    func testRecordedFramesComeBackInOrderThroughThePacketizer() {
        // A capacity that ends mid-frame, fed 20 ms frames like the capture worker does, until full.
        let capacity = 3 * frameSize + 100
        var recorder = TestRecorder(capacity: capacity)
        var captured: [Int16] = []
        var clock = 0
        var appends = 0
        while true {
            let frame = (0..<frameSize).map { _ -> Int16 in
                clock += 1
                return Int16(truncatingIfNeeded: clock * 7)
            }
            captured += frame
            appends += 1
            if recorder.append(frame) { break }
        }
        XCTAssertEqual(appends, 4, "the fourth frame fills the recorder")
        XCTAssertEqual(recorder.count, capacity)

        var packetizer = LoopbackPacketizer(samples: recorder.take(), codec: WireRate.standard.codec)
        XCTAssertEqual(recorder.count, 0, "take left the recorder ready for the next test recording")
        XCTAssertEqual(packetizer.packetCount, 4, "the truncated fourth frame is padded back to a whole one")
        let played = drain(&packetizer).flatMap(\.samples)
        XCTAssertEqual(played.count, 4 * frameSize)
        XCTAssertEqual(Array(played[0..<capacity]), Array(captured[0..<capacity]),
                       "playback reproduces the recording sample for sample up to the capacity")
        XCTAssertEqual(Array(played[capacity...]), [Int16](repeating: 0, count: frameSize - 100),
                       "what was cut off at the capacity is silence on playback, not stale capture")
    }
}
