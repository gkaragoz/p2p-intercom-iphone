import AVFoundation
import Foundation
import os

/// Owns the shared `AVAudioSession` configuration for full-duplex voice chat and reports
/// route changes (AirPods connected / removed), interruptions (phone calls) and media server resets.
///
/// Thread-safety: `AVAudioSession` is thread-safe. `activate()` blocks (it talks to the media
/// server), so the audio engine calls it on its own queue, never on the main thread. Callbacks run
/// on the thread that posted the notification.
final class AudioSessionController: @unchecked Sendable {
    struct Route: Equatable {
        var outputName: String
        var inputName: String
        var outputPortType: AVAudioSession.Port

        static let unknown = Route(outputName: "", inputName: "", outputPortType: .builtInSpeaker)

        var isBluetooth: Bool {
            outputPortType == .bluetoothHFP || outputPortType == .bluetoothA2DP || outputPortType == .bluetoothLE
        }

        var isWiredHeadset: Bool {
            outputPortType == .headphones
        }

        var isSpeaker: Bool {
            outputPortType == .builtInSpeaker
        }

        var isReceiver: Bool {
            outputPortType == .builtInReceiver
        }

        /// The AirPods microphone is only reachable through the hands-free profile.
        var isHandsFreeProfile: Bool {
            outputPortType == .bluetoothHFP
        }
    }

    enum Interruption: Equatable {
        case began
        case ended(shouldResume: Bool)
    }

    /// Preferred hardware I/O buffer. Deliberately its own constant, not the 20 ms wire frame: the I/O
    /// buffer adds its duration to both capture and playback delay, and the capture worker and the
    /// jitter buffer cope with any block size. 10 ms halves that cost against 20 ms at a modest CPU
    /// price. iOS treats it as a hint (it may round, or impose more, e.g. with Sound Recognition on);
    /// the actual value is read back into `metrics`.
    static let preferredIOBufferDuration: TimeInterval = 0.010

    /// Route changes; set by `IntercomController`.
    var onRouteChange: (@Sendable (Route, AVAudioSession.RouteChangeReason) -> Void)?
    /// Interruptions; set by `AudioEngineController`, which must see them before any thread hop.
    var onInterruption: (@Sendable (Interruption) -> Void)?
    /// `mediaServicesWereReset`; set by `AudioEngineController`.
    var onMediaServicesReset: (@Sendable () -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private static let log = Logger(subsystem: "intercom", category: "audio.session")

    private static let category: AVAudioSession.Category = .playAndRecord
    private static let mode: AVAudioSession.Mode = .voiceChat

    deinit {
        stopObserving()
    }

    /// Configures and activates the session for two-way voice. Idempotent: safe (and intended) to
    /// call before every engine (re)start.
    ///
    /// * `.playAndRecord` + `.voiceChat`: enables the low-latency voice-processing I/O unit
    ///   (echo cancellation, gain control) and routes to a headset when one is connected.
    /// * `.allowBluetoothHFP`: permits the Bluetooth hands-free profile, which is the only way to
    ///   use the AirPods microphone. A2DP is deliberately *not* allowed so iOS never picks
    ///   high-quality one-way output plus the iPhone's own microphone.
    /// * `.defaultToSpeaker`: without a headset, play through the loudspeaker instead of the earpiece.
    ///
    /// The category is re-applied whenever it differs from the above, because a media services reset
    /// (or anything else in the process) can leave the session with the default category, and
    /// activating that would silently record nothing.
    func activate() throws {
        let options = Self.categoryOptions
        if session.category != Self.category || session.mode != Self.mode || session.categoryOptions != options {
            Self.log.notice("applying category playAndRecord/voiceChat (was \(self.session.category.rawValue, privacy: .public)/\(self.session.mode.rawValue, privacy: .public), options \(self.session.categoryOptions.rawValue, privacy: .public))")
            try session.setCategory(Self.category, mode: Self.mode, options: options)
        }
        if abs(session.preferredIOBufferDuration - Self.preferredIOBufferDuration) > 0.0005 {
            do {
                try session.setPreferredIOBufferDuration(Self.preferredIOBufferDuration)
            } catch {
                // Only a preference; the session works with whatever buffer it gets.
                Self.log.error("setPreferredIOBufferDuration failed: \(String(describing: error), privacy: .public)")
            }
        }
        if !session.prefersNoInterruptionsFromSystemAlerts {
            do {
                // Ringtones and alerts of a call shown as a banner no longer interrupt the intercom;
                // only accepting the call does. (No effect with the full-screen call style.)
                try session.setPrefersNoInterruptionsFromSystemAlerts(true)
            } catch {
                Self.log.error("setPrefersNoInterruptionsFromSystemAlerts failed: \(String(describing: error), privacy: .public)")
            }
        }
        try session.setActive(true, options: [])
    }

    /// The iOS 26 SDK renamed `.allowBluetooth` to `.allowBluetoothHFP` (same value); older SDKs
    /// only know the old name. Swift 6.2 ships with Xcode 26.
    private static var categoryOptions: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return [.allowBluetoothHFP, .defaultToSpeaker]
        #else
        return [.allowBluetooth, .defaultToSpeaker]
        #endif
    }

    func deactivate() {
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            Self.log.error("deactivation failed: \(String(describing: error), privacy: .public)")
        }
    }

    var currentRoute: Route {
        let route = session.currentRoute
        let output = route.outputs.first
        let input = route.inputs.first
        return Route(
            outputName: output?.portName ?? "",
            inputName: input?.portName ?? "",
            outputPortType: output?.portType ?? .builtInSpeaker
        )
    }

    /// What the hardware actually runs at right now.
    var metrics: AudioSessionMetrics {
        AudioSessionMetrics(
            sampleRate: session.sampleRate,
            ioBufferDuration: session.ioBufferDuration,
            preferredIOBufferDuration: session.preferredIOBufferDuration,
            inputLatency: session.inputLatency,
            outputLatency: session.outputLatency
        )
    }

    /// Human-readable summary of the hardware format, for the diagnostics screen.
    var hardwareDescription: String {
        String(format: "%.0f Hz, IO %.1f ms", session.sampleRate, session.ioBufferDuration * 1000)
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let rawReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) ?? .unknown
            let route = self.currentRoute
            Self.log.notice("route changed (reason \(rawReason, privacy: .public)): output \(route.outputPortType.rawValue, privacy: .public), input \(route.inputName.isEmpty ? "none" : "present", privacy: .public), \(self.hardwareDescription, privacy: .public)")
            self.onRouteChange?(route, reason)
        })

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
            guard let self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                let reason = (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt) ?? 0
                Self.log.notice("interruption began (reason \(reason, privacy: .public))")
                self.onInterruption?(.began)
            case .ended:
                let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                Self.log.notice("interruption ended (shouldResume \(options.contains(.shouldResume), privacy: .public))")
                self.onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Self.log.error("media services were reset")
            self?.onMediaServicesReset?()
        })
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
