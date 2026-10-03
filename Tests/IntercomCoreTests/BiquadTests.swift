import Foundation
import XCTest
@testable import IntercomCore

/// Fixtures shared by the filter and preset tests.
enum FilterTestSupport {
    /// The four wire rates plus the two hardware rates a route may run at.
    static let sampleRates: [Double] = [8_000, 16_000, 24_000, 32_000, 44_100, 48_000]

    /// Deterministic white noise in `-1 ... 1`.
    static func noise(count: Int, seed: UInt64 = 1) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in Float.random(in: -1...1, using: &rng) }
    }

    /// Gain of `bands` in series at `hz`: the sum of the sections' gains in dB.
    static func magnitudeDB(_ bands: [Biquad.Kind], hz: Double, sampleRate: Double) -> Double {
        bands.reduce(0) { total, band in
            let coefficients = Biquad.coefficients(band, sampleRate: sampleRate)
            return total + Biquad.magnitudeDB(coefficients, hz: hz, sampleRate: sampleRate)
        }
    }

    /// Response of `chain` (in whatever state it is) to a unit impulse followed by silence.
    static func impulseResponse(_ chain: inout BiquadChain, length: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: length)
        samples[0] = 1
        chain.process(&samples)
        return samples
    }
}

final class BiquadTests: XCTestCase {
    private let rates = FilterTestSupport.sampleRates

    /// Two designs of every `Kind`, spanning the parameter ranges the presets use.
    private let kinds: [Biquad.Kind] = [
        .peaking(hz: 1_500, q: 1, gainDB: 4),
        .peaking(hz: 1_000, q: 0.8, gainDB: -2),
        .lowShelf(hz: 200, slope: 1, gainDB: 6),
        .lowShelf(hz: 150, slope: 0.5, gainDB: -5),
        .highShelf(hz: 3_000, slope: 1, gainDB: -2),
        .highShelf(hz: 5_000, slope: 1, gainDB: 6),
        .highPass(hz: 120, q: 0.707),
        .highPass(hz: 300, q: 0.9),
        .lowPass(hz: 3_400, q: 0.9),
        .lowPass(hz: 1_000, q: 0.707),
    ]

    private func filtered(_ input: [Float], _ c: Biquad.Coefficients) -> [Float] {
        var state = Biquad.State()
        return input.map { Biquad.process($0, c, &state) }
    }

    // MARK: Design

    func testEveryKindIsStableAndFiniteAtEveryRate() {
        for kind in kinds {
            for rate in rates {
                let c = Biquad.coefficients(kind, sampleRate: rate)
                XCTAssertTrue(Biquad.isStable(c), "\(kind) at \(rate) Hz must be stable and finite: \(c)")
            }
        }
    }

    func testIdentityIsABitIdenticalPassthrough() {
        let input = FilterTestSupport.noise(count: 1_000)
        let output = filtered(input, Biquad.identity)
        XCTAssertEqual(output.map(\.bitPattern), input.map(\.bitPattern),
                       "identity must not touch a single bit")
    }

    func testZeroGainPeakingIsIdentityWithinRoundoff() {
        let input = FilterTestSupport.noise(count: 1_000)
        let c = Biquad.coefficients(.peaking(hz: 1_000, q: 1, gainDB: 0), sampleRate: 16_000)
        let output = filtered(input, c)
        let error = zip(output, input).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(error, 1e-4, "a 0 dB bell is a wire")
    }

    func testTransposedFormMatchesTheDifferenceEquation() {
        let input = FilterTestSupport.noise(count: 2_000, seed: 7)
        let c = Biquad.coefficients(.peaking(hz: 1_500, q: 1, gainDB: 6), sampleRate: 16_000)
        var state = Biquad.State()
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var error = 0.0
        for x in input {
            let y = Double(Biquad.process(x, c, &state))
            let xd = Double(x)
            let reference = Double(c.b0) * xd + Double(c.b1) * x1 + Double(c.b2) * x2
                - Double(c.a1) * y1 - Double(c.a2) * y2
            error = max(error, abs(y - reference))
            x2 = x1
            x1 = xd
            y2 = y1
            y1 = reference
        }
        XCTAssertLessThan(error, 1e-4, "TDF-II must compute the same filter as the direct form")
    }

