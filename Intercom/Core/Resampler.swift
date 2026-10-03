import Foundation

/// Converts a mono PCM stream between two of the `WireRate` sample rates with a polyphase
/// windowed-sinc FIR, in pure Swift so it builds on every platform the Core package supports.
///
/// Design: the stream is conceptually zero-stuffed by `L` (`ratio.interpolation`), low-pass
/// filtered at the intermediate rate `inputRate * L`, then every `M`-th sample (`ratio.decimation`)
/// is kept. The filter is a Kaiser-windowed sinc (β = 8, 12 zero crossings per side) with its
/// cutoff 10 % below the narrower Nyquist band: the speech band is flat to within 0.001 dB and
/// droops under 1 dB at 80 % of Nyquist, while anything that would alias from beyond the
/// transition band is attenuated by more than 80 dB. Only the taps that meet a non-zero stuffed
/// sample are ever evaluated (the polyphase form), which keeps the cost at `N / L` multiplies per
/// output sample, under 20 µs per frame. Each polyphase row is normalised to sum to exactly 1,
/// so a constant input reproduces exactly at every output phase and DC carries no ripple. For the
/// four wire rates every factor is at most 4 (`16 → 24` is `3 / 2`, `8 → 32` is `4 / 1`,
/// `32 → 24` is `3 / 4`).
///
/// Delay: the filter is linear phase with `N` taps, so it delays the signal by
/// `(N − 1) / (2 · inputRate · L)` seconds, between 0.5 and 1.5 ms for the rate pairs the intercom
/// uses (`groupDelay`). The output for a whole 20 ms input frame is therefore the *input frame shifted by that
/// delay*, which the jitter buffer never notices because it only compares frames to each other.
///
/// Streaming: the last `N / L − 1` input samples are carried across calls together with a phase
/// accumulator, so a sequence of arbitrary-length inputs yields exactly the samples a single call
/// over their concatenation would (`process(a) + process(b) == process(a + b)`). For whole 20 ms
/// frames (`inputRate / 50` samples, always a multiple of `M` for these rates) every call returns
/// exactly `outputRate / 50` samples and the phase is back at 0 afterwards. The identity pair
/// (`inputRate == outputRate`) is an exact copy with no filtering.
///
/// Memory: the coefficient table and the history are allocated in `init`; the work buffers grow
/// only when a larger input than any seen before arrives, so steady state (a fixed frame size)
/// never allocates. Value type; not thread-safe, the owner serialises calls.
struct Resampler: Sendable {
    /// Zero crossings of the sinc on each side of its centre; sets the filter length.
    static let zeroCrossingsPerSide = 12
    /// Kaiser window shape: β = 8 gives about −80 dB stopband ripple at the cost of a wider transition.
    static let kaiserBeta = 8.0
    /// Fraction of the narrower Nyquist band the passband keeps; the rest is the transition band.
    static let passbandFraction = 0.9

    let inputRate: Int
    let outputRate: Int

    /// Reduced rate ratio: `outputRate / inputRate == interpolation / decimation`.
    var ratio: (interpolation: Int, decimation: Int) { (interpolation, decimation) }

    /// Total taps of the prototype low-pass filter; 0 for the identity pair.
    let tapCount: Int

    /// Taps per polyphase row (`tapCount / interpolation`); the history holds one fewer samples.
    let tapsPerPhase: Int

    /// Delay the filter adds, in seconds: `(tapCount − 1) / (2 · inputRate · interpolation)`.
    var groupDelay: TimeInterval {
        guard !isIdentity else { return 0 }
        return Double(tapCount - 1) / (2 * Double(inputRate) * Double(interpolation))
    }

