import AVFoundation
import Foundation

/// Owns the shared `AVAudioSession` configuration for full-duplex voice chat and reports
/// route changes (AirPods connected / removed) and interruptions (phone calls).
final class AudioSessionController {
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

    var onRouteChange: (@Sendable (Route, AVAudioSession.RouteChangeReason) -> Void)?
    var onInterruption: (@Sendable (Interruption) -> Void)?
    var onMediaServicesReset: (@Sendable () -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []

    deinit {
        stopObserving()
    }

    /// Configures and activates the session for two-way voice.
    ///
    /// * `.playAndRecord` + `.voiceChat`: enables the low-latency voice-processing I/O unit
    ///   (echo cancellation, gain control) and routes to a headset when one is connected.
    /// * `.allowBluetooth`: permits the Bluetooth hands-free profile, i.e. the AirPods microphone.
    /// * `.allowBluetoothA2DP`: keeps high-quality Bluetooth output available; when both options
    ///   are set iOS prefers HFP while recording, which is what a two-way intercom needs.
    /// * `.defaultToSpeaker`: without a headset, play through the loudspeaker instead of the earpiece.
    func activate() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setPreferredIOBufferDuration(IntercomProtocol.frameDuration)
        try session.setActive(true, options: [])
    }

    /// Re-activates the session after an interruption without touching the category.
    func reactivate() throws {
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
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
            self.onRouteChange?(self.currentRoute, reason)
        })

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
            guard let self,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                self.onInterruption?(.began)
            case .ended:
                let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                self.onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
            @unknown default:
                break
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            self?.onMediaServicesReset?()
        })
    }

    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
