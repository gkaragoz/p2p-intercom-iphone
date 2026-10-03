import Foundation
import XCTest
@testable import IntercomCore

final class VoiceEffectPresetTests: XCTestCase {
    private let wireRates = WireRate.allCases.map { Double($0.sampleRate) }

    func testDefaultIsOff() {
        XCTAssertEqual(VoiceEffectPreset.default, .off)
        XCTAssertEqual(VoiceEffectPreset.off.index, 0)
    }

    func testOffIsTheEmptyRecipe() {
        let recipe = VoiceEffectPreset.off.recipe
        XCTAssertEqual(recipe, VoiceEffectRecipe(), "off must not process anything")
        XCTAssertFalse(recipe.needsOfflineEngine)
        XCTAssertTrue(recipe.eqBands.isEmpty)
        XCTAssertEqual(recipe.pitchCents, 0)
        XCTAssertEqual(recipe.outputGainDB, 0)
        XCTAssertNil(recipe.distortion)
        XCTAssertNil(recipe.reverb)
    }

    func testEQBandsAreStableAtEveryWireRate() {
        XCTAssertEqual(wireRates, [8_000, 16_000, 24_000, 32_000])
        for preset in VoiceEffectPreset.allCases {
            for rate in wireRates {
                for band in preset.recipe.eqBands {
                    let c = Biquad.coefficients(band, sampleRate: rate)
                    XCTAssertTrue(Biquad.isStable(c), "\(preset) \(band) at \(rate) Hz: \(c)")
                }
            }
        }
    }

    func testEQBandsFitTheChain() {
        for preset in VoiceEffectPreset.allCases {
            let bands = preset.recipe.eqBands
            XCTAssertLessThanOrEqual(bands.count, BiquadChain.maxBands, "\(preset)")
            XCTAssertEqual(BiquadChain(bands: bands, sampleRate: 16_000).count, bands.count, "\(preset)")
        }
    }

    func testPitchStaysWithinAnOctave() {
        for preset in VoiceEffectPreset.allCases {
            let cents = preset.recipe.pitchCents
            XCTAssertTrue(cents.isFinite, "\(preset)")
            XCTAssertLessThanOrEqual(abs(cents), 1_200, "\(preset) shifts more than an octave, which stops sounding like speech")
        }
    }

    func testMixesAreWithinPercentRange() {
        for preset in VoiceEffectPreset.allCases {
            let recipe = preset.recipe
            if let distortion = recipe.distortion {
                XCTAssertTrue((0...100).contains(distortion.wetDryMix), "\(preset) distortion mix \(distortion.wetDryMix)")
            }
            if let reverb = recipe.reverb {
                XCTAssertTrue((0...100).contains(reverb.wetDryMix), "\(preset) reverb mix \(reverb.wetDryMix)")
            }
            XCTAssertTrue(recipe.outputGainDB.isFinite, "\(preset)")
        }
    }

    func testOnlyEngineEffectsRequireTheOfflineEngine() {
        for preset in VoiceEffectPreset.allCases {
            let recipe = preset.recipe
            let usesEngineEffect = recipe.pitchCents != 0 || recipe.distortion != nil || recipe.reverb != nil
            XCTAssertEqual(recipe.needsOfflineEngine, usesEngineEffect,
                           "\(preset): EQ alone runs on the capture worker, anything else needs the engine")
        }
        XCTAssertFalse(VoiceEffectRecipe(eqBands: [.highPass(hz: 120, q: 0.707)]).needsOfflineEngine,
                       "an EQ-only recipe runs without the engine")
        XCTAssertTrue(VoiceEffectRecipe(pitchCents: 100).needsOfflineEngine)
        XCTAssertTrue(VoiceEffectRecipe(distortion: .init(flavor: .decimated, wetDryMix: 10)).needsOfflineEngine)
        XCTAssertTrue(VoiceEffectRecipe(reverb: .init(flavor: .smallRoom, wetDryMix: 10)).needsOfflineEngine)
        // Today every preset but off uses at least one engine effect.
        for preset in VoiceEffectPreset.allCases where preset != .off {
            XCTAssertTrue(preset.recipe.needsOfflineEngine, "\(preset)")
        }
    }

    func testRecipesMatchTheirDescriptions() {
        XCTAssertEqual(VoiceEffectPreset.chipmunk.recipe.pitchCents, 900)
        XCTAssertEqual(VoiceEffectPreset.child.recipe.pitchCents, 400)
        XCTAssertEqual(VoiceEffectPreset.deep.recipe.pitchCents, -400)
        XCTAssertEqual(VoiceEffectPreset.giant.recipe.pitchCents, -800)
        XCTAssertEqual(VoiceEffectPreset.giant.recipe.reverb?.flavor, .mediumRoom)
        XCTAssertEqual(VoiceEffectPreset.robot.recipe.distortion?.flavor, .alienChatter)
        XCTAssertEqual(VoiceEffectPreset.radio.recipe.distortion?.flavor, .radioTower)
        XCTAssertEqual(VoiceEffectPreset.megaphone.recipe.distortion?.flavor, .brokenSpeaker)
        XCTAssertEqual(VoiceEffectPreset.megaphone.recipe.eqBands.count, 3)
        XCTAssertEqual(VoiceEffectPreset.cave.recipe.reverb, .init(flavor: .cathedral, wetDryMix: 40))
        XCTAssertNil(VoiceEffectPreset.cave.recipe.distortion)
        XCTAssertEqual(VoiceEffectPreset.cave.recipe.pitchCents, 0)
    }

    func testIndexFollowsAllCases() {
        for (position, preset) in VoiceEffectPreset.allCases.enumerated() {
            XCTAssertEqual(preset.index, position, "\(preset)")
            XCTAssertEqual(preset.id, preset.rawValue)
        }
    }

    func testRawValuesRoundTripThroughCodable() throws {
        let data = try JSONEncoder().encode(VoiceEffectPreset.allCases)
        let decoded = try JSONDecoder().decode([VoiceEffectPreset].self, from: data)
        XCTAssertEqual(decoded, VoiceEffectPreset.allCases)
        let names = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(names, VoiceEffectPreset.allCases.map(\.rawValue), "the stored form is the case name")
    }

    func testFlavorNamesAreStable() {
        XCTAssertEqual(DistortionFlavor.allCases.map(\.rawValue),
                       ["brokenSpeaker", "decimated", "alienChatter", "radioTower"])
        XCTAssertEqual(ReverbFlavor.allCases.map(\.rawValue),
                       ["smallRoom", "mediumRoom", "largeHall", "cathedral"])
    }
}
