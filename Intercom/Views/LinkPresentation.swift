import SwiftUI

// User-facing names and symbols for Core link and audio types. Core stays Foundation-only (it is
// tested on Linux), so everything localized about those types lives here in the app target.

extension LinkPath {
    /// Short name for the path chip, the peer list and diagnostics. `nil` when there is nothing
    /// meaningful to show (Multipeer never knows its path).
    var displayName: String? {
        switch self {
        case .peerToPeerWiFi: return String(localized: "Direct Wi‑Fi")
        case .wifiNetwork: return String(localized: "Wi‑Fi network")
        case .wired: return String(localized: "Wired")
        case .other: return String(localized: "Other network")
        case .unknown: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .peerToPeerWiFi: return "point.3.connected.trianglepath.dotted"
        case .wifiNetwork: return "wifi"
        case .wired: return "cable.connector"
        case .other, .unknown: return "network"
        }
    }
}

/// A small capsule naming the network path of the current link ("Direct Wi‑Fi", "Wi‑Fi network").
/// Truncates when squeezed; a row with room to spare pins it with `fixedSize` at the call site (at the
/// largest text sizes nothing is spare, and a fixed chip would push the card off the screen).
struct LinkPathChip: View {
    let path: LinkPath

    var body: some View {
        if let name = path.displayName {
            Label(name, systemImage: path.systemImage)
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(Color.accentColor)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: name))
        }
    }
}

extension TransportKind {
    var displayName: String {
        switch self {
        case .network: return String(localized: "Network")
        case .multipeer: return String(localized: "Multipeer")
        }
    }
}

extension AudioRecoveryMachine.State {
    /// The audio engine state in words, for diagnostics.
    var displayName: String {
        switch self {
        case .stopped: return String(localized: "Stopped")
        case .running: return String(localized: "Running")
        case .interrupted: return String(localized: "Interrupted")
        case .recovering(let attempt): return String(localized: "Restarting (attempt \(attempt))")
        case .needsForeground: return String(localized: "Waiting for the app to open")
        }
    }
}

extension CapturePath {
    var displayName: String {
        switch self {
        case .sinkNode: return String(localized: "Low latency (sink node)")
        case .tap: return String(localized: "Compatible (tap)")
        case .none: return "—"
        }
    }
}
