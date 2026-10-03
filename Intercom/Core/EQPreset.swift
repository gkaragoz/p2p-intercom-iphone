import Foundation

/// The equaliser presets a user can pick for their own voice (applied before sending) or for what
/// they hear (applied in the playback renderer). Pure data: each preset is a short list of
/// `Biquad.Kind` bands that either side designs for its own sample rate.
///
/// `off` is the default and yields no bands at all, so the audio paths skip the filter entirely
/// and today's output stays byte-identical. Every other preset uses at most
/// `BiquadChain.maxBands` sections, and the bands are ordered so that dropping the last one would
/// hurt the least, in case a future rate wants to trim.
enum EQPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    /// No processing.
    case off
    /// Warmer and fuller: lifts the chest below 200 Hz and takes a little sharpness off the top.
    case bassBoost
    /// Forward and intelligible: lifts the 1.5–3 kHz region where consonants live.
    case midPresence
    /// Clean speech: removes rumble under 120 Hz, lifts presence and adds air on top.
    case voiceClear
    /// Brighter: a plain shelf above 3 kHz.
    case treble
    /// Small-speaker loudness curve: more bass and treble, a dip in the middle.
    case loudness
    /// Old telephone: 300 Hz to 3.4 kHz only, with a nasal peak.
    case telephone

    static let `default`: EQPreset = .off

    var id: String { rawValue }

    /// Position in `allCases`, for segmented controls and per-preset tables.
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The bands to design for `sampleRate`, first band first, at most `BiquadChain.maxBands`.
    /// A band centred at or above `Biquad.maxFrequencyFraction · sampleRate` is left out: clamped
    /// there it would only colour the last few hundred hertz below Nyquist (an 8 kHz link has no
    /// 5 kHz "air" to lift).
    func bands(sampleRate: Double) -> [Biquad.Kind] {
        let limit = Biquad.maxFrequencyFraction * sampleRate
        return nominalBands.filter { $0.frequency < limit }
    }

    /// `bands(sampleRate:)` designed for `sampleRate`, ready for a renderer's coefficient table.
    func coefficients(sampleRate: Double) -> [Biquad.Coefficients] {
        bands(sampleRate: sampleRate).map { Biquad.coefficients($0, sampleRate: sampleRate) }
    }

    /// The bands as designed, before any rate-dependent trimming.
    private var nominalBands: [Biquad.Kind] {
        switch self {
        case .off:
            return []
        case .bassBoost:
            return [.lowShelf(hz: 200, slope: 1, gainDB: 6),
                    .highShelf(hz: 3_000, slope: 1, gainDB: -2)]
        case .midPresence:
            return [.peaking(hz: 1_500, q: 1, gainDB: 4),
                    .peaking(hz: 3_000, q: 1, gainDB: 2)]
        case .voiceClear:
            return [.highPass(hz: 120, q: 0.707),
                    .peaking(hz: 2_500, q: 1, gainDB: 4),
                    .highShelf(hz: 5_000, slope: 1, gainDB: 3)]
        case .treble:
            return [.highShelf(hz: 3_000, slope: 1, gainDB: 6)]
        case .loudness:
            return [.lowShelf(hz: 150, slope: 1, gainDB: 5),
                    .peaking(hz: 1_000, q: 0.8, gainDB: -2),
                    .highShelf(hz: 4_000, slope: 1, gainDB: 4)]
        case .telephone:
            return [.highPass(hz: 300, q: 0.9),
                    .lowPass(hz: 3_400, q: 0.9),
                    .peaking(hz: 1_800, q: 1, gainDB: 3)]
        }
    }
}
