import AppIntents
import SwiftUI

// Building blocks shared by the Lock Screen and the expanded Dynamic Island. SF Symbols only (image
// assets bigger than the presentation can make the activity fail to start), fixed layouts (the system
// ignores animations), and every control is a `Button(intent:)` carrying an explicit target value.

// MARK: - Status

/// The colored link symbol in a tinted circle.
struct LinkBadge: View {
    let state: IntercomLiveState
    var diameter: CGFloat = 44
    var isStale = false

    var body: some View {
        let tint = isStale ? ActivityPalette.neutral : state.linkTint
        ZStack {
            Circle()
                .fill(tint.opacity(0.2))
            Image(systemName: state.linkSymbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// "Ayşe's iPhone · talking", or the explanation for states without a peer.
struct PeerLine: View {
    let state: IntercomLiveState
    var isStale = false

    var body: some View {
        if isStale {
            Label("Not updated recently", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(ActivityPalette.warning)
                .lineLimit(1)
        } else {
            switch state.link {
            case .searching:
                Text("Looking for the other iPhone")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .audioPaused:
                Text(state.audioNeedsForeground ? "Open Intercom to resume" : "In use by a call or another app")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .stopped:
                Text("Open Intercom to start")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .disconnected:
                Text("Open Intercom to connect")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .connecting, .connected, .reconnecting:
                HStack(spacing: 4) {
                    peerName
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let status = state.peerStatus {
                        Text(verbatim: "·")
                            .foregroundStyle(.tertiary)
                        Text(status.text)
                            .foregroundStyle(status.tint)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
        }
    }

    private var peerName: Text {
        if let name = state.peerName, !name.isEmpty {
            return Text(verbatim: name)
        }
        return Text("Other iPhone")
    }
}

/// Elapsed time since the link came up (green) or was lost (orange). Updates itself: no activity
/// updates are needed for it to tick.
struct LinkTimer: View {
    let state: IntercomLiveState

    var body: some View {
        // The upper bound only has to lie beyond the activity's 8-hour lifetime. The lower one is clamped
        // so a wall-clock change can never make the range invalid.
        let now = Date()
        Text(timerInterval: min(state.linkSince, now)...now.addingTimeInterval(12 * 3600), countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(state.link == .connected ? Color.white : ActivityPalette.warning)
            // A timer text claims the width of its widest possible value; keep it to a realistic one.
            .frame(maxWidth: 76, alignment: .trailing)
    }
}

/// Route symbol plus round-trip time while connected, or the redial attempt while (re)connecting.
/// Nothing otherwise, and nothing on a stale activity, whose numbers may no longer be true.
struct LinkDetails: View {
    let state: IntercomLiveState
    var isStale = false

    var body: some View {
        if !isStale {
            if let attempt = state.visibleAttempt {
                Text("Attempt \(attempt)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if state.link == .connected {
                HStack(spacing: 4) {
                    Image(systemName: state.route.symbolName)
                        .accessibilityLabel(Text(state.route.accessibilityName))
                    if let rtt = state.rttBucketMs {
                        Text("\(rtt) ms")
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

// MARK: - Controls

/// Visual style of every control: a rounded tile with a symbol over a short label.
struct ControlTile: View {
    let symbol: String
    let title: LocalizedStringKey
    var fill: Color = ActivityPalette.controlFill
    var foreground: Color = .white
    var height: CGFloat = 46

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: height > 42 ? 16 : 14, weight: .semibold))
                // Symbols differ in height; a fixed box keeps every label on the same baseline.
                .frame(height: height > 42 ? 20 : 17)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// [Mute/Unmute] [PTT | Voice | Open mic] [Talk latch, only in push-to-talk]. No Stop: an accidental
/// tap in a pocket must never end the session; stopping stays in the app.
struct ActivityControls: View {
    let state: IntercomLiveState
    var height: CGFloat = 46

    var body: some View {
        HStack(spacing: 8) {
            muteButton
                .frame(width: sideWidth)
            modeSelector
            if state.showsTalkLatch {
                latchButton
                    .frame(width: sideWidth)
            }
        }
        .frame(height: height)
    }

    private var sideWidth: CGFloat { height > 42 ? 70 : 62 }

    /// Matches the app's mute button: the symbol shows the state, the label the action.
    private var muteButton: some View {
        Button(intent: SetMutedIntent(muted: !state.isMuted)) {
            ControlTile(symbol: state.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: state.isMuted ? "Unmute" : "Mute",
                        fill: state.isMuted ? ActivityPalette.muted : ActivityPalette.controlFill,
                        height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(state.isMuted ? "Unmute microphone" : "Mute microphone"))
    }

    private var modeSelector: some View {
        HStack(spacing: 2) {
            ForEach(ActivityTransmitMode.allCases, id: \.self) { mode in
                let isSelected = mode == state.mode
                Button(intent: SetTransmitModeIntent(mode: mode)) {
                    VStack(spacing: 3) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: height > 42 ? 16 : 14, weight: .semibold))
                            .frame(height: height > 42 ? 20 : 17)
                        Text(mode.shortTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? ActivityPalette.accent : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(mode.accessibilityName))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ActivityPalette.controlFill))
    }

    private var latchButton: some View {
        Button(intent: SetTalkLatchIntent(on: !state.isTalkLatched)) {
            ControlTile(symbol: "dot.radiowaves.up.forward",
                        title: state.isTalkLatched ? "Talking" : "Talk",
                        fill: state.isTalkLatched ? ActivityPalette.connected : ActivityPalette.controlFill,
                        foreground: state.isTalkLatched ? .black : .white,
                        height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(state.isTalkLatched ? "Stop talking" : "Talk without holding"))
    }
}

// MARK: - Lock Screen

/// The Lock Screen (and banner / StandBy) presentation: a status header and the control row.
/// About 130 pt tall, well inside the 160 pt limit, with the 14 pt standard margins.
struct LockScreenView: View {
    let state: IntercomLiveState
    /// `ActivityViewContext.isStale`: the app stopped updating the activity.
    var isStale = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                LinkBadge(state: state, isStale: isStale)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.statusTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    PeerLine(state: state, isStale: isStale)
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    if state.showsTimer, !isStale {
                        LinkTimer(state: state)
                            .font(.headline)
                    }
                    LinkDetails(state: state, isStale: isStale)
                        .font(.caption)
                }
            }
            if state.showsControls {
                ActivityControls(state: state)
            }
        }
        .padding(14)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Dynamic Island

/// Expanded leading region: badge and status title.
struct ExpandedLeading: View {
    let state: IntercomLiveState
    var isStale = false

    var body: some View {
        HStack(spacing: 8) {
            LinkBadge(state: state, diameter: 34, isStale: isStale)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                PeerLine(state: state, isStale: isStale)
                    .font(.caption)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.leading, 4)
    }
}

/// Expanded trailing region: timer and route / round-trip time.
struct ExpandedTrailing: View {
    let state: IntercomLiveState
    var isStale = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if state.showsTimer, !isStale {
                LinkTimer(state: state)
                    .font(.subheadline.weight(.semibold))
            }
            LinkDetails(state: state, isStale: isStale)
                .font(.caption)
        }
        .padding(.trailing, 4)
    }
}

/// A single glanceable symbol for the compact and minimal presentations.
struct IslandSymbol: View {
    let symbol: (name: String, tint: Color)

    var body: some View {
        Image(systemName: symbol.name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(symbol.tint)
    }
}
