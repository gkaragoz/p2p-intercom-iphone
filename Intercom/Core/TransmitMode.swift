import Foundation

/// How the local microphone is gated before audio is sent to the peer.
enum TransmitMode: String, CaseIterable, Codable, Identifiable {
    /// Audio is sent only while the talk button is held.
    case pushToTalk
    /// Audio is sent automatically whenever the microphone level crosses a threshold.
    case voiceActivated
    /// Audio is sent continuously, like an open intercom line.
    case alwaysOn

    var id: String { rawValue }
}
