import Foundation

/// Short notification sounds played into the intercom's own output (connection gained or lost,
/// mute toggled).
///
/// They are synthesized instead of shipped as files so they are exactly in the wire format the
/// playback path already renders (16 kHz mono Int16), need no decoding, and can be mixed on the
/// audio thread from preallocated memory. Each note is a sine with 5 ms raised-cosine fades at both
/// ends, so starting and stopping never clicks; notes are separated by true silence.
enum CueTone: Int, CaseIterable, Sendable {
    /// First link to the peer came up: two rising tones.
    case connected
    /// The link was lost: two falling tones.
    case lost
    /// The link came back after a loss: three quick rising tones.
    case reconnected
    /// Microphone muted: one short low tick.
    case muted
    /// Microphone unmuted: one short higher tick.
    case unmuted

    struct Note: Equatable, Sendable {
        var frequency: Double
        var durationMs: Int
        /// Silence after the note (ignored for the last note).
        var gapMs: Int = 0
    }

    var notes: [Note] {
        switch self {
        case .connected:
            return [Note(frequency: 523.25, durationMs: 90, gapMs: 40), Note(frequency: 783.99, durationMs: 140)]
        case .lost:
            return [Note(frequency: 783.99, durationMs: 110, gapMs: 40), Note(frequency: 523.25, durationMs: 170)]
        case .reconnected:
            return [Note(frequency: 523.25, durationMs: 60, gapMs: 25),
                    Note(frequency: 659.25, durationMs: 60, gapMs: 25),
                    Note(frequency: 783.99, durationMs: 110)]
        case .muted:
            return [Note(frequency: 440, durationMs: 40)]
        case .unmuted:
            return [Note(frequency: 659.25, durationMs: 40)]
        }
    }

    /// Length of the fade in and fade out of every note.
    static let fadeMs = 5

    /// Total duration including the gaps between notes.
    var durationMs: Int {
        let notes = self.notes
        return notes.reduce(0) { $0 + $1.durationMs } + notes.dropLast().reduce(0) { $0 + $1.gapMs }
    }

    /// Number of samples at `sampleRate`, identical to `synthesize(sampleRate:amplitude:).count`.
    func sampleCount(sampleRate: Int) -> Int {
        let notes = self.notes
        var total = 0
        for (index, note) in notes.enumerated() {
            total += Self.samples(forMs: note.durationMs, sampleRate: sampleRate)
            if index < notes.count - 1 {
                total += Self.samples(forMs: note.gapMs, sampleRate: sampleRate)
            }
        }
        return total
    }

    /// Renders the cue. `amplitude` is the peak level relative to full scale (0...1).
    func synthesize(sampleRate: Int = Int(IntercomProtocol.sampleRate), amplitude: Float = CueToneBank.defaultAmplitude) -> [Int16] {
        let rate = max(1, sampleRate)
        let peak = Double(min(max(0, amplitude), 1)) * Double(Int16.max)
        let notes = self.notes
        var output: [Int16] = []
        output.reserveCapacity(sampleCount(sampleRate: rate))
        for (index, note) in notes.enumerated() {
            let length = Self.samples(forMs: note.durationMs, sampleRate: rate)
            let fade = min(Self.samples(forMs: Self.fadeMs, sampleRate: rate), length / 2)
            let phaseStep = 2 * Double.pi * note.frequency / Double(rate)
            for position in 0..<length {
                var gain = 1.0
                if fade > 0 {
                    if position < fade {
                        gain = Self.raisedCosine(Double(position) / Double(fade))
                    } else if position >= length - fade {
                        gain = Self.raisedCosine(Double(length - 1 - position) / Double(fade))
                    }
                }
                let value = sin(phaseStep * Double(position)) * peak * gain
                output.append(Int16(clamping: Int(value.rounded())))
            }
            if index < notes.count - 1 {
                output.append(contentsOf: repeatElement(0, count: Self.samples(forMs: note.gapMs, sampleRate: rate)))
            }
        }
        return output
    }

    private static func samples(forMs milliseconds: Int, sampleRate: Int) -> Int {
        max(0, milliseconds) * sampleRate / 1000
    }

    /// 0 at `x == 0`, 1 at `x == 1`, smooth at both ends.
    private static func raisedCosine(_ x: Double) -> Double {
        0.5 - 0.5 * cos(Double.pi * min(max(0, x), 1))
    }
}

/// Every `CueTone` rendered once into a single contiguous sample array.
///
/// The audio engine copies `samples` into memory it owns before the render callback can use it
/// and selects a cue by its `range(of:)`; `mix(_:into:gain:)` does the per-cycle work without
/// allocating, locking or calling into the runtime.
struct CueToneBank: Sendable {
    /// −14 dBFS: clearly audible over the peer's voice without being startling in AirPods.
    static let defaultAmplitude: Float = 0.2

    /// Rendered once at the wire sample rate on first use.
    static let standard = CueToneBank()

    let sampleRate: Int
    let amplitude: Float
    let samples: [Int16]
    private let ranges: [Range<Int>]

    init(sampleRate: Int = Int(IntercomProtocol.sampleRate), amplitude: Float = CueToneBank.defaultAmplitude) {
        self.sampleRate = max(1, sampleRate)
        self.amplitude = amplitude
        var all: [Int16] = []
        var ranges: [Range<Int>] = []
        for cue in CueTone.allCases {
            let rendered = cue.synthesize(sampleRate: self.sampleRate, amplitude: amplitude)
            ranges.append(all.count..<(all.count + rendered.count))
            all.append(contentsOf: rendered)
        }
        samples = all
        self.ranges = ranges
    }

    func range(of cue: CueTone) -> Range<Int> {
        ranges[cue.rawValue]
    }

    func samples(of cue: CueTone) -> ArraySlice<Int16> {
        samples[range(of: cue)]
    }

    /// Adds `source` (Int16 PCM) scaled by `gain` onto `output` (Float PCM, ±1), sample by
    /// sample, clamping the sum to ±1. Returns how many samples were mixed, `min` of both counts.
    /// Real-time safe: plain arithmetic on caller-provided memory.
    @discardableResult
    static func mix(_ source: UnsafeBufferPointer<Int16>, into output: UnsafeMutableBufferPointer<Float>, gain: Float = 1) -> Int {
        let count = min(source.count, output.count)
        guard count > 0, let sourceBase = source.baseAddress, let outputBase = output.baseAddress else { return 0 }
        let scale = gain / 32_768
        for index in 0..<count {
            let sum = outputBase[index] + Float(sourceBase[index]) * scale
            outputBase[index] = min(1, max(-1, sum))
        }
        return count
    }
}
