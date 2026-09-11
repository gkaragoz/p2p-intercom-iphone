import Foundation

/// Level metering helpers shared by the capture and playback paths.
enum AudioLevel {
    /// Root-mean-square of the samples, normalized to `0...1`.
    static func rms(_ samples: UnsafeBufferPointer<Int16>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var accumulator: Double = 0
        for sample in samples {
            let value = Double(sample) / 32_768.0
            accumulator += value * value
        }
        return Float((accumulator / Double(samples.count)).squareRoot())
    }

    static func rms(_ samples: [Int16]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    /// Converts a normalized RMS or peak value to decibels full scale, floored at -100 dB.
    static func decibels(fromLinear value: Float) -> Float {
        guard value > 0 else { return -100 }
        return Float(max(-100, 20 * log10(Double(value))))
    }

    /// Maps a dBFS value onto `0...1` for drawing a meter.
    static func meterValue(dB: Float, floor: Float = -60, ceiling: Float = 0) -> Float {
        guard ceiling > floor else { return 0 }
        let normalized = (dB - floor) / (ceiling - floor)
        return min(1, max(0, normalized))
    }
}

/// Simple attack/release smoothing so meters do not flicker.
struct LevelSmoother {
    var attack: Float
    var release: Float
    private(set) var value: Float = 0

    init(attack: Float = 0.7, release: Float = 0.2) {
        self.attack = attack
        self.release = release
    }

    mutating func process(_ target: Float) -> Float {
        let coefficient = target > value ? attack : release
        value += (target - value) * coefficient
        if abs(target - value) < 0.0005 { value = target }
        return value
    }

    mutating func reset() {
        value = 0
    }
}
