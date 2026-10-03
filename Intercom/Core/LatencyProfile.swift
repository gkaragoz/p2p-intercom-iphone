import Foundation

/// How much delay the intercom trades for robustness: the bounds of the adaptive playout delay and
/// the preferred hardware I/O buffer. `balanced` reproduces the original fixed values exactly.
///
/// The fixed playout slider (`AppSettings.jitterTargetMs`, used when the automatic buffer is off) is
/// independent of the profile; the profile only bounds the automatic estimate and sets the I/O buffer.
enum LatencyProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Smallest buffers: lowest delay, less tolerant of Wi‑Fi hiccups.
    case fast
    /// The original behaviour: 40–200 ms adaptive playout, 10 ms I/O buffer.
    case balanced
    /// Deeper buffers: survives stalls better at the cost of delay.
    case safe

    static let `default`: LatencyProfile = .balanced

    var id: String { rawValue }

    /// Lowest target the adaptive playout delay estimator returns.
    var playoutFloorMs: Double {
        switch self {
        case .fast: return 20
        case .balanced: return 40
        case .safe: return 100
        }
    }

    /// Highest target the adaptive playout delay estimator returns.
    var playoutCeilingMs: Double {
        switch self {
        case .fast: return 120
        case .balanced: return 200
        case .safe: return 300
        }
    }

    /// Safety margin added on top of the measured delay.
    var playoutMarginMs: Double {
        switch self {
        case .fast: return 5
        case .balanced: return 10
        case .safe: return 20
        }
    }

    /// Preferred `AVAudioSession` I/O buffer duration (a hint; iOS may round it).
    var ioBufferDuration: TimeInterval {
        switch self {
        case .fast: return 0.005
        case .balanced: return 0.010
        case .safe: return 0.020
        }
    }
}
