import SwiftUI

extension TransmitMode {
    var title: LocalizedStringKey {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .voiceActivated: return "Voice"
        case .alwaysOn: return "Open mic"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .pushToTalk: return "Hold the button while you speak."
        case .voiceActivated: return "Sends automatically when you speak; adjust the threshold in Settings."
        case .alwaysOn: return "Your microphone is always on, like an intercom line."
        }
    }

    var systemImage: String {
        switch self {
        case .pushToTalk: return "hand.tap.fill"
        case .voiceActivated: return "waveform"
        case .alwaysOn: return "mic.fill"
        }
    }
}
