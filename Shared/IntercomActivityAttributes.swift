import ActivityKit
import Foundation

/// The Live Activity's data model. This file lives in `Shared/`, which is compiled into both the
/// app (which requests and updates the activity) and the widget extension (which renders it), so
/// the two sides always agree on the Codable layout ActivityKit passes between the processes.
///
/// Keep `ContentState` tiny and made of enums rather than strings: ActivityKit caps attributes plus
/// state at 4 KB, every update is re-rendered by the extension, and the extension localizes the
/// words itself (so the activity follows the phone's language, not whatever the app had).
///
/// Changing a stored property's name or type changes the encoding: an activity left over from an
/// older build would fail to decode. The app ends leftover activities at launch, so that is harmless,
/// but add new fields as optionals or with care.
struct IntercomActivityAttributes: ActivityAttributes {
    /// This phone's display name. Static for the activity's lifetime (a rename takes effect with the
    /// next activity).
    var localName: String

    struct ContentState: Codable, Hashable, Sendable {
        /// Coarse connection state shown in the Lock Screen header and the Dynamic Island.
        enum Link: String, Codable, Hashable, Sendable {
            /// Running, never linked in this run: looking for the other phone.
            case searching
            /// The link was ended with Disconnect (on either phone); nothing reconnects until someone
            /// taps Connect in the app.
            case disconnected
            /// A first connection attempt is under way.
            case connecting
            case connected
            /// The link was lost unexpectedly; the transport is redialling.
            case reconnecting
            /// Audio I/O is interrupted (call, Siri, another app).
            case audioPaused
            /// The intercom is not running (only shown briefly before the activity ends, or when an
            /// activity outlived its app).
            case stopped
        }

        /// Where the audio goes. Mirrors the app's route classification.
        enum Route: String, Codable, Hashable, Sendable {
            /// Any Bluetooth headset (shown with the AirPods symbol, as in the app).
            case bluetooth
            case wired
            case speaker
            case receiver
        }

        /// The network path of the link; mirrors the app's `LinkPath`.
        enum Path: String, Codable, Hashable, Sendable {
            /// Apple peer-to-peer Wi-Fi: no router involved.
            case direct
            /// Both phones on the same Wi-Fi network.
            case wifiNetwork
            case wired
            case other
        }

        var link: Link
        /// When `link` last changed (for connected: when the link came up; for reconnecting: when it
        /// was lost). Drives `Text(timerInterval:)`, so elapsed time needs no updates.
        var linkSince: Date
        /// Display name of the connected (or last connected) peer, if any.
        var peerName: String?
        /// Redial attempt while connecting or reconnecting; 0 when not known yet.
        var reconnectAttempt: Int
        /// With `link == .audioPaused`: iOS will not restart audio until Intercom is opened.
        var audioNeedsForeground: Bool
        var mode: ActivityTransmitMode
        var isMuted: Bool
        /// Push-to-talk is latched on from the activity (or the app).
        var isTalkLatched: Bool
        /// This phone is transmitting right now.
        var isSending: Bool
        var remoteTalking: Bool
        var remoteMuted: Bool
        /// The peer's audio is interrupted: it can neither hear nor speak.
        var remoteAudioPaused: Bool
        var route: Route
        /// `nil` while no link is up.
        var linkPath: Path?
        /// Round-trip time rounded up to 10 ms; `nil` while unknown.
        var rttBucketMs: Int?
    }
}

/// How the microphone is gated, as the activity and its intents see it. A mirror of the app's
/// `TransmitMode` (which lives in the platform-independent core and is not compiled into the
/// extension); the raw values match so conversion is lossless.
enum ActivityTransmitMode: String, Codable, Hashable, Sendable, CaseIterable {
    case pushToTalk
    case voiceActivated
    case alwaysOn
}
