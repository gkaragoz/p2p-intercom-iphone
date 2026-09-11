import SwiftUI

/// Every iPhone running Intercom that has been seen nearby, with its connection state.
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
                .foregroundStyle(peer.state == .connected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.body)
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch peer.state {
            case .discovered:
                Button("Connect") {
                    controller.connect(to: peer)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
    }

    private var stateText: LocalizedStringKey {
        switch peer.state {
        case .discovered: return "Discovered"
        case .connecting: return "Connecting…"
        case .connected:
            if let version = peer.appVersion {
                return "Connected · v\(version)"
            }
            return "Connected"
        }
    }
}