    func testDCSettlesToUnityThroughALowPass() {
        let c = Biquad.coefficients(.lowPass(hz: 1_000, q: 0.707), sampleRate: 16_000)
        var state = Biquad.State()
        var y: Float = 0
        for _ in 0..<2_000 { y = Biquad.process(1, c, &state) }
        XCTAssertEqual(y, 1, accuracy: 0.01, "a low-pass has unity gain at DC")
    }

    func testHighPassMagnitudeAtSixteenKilohertz() {
        let c = Biquad.coefficients(.highPass(hz: 120, q: 0.707), sampleRate: 16_000)
        XCTAssertLessThan(Biquad.magnitudeDB(c, hz: 50, sampleRate: 16_000), -6, "rumble is cut")
        XCTAssertGreaterThan(Biquad.magnitudeDB(c, hz: 2_000, sampleRate: 16_000), -0.5, "speech passes")
    }

    func testLowShelfMagnitudeAtFortyEightKilohertz() {
        let c = Biquad.coefficients(.lowShelf(hz: 200, slope: 1, gainDB: 6), sampleRate: 48_000)
        XCTAssertEqual(Biquad.magnitudeDB(c, hz: 10, sampleRate: 48_000), 6, accuracy: 0.5,
                       "the shelf reaches its full gain far below the corner")
        XCTAssertEqual(Biquad.magnitudeDB(c, hz: 4_000, sampleRate: 48_000), 0, accuracy: 0.5,
                       "the shelf is flat far above the corner")
    }

    func testMagnitudeOfIdentityIsZeroDecibels() {
        for hz in [0.0, 100, 1_000, 7_999] {
            XCTAssertEqual(Biquad.magnitudeDB(Biquad.identity, hz: hz, sampleRate: 16_000), 0, accuracy: 1e-9)
        }
    }

    func testFrequencyAboveNyquistIsClampedAndStable() {
        let designs: [Biquad.Kind] = [
            .peaking(hz: 20_000, q: 1, gainDB: 6),
            .lowShelf(hz: 1e9, slope: 1, gainDB: 6),
            .highShelf(hz: 12_000, slope: 1, gainDB: -6),
            .highPass(hz: .infinity, q: 0.707),
            .lowPass(hz: 8_000, q: 0.707),
        ]
        for kind in designs {
            let c = Biquad.coefficients(kind, sampleRate: 16_000)
            XCTAssertTrue(Biquad.isStable(c), "\(kind) must clamp to the band, not blow up: \(c)")
        }
        let clamped = Biquad.coefficients(.peaking(hz: 20_000, q: 1, gainDB: 6), sampleRate: 16_000)
        let atLimit = Biquad.coefficients(.peaking(hz: 0.45 * 16_000, q: 1, gainDB: 6), sampleRate: 16_000)
        XCTAssertEqual(clamped, atLimit, "the clamp lands exactly on maxFrequencyFraction")
    }

    func testDegenerateParametersFallBackSafely() {
        let designs: [Biquad.Kind] = [
            .peaking(hz: .nan, q: .nan, gainDB: .nan),
            .peaking(hz: -5, q: 0, gainDB: 500),
            .lowShelf(hz: 0, slope: 0, gainDB: -.infinity),
            .highShelf(hz: 1_000, slope: 40, gainDB: 30),
            .highPass(hz: 1, q: -1),
            .lowPass(hz: 100, q: .infinity),
        ]
        for kind in designs {
            let c = Biquad.coefficients(kind, sampleRate: 16_000)
            XCTAssertTrue(Biquad.isStable(c), "\(kind) must yield a usable filter: \(c)")
        }
        XCTAssertEqual(Biquad.coefficients(.peaking(hz: 1_000, q: 1, gainDB: 6), sampleRate: 0),
                       Biquad.identity, "no sample rate, no design")
        XCTAssertEqual(Biquad.coefficients(.peaking(hz: 1_000, q: 1, gainDB: 6), sampleRate: .nan),
                       Biquad.identity)
    }

