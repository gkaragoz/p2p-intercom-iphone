import SwiftUI

/// Colors of the Live Activity. The activity always draws on a dark ground (the Dynamic Island is
/// black, and the Lock Screen card uses `background`), so these are chosen for dark and the views
/// force the dark color scheme. The accent is the app's AccentColor; the extension has no asset
/// catalog, so it is repeated here.
enum ActivityPalette {
    /// The app's accent (AccentColor.colorset), for filled controls.
    static let accent = Color(red: 0.129, green: 0.478, blue: 0.949)
    /// A lighter accent that stays legible as a symbol or text color on the dark ground.
    static let accentOnDark = Color(red: 0.40, green: 0.66, blue: 1.0)
    static let connected = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let muted = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let neutral = Color.white.opacity(0.6)
    /// The Lock Screen card: a deep blue-black, slightly translucent so the wallpaper still shows at
    /// the edges like the system's own activities.
    static let background = Color(red: 0.05, green: 0.07, blue: 0.11).opacity(0.88)
    /// Unselected control fill.
    static let controlFill = Color.white.opacity(0.14)
}

typealias IntercomLiveState = IntercomActivityAttributes.ContentState

// MARK: - Link

extension IntercomLiveState {
    var statusTitle: LocalizedStringKey {
        switch link {
        case .searching: return "Searching…"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .audioPaused: return "Audio paused"
        case .stopped: return "Intercom stopped"
        }
    }

    /// The link symbol: the same antenna in every presentation, colored by state, so the activity
    /// reads as "the intercom link" at a glance.
    var linkSymbol: String {
        switch link {
        case .searching, .connecting, .connected: return "antenna.radiowaves.left.and.right"
        case .reconnecting, .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .audioPaused: return "pause.circle.fill"
        case .stopped: return "power"
        }
    }

    var linkTint: Color {
        switch link {
        case .connected: return ActivityPalette.connected
        case .connecting: return ActivityPalette.accentOnDark
        case .reconnecting, .audioPaused: return ActivityPalette.warning
        case .searching, .disconnected, .stopped: return ActivityPalette.neutral
        }
    }

    /// The Dynamic Island keyline: neutral once the activity is stale, like every other link color.
    func islandTint(isStale: Bool) -> Color {
        isStale ? ActivityPalette.neutral : linkTint
    }

    /// VoiceOver label of the single-symbol presentations. A stale activity must not announce a state
    /// that may no longer be true.
    func islandAccessibilityTitle(isStale: Bool) -> LocalizedStringKey {
        isStale ? "Not updated recently" : statusTitle
    }

    /// Elapsed time is only meaningful for an established or lost link.
    var showsTimer: Bool {
        link == .connected || link == .reconnecting
    }

    /// No controls once the intercom has stopped: they would do nothing.
    var showsControls: Bool {
        link != .stopped
    }

    /// The latch only works in push-to-talk, unmuted, with audio up (the app refuses it otherwise;
    /// muting also releases it).
    var showsTalkLatch: Bool {
        mode == .pushToTalk && !isMuted && link != .audioPaused && link != .stopped
    }

    /// Redial count worth showing: from the second connect attempt, or any reconnect attempt.
    var visibleAttempt: Int? {
        switch link {
        case .connecting where reconnectAttempt > 1: return reconnectAttempt
        case .reconnecting where reconnectAttempt > 0: return reconnectAttempt
        default: return nil
        }
    }
}

// MARK: - Peer

extension IntercomLiveState {
    /// What the peer is doing, most important first; only while connected.
    var peerStatus: (text: LocalizedStringKey, tint: Color)? {
        guard link == .connected else { return nil }
        if remoteAudioPaused { return ("audio paused", ActivityPalette.warning) }
        if remoteMuted { return ("muted", ActivityPalette.muted) }
        if remoteTalking { return ("talking", ActivityPalette.connected) }
        return nil
    }
}

// MARK: - Glanceable symbols (Dynamic Island)

extension IntercomLiveState {
    /// Compact trailing. A stale activity shows that it is out of date instead: the app may be gone,
    /// and a green "sending" or "peer talking" symbol would claim a live link that no longer exists.
    func activitySymbol(isStale: Bool) -> (name: String, tint: Color) {
        isStale ? ("clock.badge.exclamationmark", ActivityPalette.neutral) : liveActivitySymbol
    }

    /// Minimal. Stale: only the last known link, in neutral, never activity.
    func minimalSymbol(isStale: Bool) -> (name: String, tint: Color) {
        isStale ? (linkSymbol, ActivityPalette.neutral) : liveMinimalSymbol
    }

    /// Compact trailing: peer talking > sending > muted > transmit mode.
    private var liveActivitySymbol: (name: String, tint: Color) {
        if link == .connected, remoteTalking { return ("speaker.wave.2.fill", ActivityPalette.accentOnDark) }
        if isSending { return ("mic.and.signal.meter.fill", ActivityPalette.connected) }
        if isMuted { return ("mic.slash.fill", ActivityPalette.muted) }
        return (mode.symbolName, .white)
    }

    /// Minimal: the single most important thing. Trouble (or a Disconnect) first, then mute, then
    /// activity, then the link.
    private var liveMinimalSymbol: (name: String, tint: Color) {
        switch link {
        case .reconnecting, .disconnected, .audioPaused, .stopped:
            return (linkSymbol, linkTint)
        case .searching, .connecting, .connected:
            if isMuted { return ("mic.slash.fill", ActivityPalette.muted) }
            if link == .connected, remoteTalking { return ("speaker.wave.2.fill", ActivityPalette.accentOnDark) }
            if isSending { return ("mic.and.signal.meter.fill", ActivityPalette.connected) }
            return (linkSymbol, linkTint)
        }
    }
}

// MARK: - Mode and route

extension ActivityTransmitMode {
    /// Same symbols as the app's mode picker.
    var symbolName: String {
        switch self {
        case .pushToTalk: return "hand.tap.fill"
        case .voiceActivated: return "waveform"
        case .alwaysOn: return "mic.fill"
        }
    }

    /// Short labels that fit a third of the control row.
    var shortTitle: LocalizedStringKey {
        switch self {
        case .pushToTalk: return "PTT"
        case .voiceActivated: return "Voice"
        case .alwaysOn: return "Open mic"
        }
    }

    /// Full names for VoiceOver.
    var accessibilityName: LocalizedStringKey {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .voiceActivated: return "Voice activated"
        case .alwaysOn: return "Open mic"
        }
    }
}

extension IntercomLiveState.Route {
    /// Same symbols as the app's status card.
    var symbolName: String {
        switch self {
        case .bluetooth: return "airpods"
        case .wired: return "headphones"
        case .speaker: return "speaker.wave.2.fill"
        case .receiver: return "iphone"
        }
    }

    var accessibilityName: LocalizedStringKey {
        switch self {
        case .bluetooth: return "Bluetooth headset"
        case .wired: return "Headphones"
        case .speaker: return "Speaker"
        case .receiver: return "iPhone earpiece"
        }
    }
}