    private let interpolation: Int
    private let decimation: Int
    private let isIdentity: Bool
    /// Polyphase table, row `p` at `p * tapsPerPhase`: `coefficients[p * T + j] == h[p + j * L]`.
    private let coefficients: [Float]
    /// `history` (the last `tapsPerPhase − 1` inputs) followed by the current input; the prefix
    /// is kept valid between calls so a call sees `work[historyCount + n]` as input sample `n`.
    private var work: [Float]
    /// Offset, in intermediate-rate samples from the start of the next input block, of the next
    /// output sample. Always in `0..<decimation`; 0 at every whole-frame boundary.
    private var phase = 0
    /// Scratch for the `[Int16]` API so a fixed frame size never allocates on the way in or out.
    private var inputScratch: [Float] = []
    private var outputScratch: [Float] = []

    private var historyCount: Int { tapsPerPhase - 1 }

    init(inputRate: Int, outputRate: Int) {
        precondition(inputRate > 0 && outputRate > 0, "sample rates must be positive")
        self.inputRate = inputRate
        self.outputRate = outputRate
        let divisor = Self.greatestCommonDivisor(inputRate, outputRate)
        interpolation = outputRate / divisor
        decimation = inputRate / divisor
        isIdentity = interpolation == 1 && decimation == 1
        if isIdentity {
            tapCount = 0
            tapsPerPhase = 1
            coefficients = []
            work = []
        } else {
            let design = Self.design(interpolation: interpolation, decimation: decimation)
            tapCount = design.tapCount
            tapsPerPhase = design.tapsPerPhase
            coefficients = design.coefficients
            work = [Float](repeating: 0, count: tapsPerPhase - 1)
        }
    }

    /// Samples the next `process` call will write for `n` input samples, given the current phase.
    func outputCount(forInputCount n: Int) -> Int {
        guard !isIdentity else { return max(0, n) }
        let span = n * interpolation
        guard span > phase else { return 0 }
        return (span - phase + decimation - 1) / decimation
    }

    /// Clears the history and the phase, as if no sample had been seen. Keeps the buffers.
    mutating func reset() {
        for index in 0..<historyCount { work[index] = 0 }
        phase = 0
    }

    /// Resamples `input` into `output`, which must have room for `outputCount(forInputCount:)`
    /// samples, and returns how many were written. Never allocates once `input.count` is no
    /// larger than any earlier input.
    @discardableResult
    mutating func process(_ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>) -> Int {
        let inputCount = input.count
        if isIdentity {
            precondition(output.count >= inputCount, "output buffer too small")
            if inputCount > 0, let source = input.baseAddress, let destination = output.baseAddress {
                destination.update(from: source, count: inputCount)
            }
            return inputCount
        }

        let count = outputCount(forInputCount: inputCount)
        precondition(output.count >= count, "output buffer too small")
        let historyCount = self.historyCount
        let total = historyCount + inputCount
        if work.count < total {
            work.append(contentsOf: repeatElement(0, count: total - work.count))
        }

        let interpolation = self.interpolation
        let decimation = self.decimation
        let tapsPerPhase = self.tapsPerPhase
        let coefficients = self.coefficients
        var t = phase
        work.withUnsafeMutableBufferPointer { work in
            if inputCount > 0, let source = input.baseAddress {
                (work.baseAddress! + historyCount).update(from: source, count: inputCount)
            }
            coefficients.withUnsafeBufferPointer { table in
                for k in 0..<count {
                    let row = (t % interpolation) * tapsPerPhase
                    // Index of x[n] for this output; every tap reaches back at most tapsPerPhase − 1.
                    let newest = historyCount + t / interpolation
                    var accumulator: Float = 0
                    for j in 0..<tapsPerPhase {
                        accumulator += table[row + j] * work[newest - j]
                    }
                    output[k] = accumulator
                    t += decimation
                }
            }
            // Carry the newest historyCount samples to the front for the next call. When the
            // input is shorter than the history the ranges overlap, and an ascending copy is
            // safe because every source index is at or after its destination.
            let start = total - historyCount
            if start > 0 {
                for index in 0..<historyCount {
                    work[index] = work[start + index]
                }
            }
        }
        phase = t - inputCount * interpolation
        return count
    }