    func testStabilityCheckRejectsPolesOutsideTheUnitCircle() {
        XCTAssertFalse(Biquad.isStable(Biquad.Coefficients(b0: 1, b1: 0, b2: 0, a1: -2.1, a2: 1.1)))
        XCTAssertFalse(Biquad.isStable(Biquad.Coefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: -1)))
        XCTAssertFalse(Biquad.isStable(Biquad.Coefficients(b0: .nan, b1: 0, b2: 0, a1: 0, a2: 0)))
        XCTAssertTrue(Biquad.isStable(Biquad.identity))
        XCTAssertTrue(Biquad.isStable(Biquad.Coefficients(b0: 1, b1: 0, b2: 0, a1: -1.8, a2: 0.81)))
    }

    // MARK: Chain

    func testChainKeepsAtMostMaxBands() {
        let six = Array(kinds.prefix(6))
        let chain = BiquadChain(bands: six, sampleRate: 16_000)
        XCTAssertEqual(chain.count, BiquadChain.maxBands)
        XCTAssertEqual(chain.coefficients.count, BiquadChain.maxBands)
        XCTAssertEqual(chain.coefficients, six.prefix(BiquadChain.maxBands).map {
            Biquad.coefficients($0, sampleRate: 16_000)
        }, "the first bands win")
        XCTAssertEqual(BiquadChain(bands: [], sampleRate: 16_000).count, 0)
        XCTAssertEqual(BiquadChain(bands: [kinds[0]], sampleRate: 16_000).count, 1)
    }

    func testEmptyChainIsABitIdenticalPassthrough() {
        var chain = BiquadChain(bands: [], sampleRate: 16_000)
        XCTAssertTrue(chain.isEmpty)
        let input = FilterTestSupport.noise(count: 640)
        var samples = input
        chain.process(&samples)
        XCTAssertEqual(samples.map(\.bitPattern), input.map(\.bitPattern))
        samples.withUnsafeMutableBufferPointer { chain.process($0) }
        XCTAssertEqual(samples.map(\.bitPattern), input.map(\.bitPattern))
    }

    func testResetRepeatsTheImpulseResponseExactly() {
        // 64 samples: the low shelf is still ringing at the end, so a second impulse without a reset
        // sits on that tail and must differ.
        var chain = BiquadChain(bands: Array(kinds.prefix(3)), sampleRate: 16_000)
        let first = FilterTestSupport.impulseResponse(&chain, length: 64)
        let continued = FilterTestSupport.impulseResponse(&chain, length: 64)
        XCTAssertNotEqual(continued, first, "without a reset the tail of the first impulse is still ringing")
        chain.reset()
        let afterReset = FilterTestSupport.impulseResponse(&chain, length: 64)
        XCTAssertEqual(afterReset.map(\.bitPattern), first.map(\.bitPattern), "reset returns to silence")
    }

    func testChainEqualsTheSectionsAppliedOneAfterAnother() {
        let bands = Array(kinds.prefix(4))
        var chain = BiquadChain(bands: bands, sampleRate: 16_000)
        var samples = FilterTestSupport.noise(count: 800, seed: 3)
        var reference = samples
        chain.process(&samples)
        for band in bands {
            reference = filtered(reference, Biquad.coefficients(band, sampleRate: 16_000))
        }
        XCTAssertEqual(samples.map(\.bitPattern), reference.map(\.bitPattern),
                       "band-by-band over the buffer is the same arithmetic as section after section")
    }

    func testChainStateCarriesAcrossBuffers() {
        var whole = BiquadChain(bands: Array(kinds.prefix(2)), sampleRate: 16_000)
        var split = whole
        let input = FilterTestSupport.noise(count: 640, seed: 9)
        var expected = input
        whole.process(&expected)
        var head = Array(input[..<320])
        var tail = Array(input[320...])
        split.process(&head)
        split.process(&tail)
        XCTAssertEqual((head + tail).map(\.bitPattern), expected.map(\.bitPattern),
                       "a stream cut into frames must filter like the whole")
    }
}
