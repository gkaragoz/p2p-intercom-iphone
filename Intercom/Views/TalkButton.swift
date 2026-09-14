import SwiftUI
import UIKit

/// The big round button. In push-to-talk mode it transmits while held; in the other modes a tap
/// toggles mute. A push-to-talk latch (set from the Live Activity or with VoiceOver) keeps it
/// transmitting without a hold; a tap releases the latch.
struct TalkButton: View {
    @EnvironmentObject private var controller: IntercomController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPressing = false
    /// Whether the current press began as a push-to-talk hold; a mode change mid-press must not
    /// turn the release into a mute toggle.
    @State private var pressIsTalkHold = false
    /// The hold was dropped (mode change, interruption) while the finger was still down; the rest
    /// of this touch is inert so lifting the finger does not toggle mute.
    @State private var pressConsumed = false
    /// SwiftUI resets gesture state on gesture END *and* CANCEL, which is the only signal a
    /// cancelled touch (incoming call, Control Center, app switcher) produces.
    @GestureState private var touchIsDown = false

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
                .updating($touchIsDown) { _, state, _ in state = true }
                .onChanged { _ in press() }
                .onEnded { _ in release() }
        )
        // A cancelled drag never calls `onEnded`; the gesture state reset is the only signal.
        // After a normal release this is a no-op because `release()` already ran.
        .onChange(of: touchIsDown) { _, down in
            if !down { cancelPress() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelPress() }
        }
        .onChange(of: controller.isRunning) { _, running in
            if !running { cancelPress() }
        }
        .onChange(of: controller.isTalkButtonHeld) { _, held in
            // The hold ended while the finger is still down (mode change, interruption): keep
            // `isPressing` so `press()` cannot re-arm, and make the eventual release inert.
            if !held, pressIsTalkHold {
                pressIsTalkHold = false
                pressConsumed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Start talking")) {
            guard controller.isRunning, mode == .pushToTalk else { return }
            controller.pressTalkButton()
        }
        .accessibilityAction(named: Text("Talk without holding")) {
            guard controller.isRunning, mode == .pushToTalk, !controller.isMuted else { return }
            controller.setTalkLatched(true)
        }
        .accessibilityAction(named: Text("Stop talking")) {
            controller.releaseTalkButton()
            controller.setTalkLatched(false)
        }
        .accessibilityAction(named: Text(muteActionLabel)) {
            guard controller.isRunning else { return }
            controller.toggleMute()
        }
    }

    private var muteActionLabel: LocalizedStringKey {
        controller.isMuted ? "Unmute" : "Mute"
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
        if controller.isTalkLatched, mode == .pushToTalk { return "lock.fill" }
        if controller.isSending { return "dot.radiowaves.left.and.right" }
        return mode.systemImage
    }

    private var label: LocalizedStringKey {
        switch mode {
        case .pushToTalk:
            if controller.isMuted { return "Muted" }
            if controller.isTalkLatched, !controller.isTalkButtonHeld { return "Tap to stop talking" }
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
        if mode == .pushToTalk, controller.isTalkLatched {
            // A tap on a latched button ends the latch; the rest of this touch does nothing, so
            // holding on does not start a new transmission by accident.
            controller.setTalkLatched(false)
            pressConsumed = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
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
        let consumed = pressConsumed
        pressIsTalkHold = false
        pressConsumed = false
        guard controller.isRunning, !consumed else { return }
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

    /// Full reset for touches that will never deliver `onEnded`.
    private func cancelPress() {
        guard isPressing || pressIsTalkHold || pressConsumed else { return }
        isPressing = false
        pressIsTalkHold = false
        pressConsumed = false
        controller.releaseTalkButton()
    }
}
