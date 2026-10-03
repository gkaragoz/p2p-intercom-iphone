import Foundation

/// Second-order IIR sections (RBJ Audio EQ Cookbook) for the equaliser and the voice effects.
///
/// The design (`coefficients(_:sampleRate:)`) runs in Double whenever a setting changes; the kernel
/// (`process(_:_:_:)`) runs in Float on every sample. The kernel is a tiny static function on plain
/// structs so the playback render callback can keep its bands as `UnsafeMutablePointer<State>` and
/// its coefficient tables precomputed per `WireRate`, and call it per sample without arrays,
/// allocation or runtime calls. The capture path wraps the same kernel in `BiquadChain`.
///
/// Transposed direct form II is used because its two state values are just the pending parts of the
/// next outputs: a coefficient change between samples cannot produce the large transient a direct
/// form I history swap does, and the form keeps its precision in Float for the low corner
/// frequencies (a 120 Hz high-pass at 48 kHz) an intercom equaliser uses.
enum Biquad {
    /// Normalised coefficients (`a0 == 1`):
    /// `H(z) = (b0 + b1 z⁻¹ + b2 z⁻²) / (1 + a1 z⁻¹ + a2 z⁻²)`.
    struct Coefficients: Equatable, Sendable {
        var b0: Float
        var b1: Float
        var b2: Float
        var a1: Float
        var a2: Float
    }

    /// The two delay elements of one section. Zero is silence; the renderer owns one per band.
    struct State: Equatable, Sendable {
        var z1: Float = 0
        var z2: Float = 0
    }

    /// A filter design. Frequencies in hertz, gains in decibels.
    enum Kind: Equatable, Sendable {
        /// Bell centred at `hz`; `q` sets its width (1 is about 1.4 octaves at ±3 dB of the gain).
        case peaking(hz: Double, q: Double, gainDB: Double)
        /// Shelf below `hz`. `slope` 1 is the standard RBJ shelf, the steepest that stays monotonic;
        /// smaller values spread the transition over more octaves.
        case lowShelf(hz: Double, slope: Double, gainDB: Double)
        /// Shelf above `hz`; `slope` as for `lowShelf`.
        case highShelf(hz: Double, slope: Double, gainDB: Double)
        /// Second-order high-pass, −3 dB at `hz` for `q` 0.707 (Butterworth).
        case highPass(hz: Double, q: Double)
        /// Second-order low-pass, −3 dB at `hz` for `q` 0.707 (Butterworth).
        case lowPass(hz: Double, q: Double)

        /// The centre or corner frequency of the design, in hertz.
        var frequency: Double {
            switch self {
            case .peaking(let hz, _, _), .lowShelf(let hz, _, _), .highShelf(let hz, _, _),
                 .highPass(let hz, _), .lowPass(let hz, _):
                return hz
            }
        }
    }

    /// Passes samples through unchanged, bit for bit (`y = 1·x + 0`).
    static let identity = Coefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// The corner frequency is clamped to this fraction of the sample rate: above it the bilinear
    /// warp squeezes the whole transition into the last few hundred hertz and the shelves stop
    /// looking like shelves. Well below Nyquist (0.5) so every design keeps a finite `sin(w0)`.
    static let maxFrequencyFraction = 0.45

    /// Smallest `q` or `slope` accepted; below it the sections become numerically pointless.
    static let minQ = 0.05

    /// Largest boost or cut accepted, so `A = 10^(gain/40)` stays within Float's comfortable range.
    static let maxGainDB = 40.0

