#if DEBUG
import ActivityKit
import SwiftUI
import WidgetKit

// Xcode canvas previews of every presentation (Lock Screen, Dynamic Island expanded, compact and
// minimal). Open this file with the Intercom scheme selected (it builds the extension), show the
// canvas, and step through the content states at the bottom of it. The shared schemes Run in
// Release, where this file compiles to nothing (and the canvas needs -Onone), so temporarily set
// Edit Scheme > Run > Build Configuration to Debug; switch it back before committing or installing.

extension IntercomActivityAttributes {
    static let preview = IntercomActivityAttributes(localName: "Gökhan's iPhone")
}

extension IntercomActivityAttributes.ContentState {
    private static func make(_ link: Link,
                             since: TimeInterval = -754,
                             attempt: Int = 0,
                             mode: ActivityTransmitMode = .pushToTalk,
                             muted: Bool = false,
                             latched: Bool = false,
                             sending: Bool = false,
                             remoteTalking: Bool = false,
                             remoteMuted: Bool = false,
                             route: Route = .bluetooth,
                             rtt: Int? = 20) -> Self {
        Self(link: link,
             linkSince: Date(timeIntervalSinceNow: since),
             peerName: link == .searching ? nil : "Ayşe's iPhone",
             reconnectAttempt: attempt,
             audioNeedsForeground: false,
             mode: mode,
             isMuted: muted,
             isTalkLatched: latched,
             isSending: sending,
             remoteTalking: remoteTalking,
             remoteMuted: remoteMuted,
             remoteAudioPaused: false,
             route: route,
             linkPath: link == .connected ? .direct : nil,
             rttBucketMs: link == .connected ? rtt : nil)
    }

    static let previewConnected = make(.connected)
    static let previewPeerTalking = make(.connected, mode: .voiceActivated, remoteTalking: true, route: .speaker, rtt: 30)
    static let previewLatched = make(.connected, latched: true, sending: true)
    static let previewMuted = make(.connected, mode: .alwaysOn, muted: true, route: .wired, rtt: 10)
    /// Muted in push-to-talk: no Talk latch tile (the app refuses it while muted).
    static let previewMutedPushToTalk = make(.connected, muted: true)
    static let previewReconnecting = make(.reconnecting, since: -9, attempt: 3)
    static let previewSearching = make(.searching, since: -40, mode: .voiceActivated, route: .speaker)
    /// Ended with Disconnect: neutral, nothing reconnects until Connect is tapped in the app.
    static let previewDisconnected = make(.disconnected, since: -30)
    static let previewAudioPaused: Self = {
        var state = make(.audioPaused)
        state.audioNeedsForeground = true
        return state
    }()
}

#Preview("Lock Screen", as: .content, using: IntercomActivityAttributes.preview) {
    IntercomLiveActivityWidget()
} contentStates: {
    IntercomActivityAttributes.ContentState.previewConnected
    IntercomActivityAttributes.ContentState.previewPeerTalking
    IntercomActivityAttributes.ContentState.previewLatched
    IntercomActivityAttributes.ContentState.previewMuted
    IntercomActivityAttributes.ContentState.previewMutedPushToTalk
    IntercomActivityAttributes.ContentState.previewReconnecting
    IntercomActivityAttributes.ContentState.previewSearching
    IntercomActivityAttributes.ContentState.previewDisconnected
    IntercomActivityAttributes.ContentState.previewAudioPaused
}

#Preview("Island Expanded", as: .dynamicIsland(.expanded), using: IntercomActivityAttributes.preview) {
    IntercomLiveActivityWidget()
} contentStates: {
    IntercomActivityAttributes.ContentState.previewConnected
    IntercomActivityAttributes.ContentState.previewPeerTalking
    IntercomActivityAttributes.ContentState.previewReconnecting
    IntercomActivityAttributes.ContentState.previewAudioPaused
}

#Preview("Island Compact", as: .dynamicIsland(.compact), using: IntercomActivityAttributes.preview) {
    IntercomLiveActivityWidget()
} contentStates: {
    IntercomActivityAttributes.ContentState.previewConnected
    IntercomActivityAttributes.ContentState.previewPeerTalking
    IntercomActivityAttributes.ContentState.previewLatched
    IntercomActivityAttributes.ContentState.previewMuted
    IntercomActivityAttributes.ContentState.previewReconnecting
    IntercomActivityAttributes.ContentState.previewSearching
    IntercomActivityAttributes.ContentState.previewDisconnected
}

#Preview("Island Minimal", as: .dynamicIsland(.minimal), using: IntercomActivityAttributes.preview) {
    IntercomLiveActivityWidget()
} contentStates: {
    IntercomActivityAttributes.ContentState.previewConnected
    IntercomActivityAttributes.ContentState.previewPeerTalking
    IntercomActivityAttributes.ContentState.previewMuted
    IntercomActivityAttributes.ContentState.previewReconnecting
    IntercomActivityAttributes.ContentState.previewDisconnected
    IntercomActivityAttributes.ContentState.previewAudioPaused
}
#endif
