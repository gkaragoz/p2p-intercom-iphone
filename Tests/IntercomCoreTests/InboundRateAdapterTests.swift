import Foundation
import XCTest
@testable import IntercomCore

final class InboundRateAdapterTests: XCTestCase {
    private func packet(sequence: UInt16, timestamp: UInt32, codec: AudioPacket.Codec, value: Int16 = 1_000) -> AudioPacket {
        AudioPacket(sequence: sequence, timestamp: timestamp, codec: codec,
                    samples: [Int16](repeating: value, count: codec.frameSamples))
    }

    /// `count` consecutive whole frames at `codec` from `sequence` / `timestamp`.
    private func stream(count: Int, sequence: UInt16 = 0, timestamp: UInt32 = 0, codec: AudioPacket.Codec) -> [AudioPacket] {
        (0..<count).map { index in
            packet(sequence: sequence &+ UInt16(index),
                   timestamp: timestamp &+ UInt32(index * codec.frameSamples),
                   codec: codec)
        }
    }

    private func rms(_ samples: ArraySlice<Int16>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    func testMatchingCodecPassesThroughUnchanged() {
        var adapter = InboundRateAdapter(localRate: .standard)
        XCTAssertNil(adapter.lastIncomingCodec)
        let input = packet(sequence: 9, timestamp: 12_345, codec: .pcm16Mono16k)
        XCTAssertEqual(adapter.adapt(input), input, "same codec: the packet must come back as is")
        XCTAssertEqual(adapter.lastIncomingCodec, .pcm16Mono16k)
        XCTAssertEqual(adapter.localRate, .standard)
    }

    func testResamplesSixteenToTwentyFourKilohertz() {
        var adapter = InboundRateAdapter(localRate: .high)
        let output = adapter.adapt(packet(sequence: 4, timestamp: 32_000, codec: .pcm16Mono16k))
        XCTAssertEqual(output.sequence, 4)
        XCTAssertEqual(output.timestamp, 48_000, "timestamps are scaled to the local sample clock")
        XCTAssertEqual(output.codec, .pcm16Mono24k)
        XCTAssertEqual(output.samples.count, 480)
        XCTAssertEqual(adapter.lastIncomingCodec, .pcm16Mono16k)
    }

    func testNarrowToHighestGivesAWholeFrame() {
        var adapter = InboundRateAdapter(localRate: .highest)
        let output = adapter.adapt(packet(sequence: 0, timestamp: 800, codec: .pcm16Mono8k))
        XCTAssertEqual(output.samples.count, 640)
        XCTAssertEqual(output.codec, .pcm16Mono32k)
        XCTAssertEqual(output.timestamp, 3_200)
    }

    func testConsecutiveFramesStayExactlyOneLocalFrameApart() {
        var adapter = InboundRateAdapter(localRate: .high)
        let outputs = stream(count: 10, sequence: 100, timestamp: 7_777, codec: .pcm16Mono16k).map { adapter.adapt($0) }
        for index in 1..<outputs.count {
            XCTAssertEqual(outputs[index].timestamp &- outputs[index - 1].timestamp, 480,
                           "frame \(index): the estimator must see the sender's clock advance one local frame")
            XCTAssertEqual(outputs[index].samples.count, 480)
        }
    }

    func testTimestampWrapKeepsFrameSpacing() {
        var adapter = InboundRateAdapter(localRate: .high)
        let start = UInt32.max - 700
        let outputs = stream(count: 10, timestamp: start, codec: .pcm16Mono16k).map { adapter.adapt($0) }
        for index in 1..<outputs.count {
            XCTAssertEqual(outputs[index].timestamp &- outputs[index - 1].timestamp, 480,
                           "frame \(index) across the 32-bit wrap")
        }
        XCTAssertEqual(outputs[0].timestamp, UInt32(truncatingIfNeeded: Int64(start) * 3 / 2),
                       "the anchor is the scaled first timestamp, wrapped to 32 bits")
    }

    func testDownsampledTimestampsStayExactAcrossTheWrap() {
        var adapter = InboundRateAdapter(localRate: .narrow)
        let outputs = stream(count: 8, timestamp: UInt32.max - 1_000, codec: .pcm16Mono32k).map { adapter.adapt($0) }
        for index in 1..<outputs.count {
            XCTAssertEqual(outputs[index].timestamp &- outputs[index - 1].timestamp, 160, "frame \(index)")
            XCTAssertEqual(outputs[index].samples.count, 160)
        }
    }

    func testCodecSwitchRebuildsTheResampler() {
        var adapter = InboundRateAdapter(localRate: .standard)
        for output in stream(count: 3, codec: .pcm16Mono8k).map({ adapter.adapt($0) }) {
            XCTAssertEqual(output.samples.count, 320)
        }
        let switched = adapter.adapt(packet(sequence: 3, timestamp: 90_000, codec: .pcm16Mono32k))
        XCTAssertEqual(switched.samples.count, 320, "the output length follows the new codec")
        XCTAssertEqual(switched.codec, .pcm16Mono16k)
        XCTAssertEqual(switched.timestamp, 45_000, "the anchor moves to the first packet of the new codec")
        XCTAssertEqual(adapter.lastIncomingCodec, .pcm16Mono32k)
        let next = adapter.adapt(packet(sequence: 4, timestamp: 90_640, codec: .pcm16Mono32k))
        XCTAssertEqual(next.timestamp &- switched.timestamp, 320)
    }

    func testSwitchingToTheLocalCodecAndBackStillResamples() {
        var adapter = InboundRateAdapter(localRate: .standard)
        XCTAssertEqual(adapter.adapt(packet(sequence: 0, timestamp: 0, codec: .pcm16Mono24k)).samples.count, 320)
        let native = packet(sequence: 1, timestamp: 480, codec: .pcm16Mono16k)
        XCTAssertEqual(adapter.adapt(native), native)
        XCTAssertEqual(adapter.adapt(packet(sequence: 2, timestamp: 960, codec: .pcm16Mono24k)).samples.count, 320)
    }

    func testSequenceGapKeepsTheOutputLengthAndClock() {
        var adapter = InboundRateAdapter(localRate: .high)
        let before = adapter.adapt(packet(sequence: 10, timestamp: 3_200, codec: .pcm16Mono16k))
        // Sequence 11 is lost; its frame of sample clock still elapsed.
        let after = adapter.adapt(packet(sequence: 12, timestamp: 3_840, codec: .pcm16Mono16k))
        XCTAssertEqual(after.samples.count, 480)
        XCTAssertEqual(after.timestamp &- before.timestamp, 960, "two local frames elapsed")
    }

    func testSequenceGapRestartsTheFilterFromSilence() {
        var adapter = InboundRateAdapter(localRate: .high)
        _ = adapter.adapt(packet(sequence: 0, timestamp: 0, codec: .pcm16Mono16k, value: 20_000))
        var fresh = InboundRateAdapter(localRate: .high)
        let expected = fresh.adapt(packet(sequence: 0, timestamp: 0, codec: .pcm16Mono16k, value: 0))
        let gapped = adapter.adapt(packet(sequence: 2, timestamp: 640, codec: .pcm16Mono16k, value: 0))
        XCTAssertEqual(gapped.samples, expected.samples,
                       "after a gap the filter must not ring with the tail of an unrelated frame")
    }

    func testReorderedPacketKeepsItsPlaceOnTheClock() {
        var adapter = InboundRateAdapter(localRate: .high)
        let first = adapter.adapt(packet(sequence: 0, timestamp: 1_000, codec: .pcm16Mono16k))
        let third = adapter.adapt(packet(sequence: 2, timestamp: 1_640, codec: .pcm16Mono16k))
        let second = adapter.adapt(packet(sequence: 1, timestamp: 1_320, codec: .pcm16Mono16k))
        XCTAssertEqual(second.timestamp &- first.timestamp, 480)
        XCTAssertEqual(third.timestamp &- second.timestamp, 480)
        XCTAssertEqual(second.samples.count, 480)
    }

    func testSetLocalRateChangesTheOutput() {
        var adapter = InboundRateAdapter(localRate: .standard)
        XCTAssertEqual(adapter.adapt(packet(sequence: 0, timestamp: 0, codec: .pcm16Mono8k)).samples.count, 320)
        adapter.setLocalRate(.highest)
        XCTAssertEqual(adapter.localRate, .highest)
        XCTAssertNil(adapter.lastIncomingCodec, "a rate change forgets the stream")
        let output = adapter.adapt(packet(sequence: 1, timestamp: 160, codec: .pcm16Mono8k))
        XCTAssertEqual(output.samples.count, 640)
        XCTAssertEqual(output.codec, .pcm16Mono32k)
        let native = packet(sequence: 2, timestamp: 320, codec: .pcm16Mono32k)
        XCTAssertEqual(adapter.adapt(native), native)
    }

    func testResetForgetsTheStream() {
        var adapter = InboundRateAdapter(localRate: .high)
        _ = adapter.adapt(packet(sequence: 0, timestamp: 0, codec: .pcm16Mono16k))
        adapter.reset()
        XCTAssertNil(adapter.lastIncomingCodec)
        XCTAssertEqual(adapter.localRate, .high)
        XCTAssertEqual(adapter.adapt(packet(sequence: 1, timestamp: 320, codec: .pcm16Mono16k)).timestamp, 480)
    }

    func testSineLevelSurvivesAdaptation() {
        var adapter = InboundRateAdapter(localRate: .highest)
        var output: [Int16] = []
        var inputPower = 0.0
        for index in 0..<10 {
            let samples: [Int16] = (0..<320).map { sample in
                let phase = 2 * Double.pi * 1_000 * Double(index * 320 + sample) / 16_000
                return Int16((16_384 * sin(phase)).rounded())
            }
            if index >= 2 { inputPower += samples.reduce(0.0) { $0 + Double($1) * Double($1) } }
            let adapted = adapter.adapt(AudioPacket(sequence: UInt16(index), timestamp: UInt32(index * 320),
                                                    codec: .pcm16Mono16k, samples: samples))
            XCTAssertEqual(adapted.samples.count, 640)
            output += adapted.samples
        }
        let inputRMS = (inputPower / Double(8 * 320)).squareRoot()
        let steady = output[1_280...]
        let level = 20 * log10(rms(steady) / inputRMS)
        XCTAssertEqual(level, 0, accuracy: 0.5, "a 1 kHz tone keeps its level after 16 → 32 kHz")
    }

    func testOddAndEmptyPacketsNeverCrash() {
        var adapter = InboundRateAdapter(localRate: .high)
        let empty = adapter.adapt(AudioPacket(sequence: 0, timestamp: 0, codec: .pcm16Mono16k, samples: []))
        XCTAssertEqual(empty.samples, [])
        XCTAssertEqual(empty.codec, .pcm16Mono24k)
        let odd = adapter.adapt(AudioPacket(sequence: 1, timestamp: 0, codec: .pcm16Mono16k,
                                            samples: [Int16](repeating: 100, count: 7)))
        XCTAssertEqual(odd.samples.count, 11, "7 samples at 16 kHz cover 10.5 output samples")
        let half = adapter.adapt(AudioPacket(sequence: 2, timestamp: 7, codec: .pcm16Mono16k,
                                             samples: [Int16](repeating: 100, count: 160)))
        XCTAssertEqual(half.samples.count, 240)
        XCTAssertEqual(half.timestamp, 10, "timestamps that are not whole frames scale in the floor direction")
        let whole = adapter.adapt(AudioPacket(sequence: 3, timestamp: 167, codec: .pcm16Mono16k,
                                              samples: [Int16](repeating: 100, count: 320)))
        XCTAssertEqual(whole.samples.count, 480, "whole frames stay whole once the phase realigns")
    }
}
