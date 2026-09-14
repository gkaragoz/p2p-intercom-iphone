import SwiftUI

/// Every iPhone running Intercom that has been seen nearby, with the state of the link to it.
struct PeerListView: View {
    @EnvironmentObject private var controller: IntercomController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nearby iPhones")
                .font(.headline)
            if controller.peers.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.peers) { peer in
                    PeerRow(peer: peer)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private var emptyMessage: LocalizedStringKey {
        controller.isRunning
            ? "No iPhones found yet. Open Intercom on the other iPhone."
            : "Start the intercom to look for nearby iPhones."
    }
}

struct PeerRow: View {
    @EnvironmentObject private var controller: IntercomController
    let peer: IntercomController.PeerInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: peer.name)
                    .font(.body)
                    .lineLimit(2)
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            accessory
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch peer.state {
        case .discovered:
            if peer.isAwaitingReconnect {
                // The transport redials by itself.
                ProgressView()
            } else if peer.compatibility == .compatible {
                Button("Connect") {
                    controller.connect(to: peer)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .connecting:
            ProgressView()
        case .connected:
            Button("Disconnect", role: .destructive) {
                controller.disconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var stateText: LocalizedStringKey {
        switch peer.state {
        case .discovered:
            switch peer.compatibility {
            case .pairingMismatch: return "Different pairing code"
            case .incompatibleVersion: return "Incompatible app version"
            case .compatible: break
            }
            if peer.isAwaitingReconnect {
                return "Reconnecting…"
            }
            switch peer.lastDisconnectReason {
            case .userRequested?:
                return "Disconnected"
            case .remoteBye(.userDisconnect)?:
                return "Disconnected on the other iPhone"
            default:
                return "Discovered"
            }
        case .connecting:
            let attempt = peer.connectAttempt
            if peer.hasBeenConnected {
                return attempt > 1 ? "Reconnecting · attempt \(attempt)" : "Reconnecting…"
            }
            return attempt > 1 ? "Connecting · attempt \(attempt)" : "Connecting…"
        case .connected:
            if peer.isSuspect {
                return "Weak connection…"
            }
            if let path = peer.path.displayName {
                return "Connected · \(path)"
            }
            return "Connected"
        }
    }

    private var stateColor: Color {
        switch peer.state {
        case .discovered:
            return peer.compatibility == .compatible ? .secondary : .orange
        case .connecting:
            return .secondary
        case .connected:
            return peer.isSuspect ? .orange : .secondary
        }
    }

    private var iconColor: Color {
        switch peer.state {
        case .connected: return peer.isSuspect ? .orange : .green
        case .connecting: return peer.hasBeenConnected ? .orange : .accentColor
        case .discovered: return peer.isAwaitingReconnect ? .orange : .secondary
        }
    }
}
