import Foundation
import XCTest
@testable import IntercomCore

final class ResamplerTests: XCTestCase {
    private let rates = [8_000, 16_000, 24_000, 32_000]

    /// Every ordered pair of distinct wire rates.
    private var conversions: [(input: Int, output: Int)] {
        rates.flatMap { input in rates.compactMap { output in input == output ? nil : (input, output) } }
    }

    private func frame(rate: Int) -> Int { rate / IntercomProtocol.framesPerSecond }

    private func randomFrame(count: Int, using rng: inout SplitMix64) -> [Int16] {
        (0..<count).map { _ in Int16.random(in: -20_000...20_000, using: &rng) }
    }

    private func sine(frequency: Double, rate: Int, count: Int, amplitude: Double, startIndex: Int = 0) -> [Int16] {
        (0..<count).map { index in
            let phase = 2 * Double.pi * frequency * Double(startIndex + index) / Double(rate)
            return Int16((amplitude * sin(phase)).rounded())
        }
    }

    private func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return power.squareRoot()
    }

    private func decibels(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

    /// Least-squares fit of `samples` to a sine of `frequency`, whatever its delay: returns the
    /// fitted amplitude and the residual power relative to the fitted signal power in dB.
    private func fitSine(_ samples: [Int16], frequency: Double, rate: Int) -> (amplitude: Double, residualDB: Double) {
        var ss = 0.0, cc = 0.0, sc = 0.0, ys = 0.0, yc = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / Double(rate)
            let s = sin(phase), c = cos(phase), y = Double(sample)
            ss += s * s; cc += c * c; sc += s * c; ys += y * s; yc += y * c
        }
        let determinant = ss * cc - sc * sc
        let a = (ys * cc - yc * sc) / determinant
        let b = (yc * ss - ys * sc) / determinant
        var residual = 0.0, signal = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / Double(rate)
            let fit = a * sin(phase) + b * cos(phase)
            residual += (Double(sample) - fit) * (Double(sample) - fit)
            signal += fit * fit
        }
        return ((a * a + b * b).squareRoot(), 10 * log10(max(residual, 1e-12) / signal))
    }

    // MARK: - Ratios and lengths

    func testRatiosAreReducedAndSmall() {
        XCTAssertEqual(Resampler(inputRate: 16_000, outputRate: 24_000).ratio.interpolation, 3)
        XCTAssertEqual(Resampler(inputRate: 16_000, outputRate: 24_000).ratio.decimation, 2)
        XCTAssertEqual(Resampler(inputRate: 8_000, outputRate: 32_000).ratio.interpolation, 4)
        XCTAssertEqual(Resampler(inputRate: 8_000, outputRate: 32_000).ratio.decimation, 1)
        XCTAssertEqual(Resampler(inputRate: 32_000, outputRate: 24_000).ratio.interpolation, 3)
        XCTAssertEqual(Resampler(inputRate: 32_000, outputRate: 24_000).ratio.decimation, 4)
        XCTAssertEqual(Resampler(inputRate: 16_000, outputRate: 16_000).ratio.interpolation, 1)
        XCTAssertEqual(Resampler(inputRate: 16_000, outputRate: 16_000).ratio.decimation, 1)
        for conversion in conversions {
            let resampler = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            XCTAssertLessThanOrEqual(max(resampler.ratio.interpolation, resampler.ratio.decimation), 4,
                                     "\(conversion) needs a polyphase factor above 4")
            XCTAssertGreaterThan(resampler.groupDelay, 0.0004, "\(conversion) delay")
            XCTAssertLessThan(resampler.groupDelay, 0.0016, "\(conversion) delay")
        }
    }

    func testWholeFramesGiveExactOutputFramesForEveryPair() {
        var rng = SplitMix64(seed: 1)
        for conversion in conversions {
            var resampler = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            let expected = frame(rate: conversion.output)
            let input = randomFrame(count: frame(rate: conversion.input), using: &rng)
            for index in 0..<100 {
                let output = resampler.process(input)
                XCTAssertEqual(output.count, expected, "\(conversion) frame \(index)")
                XCTAssertEqual(resampler.outputCount(forInputCount: frame(rate: conversion.input)), expected,
                               "\(conversion): the phase must be back at 0 after frame \(index)")
            }
        }
    }

    func testOutputCountMatchesSamplesWrittenForOddLengths() {
        for conversion in conversions {
            var resampler = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            var totalIn = 0, totalOut = 0
            for length in [7, 13, 1, 320, 0, 2, 159, 5] {
                let input = [Float](repeating: 0.25, count: length)
                let expected = resampler.outputCount(forInputCount: length)
                var output = [Float](repeating: .nan, count: expected + 8)
                let written = input.withUnsafeBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { resampler.process(source, into: $0) }
                }
                XCTAssertEqual(written, expected, "\(conversion) input length \(length)")
                XCTAssertTrue(output[expected...].allSatisfy(\.isNaN), "\(conversion): wrote past outputCount")
                totalIn += length
                totalOut += written
            }
            let l = resampler.ratio.interpolation, m = resampler.ratio.decimation
            XCTAssertEqual(totalOut, (totalIn * l + m - 1) / m, "\(conversion): streaming total")
        }
    }

    func testEmptyInputYieldsEmptyOutput() {
        var resampler = Resampler(inputRate: 16_000, outputRate: 24_000)
        XCTAssertEqual(resampler.process([Int16]()), [])
        XCTAssertEqual(resampler.process([Int16](repeating: 0, count: 320)).count, 480, "still aligned")
    }

    // MARK: - Streaming continuity

    func testSeamsAreContinuous() {
        var rng = SplitMix64(seed: 7)
        for conversion in conversions {
            let a = randomFrame(count: frame(rate: conversion.input), using: &rng)
            let b = randomFrame(count: frame(rate: conversion.input), using: &rng)
            var streaming = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            let pieces = streaming.process(a) + streaming.process(b)
            var whole = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            let joined = whole.process(a + b)
            XCTAssertEqual(pieces.count, joined.count, "\(conversion)")
            for index in 0..<min(pieces.count, joined.count) {
                XCTAssertLessThanOrEqual(abs(Int(pieces[index]) - Int(joined[index])), 1,
                                         "\(conversion) sample \(index) differs across the seam")
            }
        }
    }

    func testSeamsAreContinuousForOddSplits() {
        var rng = SplitMix64(seed: 11)
        for conversion in conversions {
            let input = randomFrame(count: 500, using: &rng)
            var streaming = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            var pieces: [Int16] = []
            for range in [0..<7, 7..<20, 20..<21, 21..<341, 341..<500] {
                pieces += streaming.process(Array(input[range]))
            }
            var whole = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            let joined = whole.process(input)
            XCTAssertEqual(pieces.count, joined.count, "\(conversion)")
            for index in 0..<min(pieces.count, joined.count) {
                XCTAssertLessThanOrEqual(abs(Int(pieces[index]) - Int(joined[index])), 1,
                                         "\(conversion) sample \(index) differs across a seam")
            }
        }
    }

    func testResetMatchesAFreshResampler() {
        var rng = SplitMix64(seed: 3)
        let warmup = randomFrame(count: 320, using: &rng)
        let frame = randomFrame(count: 320, using: &rng)
        var reused = Resampler(inputRate: 16_000, outputRate: 24_000)
        _ = reused.process(warmup)
        _ = reused.process(Array(warmup.prefix(13)))
        reused.reset()
        var fresh = Resampler(inputRate: 16_000, outputRate: 24_000)
        XCTAssertEqual(reused.process(frame), fresh.process(frame), "reset must clear history and phase")
    }

    // MARK: - Signal quality

    func testIdentityPairIsAnExactCopy() {
        var rng = SplitMix64(seed: 5)
        var resampler = Resampler(inputRate: 16_000, outputRate: 16_000)
        let frame = randomFrame(count: 320, using: &rng)
        XCTAssertEqual(resampler.process(frame), frame)
        XCTAssertEqual(resampler.groupDelay, 0)
        let floats = frame.map(Float.init)
        var output = [Float](repeating: 0, count: 320)
        let written = floats.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { resampler.process(source, into: $0) }
        }
        XCTAssertEqual(written, 320)
        XCTAssertEqual(output, floats)
    }

    func testDCPassesWithoutRipple() {
        for conversion in conversions {
            var resampler = Resampler(inputRate: conversion.input, outputRate: conversion.output)
            let input = [Int16](repeating: 10_000, count: frame(rate: conversion.input) * 4)
            let output = resampler.process(input)
            // The filter has settled once tapsPerPhase inputs have been seen.
            let settled = resampler.tapsPerPhase * resampler.ratio.interpolation / resampler.ratio.decimation + 1
            for sample in output[settled...] {
                XCTAssertEqual(Double(sample), 10_000, accuracy: 50, "\(conversion) DC gain")
            }
        }
    }

    func testRoundTripKeepsAOneKilohertzSine() {
        for (low, high) in [(16_000, 24_000), (16_000, 32_000), (8_000, 32_000)] {
            var up = Resampler(inputRate: low, outputRate: high)
            var down = Resampler(inputRate: high, outputRate: low)
            let frames = 20
            let count = frame(rate: low) * frames
            let input = sine(frequency: 1_000, rate: low, count: count, amplitude: 16_384)
            var output: [Int16] = []
            for index in 0..<frames {
                let piece = Array(input[index * frame(rate: low)..<(index + 1) * frame(rate: low)])
                output += down.process(up.process(piece))
            }
            XCTAssertEqual(output.count, count)
            // Skip the start-up transient (two group delays, well under one frame).
            let skip = frame(rate: low) * 2
            let steady = Array(output[skip...])
            let fit = fitSine(steady, frequency: 1_000, rate: low)
            XCTAssertLessThan(fit.residualDB, -45, "\(low) → \(high) → \(low): residual")
            XCTAssertEqual(decibels(fit.amplitude / 16_384), 0, accuracy: 0.1, "\(low) → \(high) → \(low): level")
            let inputRMS = rms(Array(input[skip...]))
            XCTAssertEqual(decibels(rms(steady) / inputRMS), 0, accuracy: 0.1, "\(low) → \(high) → \(low): RMS")
        }
    }

    func testDecimationRejectsTonesAboveTheNewNyquist() {
        for (input, output, tone) in [(16_000, 8_000, 7_000.0), (32_000, 16_000, 15_000.0)] {
            var resampler = Resampler(inputRate: input, outputRate: output)
            let count = frame(rate: input) * 10
            let signal = sine(frequency: tone, rate: input, count: count, amplitude: 16_384)
            let result = resampler.process(signal)
            let skip = frame(rate: output) * 2
            let steady = Array(result[skip...])
            let attenuation = decibels(rms(steady) / rms(signal))
            XCTAssertLessThan(attenuation, -40, "\(tone) Hz must not alias into the \(output) Hz output")
        }
    }

    func testInterpolationDoesNotAddImages() {
        // A 1 kHz tone at 8 kHz interpolated to 32 kHz must come out as a clean 1 kHz tone: the
        // images at 7, 9, 15, 17 kHz... are what the low-pass removes.
        var resampler = Resampler(inputRate: 8_000, outputRate: 32_000)
        let signal = sine(frequency: 1_000, rate: 8_000, count: 160 * 10, amplitude: 16_384)
        let result = resampler.process(signal)
        let fit = fitSine(Array(result[1_280...]), frequency: 1_000, rate: 32_000)
        XCTAssertLessThan(fit.residualDB, -45)
        XCTAssertEqual(decibels(fit.amplitude / 16_384), 0, accuracy: 0.1)
    }

    func testOutputIsClampedToInt16() {
        // Full-scale square edges overshoot after band limiting (Gibbs); the Int16 path must clamp.
        var resampler = Resampler(inputRate: 8_000, outputRate: 32_000)
        let square: [Int16] = (0..<160 * 4).map { ($0 / 40) % 2 == 0 ? Int16.max : Int16.min }
        let output = resampler.process(square)
        XCTAssertEqual(output.count, 640 * 4)
        XCTAssertTrue(output.contains(Int16.max) || output.contains(Int16.min), "the edges reach full scale")
    }

    func testBesselI0MatchesKnownValues() {
        XCTAssertEqual(Resampler.besselI0(0), 1, accuracy: 1e-12)
        XCTAssertEqual(Resampler.besselI0(1), 1.2660658777520084, accuracy: 1e-12)
        XCTAssertEqual(Resampler.besselI0(8), 427.56411572180474, accuracy: 1e-9)
    }
}
