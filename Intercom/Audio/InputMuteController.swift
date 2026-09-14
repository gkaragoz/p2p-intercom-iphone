import AVFoundation
import Foundation
import os

/// Keeps the app's mute button and the system's input mute (iOS 17+) in step.
///
/// Since iOS 17 the system can mute an app's microphone itself: the AirPods stem press (or the
/// Control Center mic mode) zeroes the input samples of every audio client of the app and posts
/// `AVAudioApplication.inputMuteStateChangeNotification`. Without listening to it the app would show
/// "unmuted" while the peer hears nothing. In the other direction the app's own mute calls
/// `setInputMuted`, so the system state (and the AirPods tone) matches.
///
/// `setInputMuteStateChangeHandler` is macOS only; on iOS the notification is the API. The
/// notification is only posted while a record session is active; a value set while inactive is
/// stored and applied (and notified) when the session next goes active.
///
/// The transmit gate stays muted too: in open-line mode it keeps zeroed frames off the network, and
/// the talk state sent to the peer stays accurate.
final class InputMuteController: @unchecked Sendable {
    /// Called with the new system mute state, on the notification's thread.
    var onSystemMuteChange: (@Sendable (Bool) -> Void)?

    private var observer: NSObjectProtocol?
    private static let log = Logger(subsystem: "intercom", category: "audio")

    deinit {
        stop()
    }

    var isSystemMuted: Bool {
        AVAudioApplication.shared.isInputMuted
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let muted = (notification.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue
                ?? AVAudioApplication.shared.isInputMuted
            Self.log.notice("system input mute changed: \(muted, privacy: .public)")
            self?.onSystemMuteChange?(muted)
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    /// Applies the app's mute to the system input. No-op when it already matches.
    func setSystemMuted(_ muted: Bool) {
        let application = AVAudioApplication.shared
        guard application.isInputMuted != muted else { return }
        do {
            try application.setInputMuted(muted)
            Self.log.notice("system input mute set to \(muted, privacy: .public)")
        } catch {
            Self.log.error("setInputMuted(\(muted, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
