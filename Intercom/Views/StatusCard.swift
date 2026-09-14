import SwiftUI
import UIKit

/// The intercom at a glance: what the link is doing (with elapsed time and redial attempt), the path
/// it uses, anything the user can fix, the primary action for the current state (start, retry,
/// connect again, resume audio, open Settings), and the audio route and round-trip time.
///
/// Before the intercom runs the card follows `controller.phase` (permission, start-up, failure);
/// while it runs it follows `controller.linkState`, which already puts an audio interruption ahead of
/// the link.
struct StatusCard: View {
    @EnvironmentObject private var controller: IntercomController
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Opens the app's own Settings sheet (where the pairing code lives).
    var showSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = controller.lastError, controller.phase != .connected {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let warning = controller.warning {
                warningView(warning)
            }

            actionButton

            Divider()

            footer
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let since = elapsedSince {
                // Counts up by itself; no timer needed.
                Text(since, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else if isBusy {
                ProgressView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Running mode; `nil` while the intercom is not running (the phase decides then).
    private var runningState: SessionLinkStatus? {
        controller.isRunning ? controller.linkState : nil
    }

    private var title: LocalizedStringKey {
        if let state = runningState {
            switch state {
            case .idle, .searching:
                return "Searching for nearby iPhones…"
            case .disconnected(let byPeer):
                return byPeer ? "Disconnected on the other iPhone" : "Disconnected"
            case .connecting:
                if let name = controller.peers.first(where: { $0.state == .connecting })?.name {
                    return "Connecting to \(name)…"
                }
                return "Connecting…"
            case .connected:
                let names = controller.connectedPeers.map(\.name).joined(separator: ", ")
                return names.isEmpty ? "Connected" : "Connected to \(names)"
            case .reconnecting:
                if let name = controller.lastPeerName {
                    return "Reconnecting to \(name)…"
                }
                return "Reconnecting…"
            case .audioInterrupted:
                return "Audio paused"
            }
        }
        switch controller.phase {
        case .idle: return "Intercom is off"
        case .requestingPermission: return "Requesting microphone access…"
        case .permissionDenied: return "Microphone access denied"
        case .starting: return "Starting audio…"
        case .failed: return "Could not start"
        case .searching, .connected: return "Searching for nearby iPhones…"
        }
    }

    private var subtitle: LocalizedStringKey {
        if let state = runningState {
            switch state {
            case .idle, .searching:
                // The Wi‑Fi warning below already says the same thing.
                return controller.warning == .wifiOff
                    ? "Open Intercom on the other iPhone too."
                    : "Works without internet. Wi‑Fi must be on."
            case .disconnected:
                return "Tap Connect to talk again."
            case .connecting(let attempt):
                return attempt > 1 ? "Attempt \(attempt)" : "Works without internet. Wi‑Fi must be on."
            case .connected:
                if controller.remoteAudioPaused { return "The other iPhone's audio is paused." }
                if controller.remoteMuted { return "Peer muted" }
                if controller.remoteTalking { return "Peer is talking" }
                return controller.isTalkLatched ? "You are talking without holding." : "Ready"
            case .reconnecting(_, let attempt):
                return attempt > 0 ? "Attempt \(attempt)" : "Waiting for the other iPhone…"
            case .audioInterrupted(let needsForeground):
                return needsForeground
                    ? "Audio could not restart in the background."
                    : "Audio is paused by a call or another app."
            }
        }
        switch controller.phase {
        case .idle: return "Tap Start to look for the other iPhone."
        case .requestingPermission, .starting: return "One moment…"
        case .permissionDenied: return "Allow the microphone in Settings to talk."
        case .failed: return "Check the microphone and try again."
        case .searching, .connected: return "Works without internet. Wi‑Fi must be on."
        }
    }

    /// Connected and reconnecting show how long the link has been up, or down.
    private var elapsedSince: Date? {
        switch runningState {
        case .connected(let since, _)?, .reconnecting(let since, _)?:
            return since
        default:
            return nil
        }
    }

    private var isBusy: Bool {
        if let state = runningState {
            switch state {
            case .idle, .searching, .connecting, .reconnecting:
                return true
            case .connected, .disconnected:
                return false
            case .audioInterrupted:
                if case .recovering = controller.audioState { return true }
                return false
            }
        }
        switch controller.phase {
        case .requestingPermission, .starting:
            return true
        default:
            return false
        }
    }

    private var statusSymbol: String {
        if let state = runningState {
            switch state {
            case .idle, .searching, .connecting:
                return "antenna.radiowaves.left.and.right"
            case .connected:
                return controller.remoteTalking ? "waveform.circle.fill" : "checkmark.circle.fill"
            case .reconnecting, .disconnected:
                return "antenna.radiowaves.left.and.right.slash"
            case .audioInterrupted:
                return "pause.circle.fill"
            }
        }
        switch controller.phase {
        case .permissionDenied, .failed: return "exclamationmark.triangle.fill"
        case .idle: return "power"
        default: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        if let state = runningState {
            switch state {
            case .idle, .searching, .connecting: return .accentColor
            case .connected: return .green
            case .reconnecting, .audioInterrupted: return .orange
            case .disconnected: return .secondary
            }
        }
        switch controller.phase {
        case .permissionDenied, .failed: return .red
        default: return .secondary
        }
    }

    // MARK: - Warnings and actions

    private func warningView(_ warning: SessionWarning) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(warningText(warning))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: warning == .wifiOff ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)

            switch warning {
            case .localNetworkDenied:
                Button("Open Settings", action: openSystemSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .pairingMismatch:
                Button("Check pairing code", action: showSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .versionMismatch, .wifiOff:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private func warningText(_ warning: SessionWarning) -> LocalizedStringKey {
        switch warning {
        case .localNetworkDenied:
            return "Local Network access is off. Allow it in Settings › Intercom."
        case .pairingMismatch:
            return "The other iPhone uses a different pairing code."
        case .versionMismatch:
            return "The other iPhone runs an incompatible version. Install the same build on both."
        case .wifiOff:
            return "Wi‑Fi must be on. No network or internet is needed."
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .audioInterrupted? = runningState {
            Button {
                controller.resumeAudio()
            } label: {
                Label("Resume audio", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else if case .disconnected? = runningState, let peer = peerToReconnect {
            // Nothing redials after a Disconnect; the peer row has the same button, but this one is
            // where the eye goes.
            Button {
                controller.connect(to: peer)
            } label: {
                Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            switch controller.phase {
            case .idle:
                Button {
                    Task { await controller.start() }
                } label: {
                    Label("Start", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .failed:
                Button {
                    Task { await controller.start() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .permissionDenied:
                Button(action: openSystemSettings) {
                    Label("Open Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            default:
                EmptyView()
            }
        }
    }

    /// The peer whose link was ended with Disconnect: the most recent one if it is among them.
    private var peerToReconnect: IntercomController.PeerInfo? {
        let candidates = controller.peers.filter { $0.state == .discovered && $0.isDeliberatelyDisconnected }
        return candidates.first { $0.name == controller.lastPeerName } ?? candidates.first
    }

    /// The app's page in the Settings app, which has both the Microphone and the Local Network switch.
    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    // MARK: - Footer

    /// One row at the usual text sizes. From xxxLarge the route gets a row of its own, and at the
    /// accessibility sizes the path and round-trip time too: the chip and the time do not shrink in the
    /// single row, so there they would push the card past the screen edges.
    private var footer: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    routeLabel
                    pathChip
                    rttLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if dynamicTypeSize >= .xxxLarge {
                VStack(alignment: .leading, spacing: 6) {
                    routeLabel
                    HStack(spacing: 12) {
                        pathChip
                        rttLabel
                            .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    routeLabel
                        .layoutPriority(-1)
                    Spacer(minLength: 4)
                    pathChip
                        .fixedSize(horizontal: true, vertical: false)
                    rttLabel
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var routeLabel: some View {
        Label {
            routeName
                .lineLimit(1)
        } icon: {
            Image(systemName: routeSymbol)
        }
    }

    @ViewBuilder
    private var pathChip: some View {
        if controller.isRunning, let path = controller.linkPath {
            LinkPathChip(path: path)
        }
    }

    @ViewBuilder
    private var rttLabel: some View {
        if let rtt = controller.roundTripMs {
            Label {
                Text(verbatim: "\(Int(rtt.rounded())) ms")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } icon: {
                Image(systemName: "timer")
            }
            .accessibilityLabel(Text("Round trip \(Int(rtt.rounded())) ms"))
        }
    }

    private var routeName: Text {
        let name = controller.route.outputName
        // Port names come from the system, already localized.
        return name.isEmpty ? Text("Speaker") : Text(verbatim: name)
    }

    private var routeSymbol: String {
        let route = controller.route
        if route.isBluetooth { return "airpods" }
        if route.isWiredHeadset { return "headphones" }
        if route.isReceiver { return "iphone" }
        return "speaker.wave.2.fill"
    }
}
