import SwiftUI

/// Live microphone and playback meters with talk indicators for both sides.
struct MetersCard: View {
    @EnvironmentObject private var controller: IntercomController
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            meterRow(
                title: "You",
                symbol: controller.isMuted ? "mic.slash.fill" : "mic.fill",
                level: controller.inputMeter,
                marker: voxMarker,
                badge: localBadge,
                badgeColor: controller.isSending ? .green : .secondary,
                tint: .green
            )
            meterRow(
                title: "Peer",
                symbol: "speaker.wave.2.fill",
                level: controller.outputMeter,
                marker: nil,
                badge: remoteBadge,
                badgeColor: controller.remoteTalking ? .green : .secondary,
                tint: .blue
            )
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    private func meterRow(title: LocalizedStringKey,
                          symbol: String,
                          level: Float,
                          marker: Float?,
                          badge: LocalizedStringKey,
                          badgeColor: Color,
                          tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(badgeColor.opacity(0.15)))
            }
            LevelMeterView(level: level, marker: marker, tint: tint)
        }
    }

    private var voxMarker: Float? {
        guard settings.transmitMode == .voiceActivated else { return nil }
        return AudioLevel.meterValue(dB: Float(settings.voxThresholdDB))
    }

    private var localBadge: LocalizedStringKey {
        if controller.isMuted { return "Muted" }
        if controller.isSending { return "Sending" }
        if settings.transmitMode == .voiceActivated, controller.isVoiceDetected { return "Voice detected" }
        return "Silent"
    }

    private var remoteBadge: LocalizedStringKey {
        if controller.connectedPeers.isEmpty { return "Not connected" }
        if controller.remoteMuted { return "Peer muted" }
        return controller.remoteTalking ? "Talking" : "Silent"
    }
}
