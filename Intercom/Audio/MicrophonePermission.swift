import AVFoundation
import Foundation

/// Thin async wrapper around `AVAudioApplication`'s microphone permission API (iOS 17+).
enum MicrophonePermission {
    enum Status {
        case undetermined
        case denied
        case granted
    }

    static var status: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    /// Prompts the user if necessary and returns whether recording is allowed.
    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
