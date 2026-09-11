import SwiftUI
import UIKit

/// Connection state, audio route and round-trip time at a glance, plus the primary action for
/// states that need one (start, retry, open Settings for the microphone permission).
struct StatusCard: View {
    @EnvironmentObject private var controller: IntercomController
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isBusy {
                    ProgressView()
                }
            }

            if let error = controller.lastError, controller.phase != .connected {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            actionButton

            Divider()

            HStack(spacing: 16) {
                Label {
                    Text(routeName)
                } icon: {
                    Image(systemName: routeSymbol)
                }
                Spacer()
                if let rtt = controller.roundTripMs {
                    Label {
                        Text(verbatim: "\(Int(rtt.rounded())) ms")
                    } icon: {
                        Image(systemName: "timer")
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private var actionButton: some View {
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
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        switch controller.phase {
        case .requestingPermission, .starting, .searching:
            return true
        default:
            return false
        }
    }

    private var title: LocalizedStringKey {
        switch controller.phase {
        case .idle: return "Idle"
        case .requestingPermission: return "Requesting microphone access…"
        case .permissionDenied: return "Microphone access denied"
        case .starting: return "Starting audio…"
        case .searching: return "Searching for nearby iPhones…"
        case .connected:
            let names = controller.connectedPeers.map(\.name).joined(separator: ", ")
            return "Connected to \(names)"
        case .failed: return "Could not start"
        }
    }

    private var subtitle: LocalizedStringKey {
        switch controller.phase {
        case .idle: return "Tap Start to look for the other iPhone."
        case .requestingPermission, .starting: return "One moment…"
        case .permissionDenied: return "Allow the microphone in Settings to talk."
        case .searching: return "Both iPhones must be on the same Wi‑Fi, or have Wi‑Fi and Bluetooth turned on."
        case .connected:
            if controller.remoteMuted { return "Peer muted" }
            return controller.remoteTalking ? "Peer is talking" : "Ready"
        case .failed: return "Check the microphone and try again."
        }
    }

    private var statusSymbol: String {
        switch controller.phase {
        case .connected: return controller.remoteTalking ? "waveform.circle.fill" : "checkmark.circle.fill"
        case .searching: return "antenna.radiowaves.left.and.right"
        case .permissionDenied, .failed: return "exclamationmark.triangle.fill"
        default: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .connected: return .green
        case .searching: return .accentColor
        case .permissionDenied, .failed: return .red
        default: return .secondary
        }
    }

    private var routeName: LocalizedStringKey {
        let name = controller.route.outputName
        return name.isEmpty ? "Speaker" : LocalizedStringKey(name)
    }

    private var routeSymbol: String {
        let route = controller.route
        if route.isBluetooth { return "airpods" }
        if route.isWiredHeadset { return "headphones" }
        if route.isReceiver { return "iphone" }
        return "speaker.wave.2.fill"
    }
}
