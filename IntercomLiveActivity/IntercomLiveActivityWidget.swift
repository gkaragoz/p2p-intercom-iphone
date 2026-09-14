import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island presentation of a running intercom session.
///
/// * Lock Screen: status header (link symbol, "Connected" with a self-updating timer, peer name and
///   what the peer is doing, route and round-trip time) and a control row: Mute, transmit mode, and
///   the talk latch in push-to-talk.
/// * Dynamic Island compact: link symbol (green connected, orange reconnecting, gray searching or
///   disconnected) and the most relevant activity (peer talking > sending > muted > mode). Minimal: one
///   symbol by priority. Expanded: header and the same controls.
///
/// Tapping outside a button opens the app (the system's default, no URL needed). Buttons run in the
/// app's process through `LiveActivityIntent`. On a locked phone iOS may ask for Face ID first.
/// A stale activity (the app stopped updating it, e.g. because it was killed) says so instead of
/// showing a timer that may no longer be true, and every Island presentation drops to neutral with no
/// sending or talking symbol.
struct IntercomLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IntercomActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(ActivityPalette.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    ExpandedLeading(state: context.state, isStale: context.isStale)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.showsControls {
                        ActivityControls(state: context.state, height: 40)
                            .padding(.top, 6)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                IslandSymbol(symbol: (context.state.linkSymbol, context.state.islandTint(isStale: context.isStale)))
                    .accessibilityLabel(Text(context.state.islandAccessibilityTitle(isStale: context.isStale)))
            } compactTrailing: {
                IslandSymbol(symbol: context.state.activitySymbol(isStale: context.isStale))
            } minimal: {
                IslandSymbol(symbol: context.state.minimalSymbol(isStale: context.isStale))
                    .accessibilityLabel(Text(context.state.islandAccessibilityTitle(isStale: context.isStale)))
            }
            .keylineTint(context.state.islandTint(isStale: context.isStale))
        }
    }
}