    /// Convenience for the packet path: `Int16` in, `Int16` out, rounded to nearest and clamped.
    /// The identity pair returns `input` itself.
    mutating func process(_ input: [Int16]) -> [Int16] {
        if isIdentity { return input }
        let count = outputCount(forInputCount: input.count)
        var inputScratch: [Float] = []
        var outputScratch: [Float] = []
        swap(&inputScratch, &self.inputScratch)
        swap(&outputScratch, &self.outputScratch)
        defer {
            swap(&inputScratch, &self.inputScratch)
            swap(&outputScratch, &self.outputScratch)
        }
        if inputScratch.count < input.count {
            inputScratch.append(contentsOf: repeatElement(0, count: input.count - inputScratch.count))
        }
        if outputScratch.count < count {
            outputScratch.append(contentsOf: repeatElement(0, count: count - outputScratch.count))
        }
        for index in 0..<input.count {
            inputScratch[index] = Float(input[index])
        }
        let written = inputScratch.withUnsafeBufferPointer { source in
            outputScratch.withUnsafeMutableBufferPointer { destination in
                process(UnsafeBufferPointer(rebasing: source[0..<input.count]),
                        into: UnsafeMutableBufferPointer(rebasing: destination[0..<count]))
            }
        }
        return [Int16](unsafeUninitializedCapacity: written) { buffer, initialized in
            for index in 0..<written {
                let value = outputScratch[index].rounded()
                buffer[index] = Int16(max(-32_768, min(32_767, value)))
            }
            initialized = written
        }
    }

    // MARK: - Filter design

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }

    /// Modified Bessel function of the first kind, order 0, by its power series. Thirty terms
    /// are exact to double precision for the arguments a β = 8 window produces.
    static func besselI0(_ x: Double) -> Double {
        let half = x / 2
        var term = 1.0
        var sum = 1.0
        for k in 1...30 {
            term *= half / Double(k)
            sum += term * term
        }
        return sum
    }

    /// Builds the polyphase table for one rate ratio: a Kaiser-windowed sinc low-pass at the
    /// intermediate rate, split into `interpolation` rows that each sum to exactly 1.
    private static func design(interpolation: Int, decimation: Int) -> (tapCount: Int, tapsPerPhase: Int, coefficients: [Float]) {
        let widest = max(interpolation, decimation)
        var tapCount = 2 * zeroCrossingsPerSide * widest
        tapCount = (tapCount + interpolation - 1) / interpolation * interpolation
        let tapsPerPhase = tapCount / interpolation
        // Cutoff in cycles per intermediate-rate sample: 10 % under the narrower Nyquist band.
        let cutoff = passbandFraction / (2 * Double(widest))
        let centre = Double(tapCount - 1) / 2
        let windowScale = 1 / besselI0(kaiserBeta)

        var prototype = [Double](repeating: 0, count: tapCount)
        for index in 0..<tapCount {
            let offset = Double(index) - centre
            let argument = 2 * cutoff * offset
            let sinc = argument == 0 ? 1.0 : sin(Double.pi * argument) / (Double.pi * argument)
            let position = 2 * Double(index) / Double(tapCount - 1) - 1
            let window = besselI0(kaiserBeta * (1 - position * position).squareRoot()) * windowScale
            prototype[index] = 2 * cutoff * sinc * window
        }

        var coefficients = [Float](repeating: 0, count: interpolation * tapsPerPhase)
        for row in 0..<interpolation {
            var sum = 0.0
            for j in 0..<tapsPerPhase {
                sum += prototype[row + j * interpolation]
            }
            for j in 0..<tapsPerPhase {
                coefficients[row * tapsPerPhase + j] = Float(prototype[row + j * interpolation] / sum)
            }
        }
        return (tapCount, tapsPerPhase, coefficients)
    }
}
