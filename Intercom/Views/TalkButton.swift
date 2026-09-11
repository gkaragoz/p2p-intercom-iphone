import SwiftUI
import UIKit

/// The big round button. In push-to-talk mode it transmits while held; in the other modes a tap
/// toggles mute.
struct TalkButton: View {
    @EnvironmentObject private var controller: IntercomController
    @EnvironmentObject private var settings: AppSettings
    @State private var isPressing = false

    private var mode: TransmitMode { settings.transmitMode }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .shadow(color: fillColor.opacity(controller.isSending ? 0.55 : 0.25), radius: controller.isSending ? 24 : 10)
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 4)
            VStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 46, weight: .semibold))
                Text(label)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 200, height: 200)
        .scaleEffect(controller.isSending ? 1.06 : (isPressing ? 0.96 : 1))
        .opacity(controller.isRunning ? 1 : 0.45)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: controller.isSending)
        .animation(.easeOut(duration: 0.12), value: isPressing)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isButton)
    }

    private var fillColor: Color {
        if !controller.isRunning { return .gray }
        if controller.isMuted { return .gray }
        if controller.isSending { return .green }
        switch mode {
        case .pushToTalk: return .accentColor
        case .voiceActivated: return .orange
        case .alwaysOn: return .teal
        }
    }

    private var symbolName: String {
        if controller.isMuted { return "mic.slash.fill" }
        if controller.isSending { return "dot.radiowaves.left.and.right" }
        return mode.systemImage
    }

    private var label: LocalizedStringKey {
        switch mode {
        case .pushToTalk:
            if controller.isMuted { return "Muted" }
            return controller.isTalkButtonHeld ? "Talking…" : "Hold to talk"
        case .voiceActivated:
            if controller.isMuted { return "Tap to unmute" }
            return controller.isSending ? "Transmitting" : "Listening for your voice"
        case .alwaysOn:
            if controller.isMuted { return "Tap to unmute" }
            return "Mic is live"
        }
    }

    private func press() {
        guard controller.isRunning, !isPressing else { return }
        isPressing = true
        if mode == .pushToTalk, !controller.isMuted {
            controller.pressTalkButton()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func release() {
        guard isPressing else { return }
        isPressing = false
        guard controller.isRunning else { return }
        if mode == .pushToTalk {
            if controller.isTalkButtonHeld {
                controller.releaseTalkButton()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } else {
            controller.toggleMute()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