    /// Designs `kind` for `sampleRate` after the RBJ Audio EQ Cookbook, in Double, and normalises
    /// by `a0`. Every parameter is clamped first (frequency to `1 ... maxFrequencyFraction ·
    /// sampleRate`, `q` and `slope` to at least `minQ` and `slope` to at most 1, gain to
    /// `±maxGainDB`; non-finite values fall back to a neutral setting), so any input yields finite,
    /// stable coefficients. A sample rate that is not positive and finite yields `identity`.
    static func coefficients(_ kind: Kind, sampleRate: Double) -> Coefficients {
        guard sampleRate.isFinite, sampleRate > 0 else { return identity }
        let hz = clamp(kind.frequency, 1, maxFrequencyFraction * sampleRate, fallback: 1_000)
        let w0 = 2 * Double.pi * hz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        let b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking(_, let rawQ, let rawGain):
            let q = clamp(rawQ, minQ, 100, fallback: 1)
            let gain = clamp(rawGain, -maxGainDB, maxGainDB, fallback: 0)
            let A = pow(10, gain / 40)
            let alpha = sinW0 / (2 * q)
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A

        case .lowShelf(_, let rawSlope, let rawGain):
            let (A, sqrtA2Alpha) = shelfTerms(slope: rawSlope, gainDB: rawGain, sinW0: sinW0)
            b0 = A * ((A + 1) - (A - 1) * cosW0 + sqrtA2Alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - sqrtA2Alpha)
            a0 = (A + 1) + (A - 1) * cosW0 + sqrtA2Alpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - sqrtA2Alpha

        case .highShelf(_, let rawSlope, let rawGain):
            let (A, sqrtA2Alpha) = shelfTerms(slope: rawSlope, gainDB: rawGain, sinW0: sinW0)
            b0 = A * ((A + 1) + (A - 1) * cosW0 + sqrtA2Alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - sqrtA2Alpha)
            a0 = (A + 1) - (A - 1) * cosW0 + sqrtA2Alpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - sqrtA2Alpha

        case .highPass(_, let rawQ):
            let q = clamp(rawQ, minQ, 100, fallback: 0.707)
            let alpha = sinW0 / (2 * q)
            b0 = (1 + cosW0) / 2
            b1 = -(1 + cosW0)
            b2 = (1 + cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha

        case .lowPass(_, let rawQ):
            let q = clamp(rawQ, minQ, 100, fallback: 0.707)
            let alpha = sinW0 / (2 * q)
            b0 = (1 - cosW0) / 2
            b1 = 1 - cosW0
            b2 = (1 - cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        }

        return Coefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                            a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// One sample through one section, transposed direct form II:
    ///
    ///     y  = b0·x + z1
    ///     z1 = b1·x − a1·y + z2
    ///     z2 = b2·x − a2·y
    ///
    /// Real-time safe: five multiplies, four adds, no branches, no memory beyond `s`.
    @inline(__always)
    static func process(_ x: Float, _ c: Coefficients, _ s: inout State) -> Float {
        let y = c.b0 * x + s.z1
        s.z1 = c.b1 * x - c.a1 * y + s.z2
        s.z2 = c.b2 * x - c.a2 * y
        return y
    }

    /// True when both poles lie inside the unit circle (the stability triangle of the denominator)
    /// and every coefficient is finite. `coefficients(_:sampleRate:)` always satisfies this; the
    /// check exists for tests and for coefficients that arrive from elsewhere.
    static func isStable(_ c: Coefficients) -> Bool {
        guard c.b0.isFinite, c.b1.isFinite, c.b2.isFinite, c.a1.isFinite, c.a2.isFinite else { return false }
        return abs(c.a2) < 1 && abs(c.a1) < 1 + c.a2
    }

    /// Gain of the section at `hz`, in decibels, from `|H(e^{jω})|` with `ω = 2π·hz / sampleRate`.
    /// Floored at −300 dB so an exact zero (a high-pass at DC) stays finite. Meant for tests and
    /// for drawing response curves, not for the audio thread.
    static func magnitudeDB(_ c: Coefficients, hz: Double, sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let w = 2 * Double.pi * hz / sampleRate
        let (b0, b1, b2) = (Double(c.b0), Double(c.b1), Double(c.b2))
        let (a1, a2) = (Double(c.a1), Double(c.a2))
        // z⁻¹ = cos w − j·sin w, z⁻² = cos 2w − j·sin 2w.
        let numeratorRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numeratorIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denominatorRe = 1 + a1 * cos(w) + a2 * cos(2 * w)
        let denominatorIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let power = (numeratorRe * numeratorRe + numeratorIm * numeratorIm)
            / (denominatorRe * denominatorRe + denominatorIm * denominatorIm)
        if power.isNaN || power <= 0 { return -300 }
        if power == .infinity { return 300 }
        return min(300, max(-300, 10 * log10(power)))
    }

    /// `A` and `2·√A·α` of the RBJ shelves: `α = sin(w0)/2 · √((A + 1/A)(1/S − 1) + 2)`. The slope
    /// is capped at 1 because beyond it the radicand can go negative for large gains and the shelf
    /// overshoots before it settles.
    private static func shelfTerms(slope rawSlope: Double, gainDB rawGain: Double,
                                   sinW0: Double) -> (A: Double, sqrtA2Alpha: Double) {
        let slope = clamp(rawSlope, minQ, 1, fallback: 1)
        let gain = clamp(rawGain, -maxGainDB, maxGainDB, fallback: 0)
        let A = pow(10, gain / 40)
        let alpha = sinW0 / 2 * ((A + 1 / A) * (1 / slope - 1) + 2).squareRoot()
        return (A, 2 * A.squareRoot() * alpha)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double, fallback: Double) -> Double {
        guard value.isFinite else { return min(max(fallback, low), high) }
        return min(max(value, low), high)
    }
}

/// Up to `maxBands` biquad sections in series, for the capture path (non-real-time worker thread)
/// and offline rendering. Coefficients are designed once in `init`; only the states change while
/// processing, so a chain is a plain value that can be handed to a worker and processed in place.
///
/// The bands live in four fixed slots rather than an array so that processing never touches
/// reference counts or risks a copy-on-write allocation, and an empty chain returns before it
/// reads a single sample, leaving the buffer bit-identical.
struct BiquadChain: Sendable {
    /// Sections a chain can hold. Extra bands passed to `init` are dropped, in order, so a preset
    /// lists its most important bands first.
    static let maxBands = 4

    /// Number of active sections, `0 ... maxBands`.
    private(set) var count: Int

    private var c0 = Biquad.identity
    private var c1 = Biquad.identity
    private var c2 = Biquad.identity
    private var c3 = Biquad.identity
    private var s0 = Biquad.State()
    private var s1 = Biquad.State()
    private var s2 = Biquad.State()
    private var s3 = Biquad.State()

    /// Designs the first `maxBands` of `bands` for `sampleRate`; later bands are ignored.
    init(bands: [Biquad.Kind], sampleRate: Double) {
        count = min(bands.count, Self.maxBands)
        if count > 0 { c0 = Biquad.coefficients(bands[0], sampleRate: sampleRate) }
        if count > 1 { c1 = Biquad.coefficients(bands[1], sampleRate: sampleRate) }
        if count > 2 { c2 = Biquad.coefficients(bands[2], sampleRate: sampleRate) }
        if count > 3 { c3 = Biquad.coefficients(bands[3], sampleRate: sampleRate) }
    }

    var isEmpty: Bool { count == 0 }

    /// The active sections' coefficients, first band first. Allocates; for inspection and tests.
    var coefficients: [Biquad.Coefficients] {
        Array([c0, c1, c2, c3].prefix(count))
    }

    /// Forgets the delay lines: the next samples start from silence (a stream restart, a rate
    /// change). Coefficients are untouched.
    mutating func reset() {
        s0 = Biquad.State()
        s1 = Biquad.State()
        s2 = Biquad.State()
        s3 = Biquad.State()
    }

    /// Filters `buffer` in place, one band after the other over the whole buffer. No allocation.
    mutating func process(_ buffer: UnsafeMutableBufferPointer<Float>) {
        guard count > 0 else { return }
        Self.run(buffer, c0, &s0)
        guard count > 1 else { return }
        Self.run(buffer, c1, &s1)
        guard count > 2 else { return }
        Self.run(buffer, c2, &s2)
        guard count > 3 else { return }
        Self.run(buffer, c3, &s3)
    }

    /// Filters `samples` in place.
    mutating func process(_ samples: inout [Float]) {
        guard count > 0 else { return }
        samples.withUnsafeMutableBufferPointer { process($0) }
    }

    @inline(__always)
    private static func run(_ buffer: UnsafeMutableBufferPointer<Float>,
                            _ c: Biquad.Coefficients, _ s: inout Biquad.State) {
        var state = s
        for index in buffer.indices {
            buffer[index] = Biquad.process(buffer[index], c, &state)
        }
        s = state
    }
}
