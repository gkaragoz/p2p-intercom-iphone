import Foundation

/// A distortion character. Pure names here; the Audio layer maps them to
/// `AVAudioUnitDistortionPreset` (`.multiBrokenSpeaker`, `.multiDecimated2`, `.speechAlienChatter`,
/// `.speechRadioTower`), which cannot be named in this Foundation-only module.
enum DistortionFlavor: String, CaseIterable, Sendable {
    case brokenSpeaker
    case decimated
    case alienChatter
    case radioTower
}

/// A reverb space; the Audio layer maps it to `AVAudioUnitReverbPreset` (`.smallRoom`,
/// `.mediumRoom`, `.largeHall`, `.cathedral`).
enum ReverbFlavor: String, CaseIterable, Sendable {
    case smallRoom
    case mediumRoom
    case largeHall
    case cathedral
}

/// What a voice effect does to the outgoing voice, as plain numbers the Audio layer turns into an
/// offline `AVAudioEngine` graph (pitch → distortion → reverb) plus a `BiquadChain`.
///
/// The EQ bands alone run on the capture worker without an engine; pitch, distortion and reverb
/// need the offline engine (`needsOfflineEngine`), which costs a few milliseconds of latency, so
/// the Audio layer only builds it for recipes that ask for it.
struct VoiceEffectRecipe: Equatable, Sendable {
    struct Distortion: Equatable, Sendable {
        var flavor: DistortionFlavor
        /// Percent of the distorted signal in the output, `0 ... 100` like `AVAudioUnitDistortion`.
        var wetDryMix: Float
    }

    struct Reverb: Equatable, Sendable {
        var flavor: ReverbFlavor
        /// Percent of the reverberated signal in the output, `0 ... 100` like `AVAudioUnitReverb`.
        var wetDryMix: Float
    }

    /// Pitch shift in cents (`AVAudioUnitTimePitch.pitch`), `−2400 ... 2400`; 0 leaves the pitch.
    var pitchCents: Float = 0
    /// Equaliser bands applied after the effects, at most `BiquadChain.maxBands`.
    var eqBands: [Biquad.Kind] = []
    var distortion: Distortion? = nil
    var reverb: Reverb? = nil
    /// Make-up gain applied last, in decibels.
    var outputGainDB: Float = 0

    /// True when the recipe needs the offline effect engine; an EQ-only recipe does not.
    var needsOfflineEngine: Bool { pitchCents != 0 || distortion != nil || reverb != nil }
}

/// The voice effects a user can pick for their outgoing voice. Pure data: each preset is a
/// `VoiceEffectRecipe`. `off` is the default and is the empty recipe, so nothing is processed and
/// today's output stays byte-identical.
enum VoiceEffectPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    /// The voice as captured.
    case off
    /// Pitched up a major third with the low end thinned and the top lifted: a small child.
    case child
    /// Pitched up almost an octave: the cartoon chipmunk.
    case chipmunk
    /// Pitched down a major third with extra chest: a heavier, older voice.
    case deep
    /// Pitched down most of an octave inside a room: a giant.
    case giant
    /// Alien-chatter distortion, slightly pitched down: a metallic robot.
    case robot
    /// Band-limited to the telephone band and crackly: a two-way radio.
    case radio
    /// Harsh, mid-heavy and clipped: shouting through a megaphone.
    case megaphone
    /// A long cathedral reverb on the dry voice: talking in a cave.
    case cave

    static let `default`: VoiceEffectPreset = .off

    var id: String { rawValue }

    /// Position in `allCases`, for segmented controls and per-preset tables.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var recipe: VoiceEffectRecipe {
        switch self {
        case .off:
            return VoiceEffectRecipe()
        case .child:
            return VoiceEffectRecipe(pitchCents: 400,
                                     eqBands: [.highPass(hz: 180, q: 0.707),
                                               .highShelf(hz: 3_000, slope: 1, gainDB: 3)])
        case .chipmunk:
            return VoiceEffectRecipe(pitchCents: 900)
        case .deep:
            return VoiceEffectRecipe(pitchCents: -400,
                                     eqBands: [.lowShelf(hz: 150, slope: 1, gainDB: 3)])
        case .giant:
            return VoiceEffectRecipe(pitchCents: -800,
                                     reverb: .init(flavor: .mediumRoom, wetDryMix: 20))
        case .robot:
            return VoiceEffectRecipe(pitchCents: -200,
                                     distortion: .init(flavor: .alienChatter, wetDryMix: 45))
        case .radio:
            return VoiceEffectRecipe(eqBands: [.highPass(hz: 300, q: 0.9),
                                               .lowPass(hz: 3_400, q: 0.9)],
                                     distortion: .init(flavor: .radioTower, wetDryMix: 35))
        case .megaphone:
            return VoiceEffectRecipe(eqBands: [.highPass(hz: 400, q: 0.707),
                                               .peaking(hz: 2_000, q: 1.2, gainDB: 6),
                                               .lowPass(hz: 4_000, q: 0.707)],
                                     distortion: .init(flavor: .brokenSpeaker, wetDryMix: 40))
        case .cave:
            return VoiceEffectRecipe(reverb: .init(flavor: .cathedral, wetDryMix: 40))
        }
    }
}
