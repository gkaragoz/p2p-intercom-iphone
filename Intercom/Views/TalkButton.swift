import SwiftUI
import UIKit

/// The big round button. In push-to-talk mode it transmits while held; in the other modes a tap
/// toggles mute.
struct TalkButton: View {
    @EnvironmentObject private var controller: IntercomController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPressing = false
    /// Whether the current press began as a push-to-talk hold; a mode change mid-press must not
    /// turn the release into a mute toggle.
    @State private var pressIsTalkHold = false

    var diameter: CGFloat = 176

    private var mode: TransmitMode { settings.transmitMode }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .shadow(color: fillColor.opacity(controller.isSending ? 0.55 : 0.25), radius: controller.isSending ? 24 : 10)
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 4)
            VStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 40, weight: .semibold))
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 16)
            }
            .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
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
        // A drag that is cancelled (incoming call, Control Center, app switcher) ends without
        // `onEnded`, so reset the visual state whenever the hold is released elsewhere.
        .onChange(of: scenePhase) { phase in
            if phase != .active { cancelPress() }
        }
        .onChange(of: controller.isRunning) { running in
            if !running { cancelPress() }
        }
        .onChange(of: controller.isTalkButtonHeld) { held in
            if !held, pressIsTalkHold { cancelPress() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Start talking")) {
            guard controller.isRunning, mode == .pushToTalk else { return }
            controller.pressTalkButton()
        }
        .accessibilityAction(named: Text("Stop talking")) {
            controller.releaseTalkButton()
        }
        .accessibilityAction(named: Text(controller.isMuted ? "Unmute" : "Mute")) {
            guard controller.isRunning else { return }
            controller.toggleMute()
        }
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
        pressIsTalkHold = mode == .pushToTalk && !controller.isMuted
        if pressIsTalkHold {
            controller.pressTalkButton()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func release() {
        guard isPressing else { return }
        isPressing = false
        let wasTalkHold = pressIsTalkHold
        pressIsTalkHold = false
        guard controller.isRunning else { return }
        if wasTalkHold {
            if controller.isTalkButtonHeld {
                controller.releaseTalkButton()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } else if mode != .pushToTalk {
            controller.toggleMute()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func cancelPress() {
        guard isPressing || pressIsTalkHold else { return }
        isPressing = false
        pressIsTalkHold = false
        controller.releaseTalkButton()
    }
}
