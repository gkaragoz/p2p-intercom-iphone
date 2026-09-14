import Foundation
import XCTest
@testable import IntercomCore

final class CueToneTests: XCTestCase {
    private let rate = 16_000

    /// Start and end sample offsets of every note of `cue`.
    private func noteRanges(_ cue: CueTone) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var position = 0
        for (index, note) in cue.notes.enumerated() {
            let length = note.durationMs * rate / 1000
            ranges.append(position..<(position + length))
            position += length
            if index < cue.notes.count - 1 {
                position += note.gapMs * rate / 1000
            }
        }
        return ranges
    }

    /// Frequency estimated from upward zero crossings, which is exact enough to tell notes apart.
    private func estimatedFrequency(_ samples: ArraySlice<Int16>) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for sample in samples.dropFirst() {
            if previous < 0, sample >= 0 { crossings += 1 }
            previous = sample
        }
        return Double(crossings) * Double(rate) / Double(samples.count)
    }

    func testLengthsMatchTheDeclaredDurations() {
        for cue in CueTone.allCases {
            let samples = cue.synthesize(sampleRate: rate)
            XCTAssertEqual(samples.count, cue.sampleCount(sampleRate: rate), "\(cue)")
            XCTAssertEqual(samples.count, cue.durationMs * rate / 1000, "\(cue)")
            XCTAssertGreaterThan(cue.durationMs, 0)
            XCTAssertLessThanOrEqual(cue.durationMs, 400, "\(cue) is a short cue, not a jingle")
            XCTAssertEqual(cue.synthesize(sampleRate: 48_000).count, cue.sampleCount(sampleRate: 48_000))
        }
        XCTAssertEqual(CueTone.connected.durationMs, 270)
        XCTAssertEqual(CueTone.lost.durationMs, 320)
    }

    func testEveryNoteFadesInAndOutOverFiveMilliseconds() {
        let fade = CueTone.fadeMs * rate / 1000
        let amplitude: Float = 0.5
        let peak = Double(amplitude) * Double(Int16.max)
        for cue in CueTone.allCases {
            let samples = cue.synthesize(sampleRate: rate, amplitude: amplitude)
            for range in noteRanges(cue) {
                XCTAssertEqual(samples[range.lowerBound], 0, "\(cue) starts at zero")
                XCTAssertLessThanOrEqual(abs(Int(samples[range.upperBound - 1])), 3, "\(cue) ends at zero")
                // Inside the fades the envelope bounds every sample; it reaches full level only after.
                for offset in 0..<fade {
                    let envelope = 0.5 - 0.5 * cos(Double.pi * Double(offset) / Double(fade))
                    XCTAssertLessThanOrEqual(abs(Double(samples[range.lowerBound + offset])), envelope * peak + 1)
                    XCTAssertLessThanOrEqual(abs(Double(samples[range.upperBound - 1 - offset])), envelope * peak + 1)
                }
                let body = samples[(range.lowerBound + fade)..<(range.upperBound - fade)]
                let loudest = body.map { abs(Int($0)) }.max() ?? 0
                XCTAssertEqual(Double(loudest), peak, accuracy: peak * 0.02, "\(cue) reaches its peak level")
                // Consecutive samples never jump, so no click anywhere in the note.
                let largestStep = zip(samples[range], samples[range].dropFirst()).map { abs(Int($1) - Int($0)) }.max() ?? 0
                XCTAssertLessThan(Double(largestStep), peak * 0.35)
            }
        }
    }

    func testGapsBetweenNotesAreTrueSilence() {
        for cue in CueTone.allCases {
            let samples = cue.synthesize(sampleRate: rate)
            let ranges = noteRanges(cue)
            for (earlier, later) in zip(ranges, ranges.dropFirst()) {
                XCTAssertTrue(samples[earlier.upperBound..<later.lowerBound].allSatisfy { $0 == 0 }, "\(cue)")
            }
        }
    }

    func testConnectedRisesAndLostFalls() {
        func pitches(_ cue: CueTone) -> [Double] {
            let samples = cue.synthesize(sampleRate: rate)
            return noteRanges(cue).map { estimatedFrequency(samples[$0]) }
        }
        let connected = pitches(.connected)
        XCTAssertEqual(connected.count, 2)
        XCTAssertLessThan(connected[0], connected[1])
        let lost = pitches(.lost)
        XCTAssertEqual(lost.count, 2)
        XCTAssertGreaterThan(lost[0], lost[1])
        let reconnected = pitches(.reconnected)
        XCTAssertEqual(reconnected, reconnected.sorted())
        XCTAssertNotEqual(CueTone.reconnected.notes, CueTone.connected.notes, "reconnected is distinguishable")
        for (cue, measured) in [(CueTone.connected, connected), (CueTone.lost, lost)] {
            for (note, frequency) in zip(cue.notes, measured) {
                XCTAssertEqual(frequency, note.frequency, accuracy: note.frequency * 0.05)
            }
        }
    }

    func testAmplitudeIsClampedAndSilentWhenZero() {
        XCTAssertTrue(CueTone.muted.synthesize(amplitude: 0).allSatisfy { $0 == 0 })
        let loud = CueTone.unmuted.synthesize(amplitude: 7)
        XCTAssertEqual(loud.map { abs(Int($0)) }.max(), Int(Int16.max))
        XCTAssertFalse(loud.contains(Int16.min), "no wrap-around")
        XCTAssertEqual(CueTone.connected.synthesize(sampleRate: 0).count, CueTone.connected.sampleCount(sampleRate: 1),
                       "a bogus rate is clamped, not a crash")
    }

    func testBankPrecomputesEveryCueContiguously() {
        let bank = CueToneBank()
        XCTAssertEqual(bank.sampleRate, 16_000)
        var expectedStart = 0
        for cue in CueTone.allCases {
            let range = bank.range(of: cue)
            XCTAssertEqual(range.lowerBound, expectedStart)
            XCTAssertEqual(Array(bank.samples(of: cue)), cue.synthesize(amplitude: CueToneBank.defaultAmplitude))
            expectedStart = range.upperBound
        }
        XCTAssertEqual(bank.samples.count, expectedStart)
        XCTAssertEqual(CueToneBank.standard.samples, bank.samples)
    }

    func testMixAddsScaledAndClamps() {
        let source: [Int16] = [16_384, -16_384, 32_767, -32_768, 8_192]
        var output: [Float] = [0, 0.25, 0.9, -0.9]
        let mixed = source.withUnsafeBufferPointer { sourceBuffer in
            output.withUnsafeMutableBufferPointer { CueToneBank.mix(sourceBuffer, into: $0, gain: 1) }
        }
        XCTAssertEqual(mixed, 4, "the shorter of the two")
        XCTAssertEqual(output[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(output[1], -0.25, accuracy: 1e-6)
        XCTAssertEqual(output[2], 1, "clamped")
        XCTAssertEqual(output[3], -1, "clamped")

        var quiet: [Float] = [0.1]
        _ = [Int16(16_384)].withUnsafeBufferPointer { sourceBuffer in
            quiet.withUnsafeMutableBufferPointer { CueToneBank.mix(sourceBuffer, into: $0, gain: 0.5) }
        }
        XCTAssertEqual(quiet[0], 0.35, accuracy: 1e-6)

        let empty = [Int16]().withUnsafeBufferPointer { sourceBuffer in
            quiet.withUnsafeMutableBufferPointer { CueToneBank.mix(sourceBuffer, into: $0) }
        }
        XCTAssertEqual(empty, 0)
    }
}
