import Foundation
import XCTest
@testable import IntercomCore

final class EQPresetTests: XCTestCase {
    private let rates = FilterTestSupport.sampleRates

    func testDefaultIsOff() {
        XCTAssertEqual(EQPreset.default, .off)
        XCTAssertEqual(EQPreset.off.index, 0)
    }

    func testOffHasNoBands() {
        for rate in rates {
            XCTAssertTrue(EQPreset.off.bands(sampleRate: rate).isEmpty, "off must skip the filter entirely")
            XCTAssertTrue(EQPreset.off.coefficients(sampleRate: rate).isEmpty)
            XCTAssertTrue(BiquadChain(bands: EQPreset.off.bands(sampleRate: rate), sampleRate: rate).isEmpty)
        }
    }

    func testEveryBandOfEveryPresetIsStableAtEveryRate() {
        for preset in EQPreset.allCases {
            for rate in rates {
                let bands = preset.bands(sampleRate: rate)
                let coefficients = preset.coefficients(sampleRate: rate)
                XCTAssertEqual(coefficients.count, bands.count, "\(preset) at \(rate) Hz")
                for (band, c) in zip(bands, coefficients) {
                    XCTAssertTrue(Biquad.isStable(c), "\(preset) \(band) at \(rate) Hz: \(c)")
                }
            }
        }
    }

    func testNoPresetExceedsTheChainCapacity() {
        for preset in EQPreset.allCases {
            for rate in rates {
                let bands = preset.bands(sampleRate: rate)
                XCTAssertLessThanOrEqual(bands.count, BiquadChain.maxBands, "\(preset) at \(rate) Hz")
                XCTAssertEqual(BiquadChain(bands: bands, sampleRate: rate).count, bands.count,
                               "every band of \(preset) must fit the chain")
            }
        }
    }

    func testEveryPresetHasBandsExceptOff() {
        for preset in EQPreset.allCases where preset != .off {
            for rate in rates {
                XCTAssertFalse(preset.bands(sampleRate: rate).isEmpty, "\(preset) at \(rate) Hz does something")
            }
        }
    }

    func testImpulseResponsesDecay() {
        let length = 8_192
        for preset in EQPreset.allCases {
            for rate in rates {
                var chain = BiquadChain(bands: preset.bands(sampleRate: rate), sampleRate: rate)
                let response = FilterTestSupport.impulseResponse(&chain, length: length)
                let energy = response.reduce(0.0) { $0 + Double($1) * Double($1) }
                let tail = response.suffix(length / 10).reduce(0.0) { $0 + Double($1) * Double($1) }
                XCTAssertTrue(energy.isFinite && energy > 0, "\(preset) at \(rate) Hz produced \(energy)")
                XCTAssertLessThan(tail, energy * 1e-6, "\(preset) at \(rate) Hz keeps ringing")
            }
        }
    }

    func testBassBoostLiftsTheLowEndAndLeavesTheMidsAlone() {
        let bands = EQPreset.bassBoost.bands(sampleRate: 16_000)
        XCTAssertEqual(FilterTestSupport.magnitudeDB(bands, hz: 60, sampleRate: 16_000), 6, accuracy: 1)
        XCTAssertEqual(FilterTestSupport.magnitudeDB(bands, hz: 2_000, sampleRate: 16_000), 0, accuracy: 1)
    }

    func testVoiceClearCutsRumbleAndLiftsPresence() {
        let bands = EQPreset.voiceClear.bands(sampleRate: 16_000)
        XCTAssertLessThan(FilterTestSupport.magnitudeDB(bands, hz: 50, sampleRate: 16_000), -6)
        XCTAssertEqual(FilterTestSupport.magnitudeDB(bands, hz: 2_500, sampleRate: 16_000), 4, accuracy: 1)
    }

    func testTelephoneRemovesBothEnds() {
        let bands = EQPreset.telephone.bands(sampleRate: 16_000)
        XCTAssertLessThan(FilterTestSupport.magnitudeDB(bands, hz: 100, sampleRate: 16_000), -10)
        XCTAssertLessThan(FilterTestSupport.magnitudeDB(bands, hz: 6_000, sampleRate: 16_000), -10)
        XCTAssertGreaterThan(FilterTestSupport.magnitudeDB(bands, hz: 1_800, sampleRate: 16_000), 0,
                             "the nasal peak stays audible")
    }

    func testBandsAboveTheClampLimitAreDroppedAtLowRates() {
        // voiceClear's 5 kHz air shelf has nothing to lift on an 8 kHz link (Nyquist 4 kHz).
        XCTAssertEqual(EQPreset.voiceClear.bands(sampleRate: 8_000).count, 2)
        XCTAssertEqual(EQPreset.voiceClear.bands(sampleRate: 16_000).count, 3)
        XCTAssertEqual(EQPreset.loudness.bands(sampleRate: 8_000).count, 2)
        XCTAssertEqual(EQPreset.loudness.bands(sampleRate: 16_000).count, 3)
        // Everything at 3.4 kHz and below survives even the narrow rate.
        XCTAssertEqual(EQPreset.telephone.bands(sampleRate: 8_000).count, 3)
        for preset in EQPreset.allCases {
            for rate in rates {
                for band in preset.bands(sampleRate: rate) {
                    XCTAssertLessThan(band.frequency, Biquad.maxFrequencyFraction * rate,
                                      "\(preset) at \(rate) Hz keeps a band the clamp would distort")
                }
            }
        }
    }

    func testIndexFollowsAllCases() {
        for (position, preset) in EQPreset.allCases.enumerated() {
            XCTAssertEqual(preset.index, position, "\(preset)")
            XCTAssertEqual(preset.id, preset.rawValue)
        }
    }

    func testRawValuesRoundTripThroughCodable() throws {
        let data = try JSONEncoder().encode(EQPreset.allCases)
        let decoded = try JSONDecoder().decode([EQPreset].self, from: data)
        XCTAssertEqual(decoded, EQPreset.allCases)
        let names = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(names, EQPreset.allCases.map(\.rawValue), "the stored form is the case name")
    }
}
