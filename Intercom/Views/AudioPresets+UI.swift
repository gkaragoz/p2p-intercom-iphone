import SwiftUI

/// User-facing names of the audio presets in Settings. The Core enums stay Foundation-only; the
/// titles live here so the string catalog check sees them as SwiftUI string keys.

extension WireRate {
    var title: LocalizedStringKey {
        switch self {
        case .narrow: return "Low (8 kHz)"
        case .standard: return "Standard (16 kHz)"
        case .high: return "High (24 kHz)"
        case .highest: return "Highest (32 kHz)"
        }
    }
}

extension LatencyProfile {
    var title: LocalizedStringKey {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .safe: return "Safe"
        }
    }
}

extension VoiceEffectPreset {
    var title: LocalizedStringKey {
        switch self {
        case .off: return "Off"
        case .child: return "Child"
        case .chipmunk: return "Chipmunk"
        case .deep: return "Deep"
        case .giant: return "Giant"
        case .robot: return "Robot"
        case .radio: return "Radio"
        case .megaphone: return "Megaphone"
        case .cave: return "Cave"
        }
    }
}

extension EQPreset {
    var title: LocalizedStringKey {
        switch self {
        case .off: return "Off"
        case .bassBoost: return "Bass boost"
        case .midPresence: return "Mid presence"
        case .voiceClear: return "Voice clear"
        case .treble: return "Treble"
        case .loudness: return "Loudness"
        case .telephone: return "Telephone"
        }
    }
}
