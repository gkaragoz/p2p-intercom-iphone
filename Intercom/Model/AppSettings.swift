import Combine
import Foundation
import UIKit

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let displayName = "settings.displayName"
        static let transmitMode = "settings.transmitMode"
        static let jitterTargetMs = "settings.jitterTargetMs"
        static let voxThresholdDB = "settings.voxThresholdDB"
        static let outputVolume = "settings.outputVolume"
        static let keepScreenAwake = "settings.keepScreenAwake"
        static let nameSuffix = "settings.nameSuffix"
        static let transportKind = "settings.transportKind"
        static let pairingCode = "settings.pairingCode"
        static let playoutAuto = "settings.playoutAuto"
        static let captureMode = "settings.captureMode"
        static let voiceProcessing = "settings.voiceProcessing"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let audioCuesEnabled = "settings.audioCuesEnabled"
    }

    static let jitterRangeMs: ClosedRange<Double> = 20...300
    static let voxThresholdRange: ClosedRange<Double> = -60...(-10)

    @Published var displayName: String {
        didSet { defaults.set(displayName, forKey: Key.displayName) }
    }

    @Published var transmitMode: TransmitMode {
        didSet { defaults.set(transmitMode.rawValue, forKey: Key.transmitMode) }
    }

    /// Playout delay in milliseconds; larger absorbs more jitter but adds latency. Used when
    /// `playoutAuto` is off.
    @Published var jitterTargetMs: Double {
        didSet { defaults.set(jitterTargetMs, forKey: Key.jitterTargetMs) }
    }

    /// Let the jitter buffer size its playout delay from the measured network jitter (40–200 ms)
    /// instead of the fixed `jitterTargetMs`.
    @Published var playoutAuto: Bool {
        didSet { defaults.set(playoutAuto, forKey: Key.playoutAuto) }
    }

    /// Low latency (sink node) or compatible (input tap) microphone capture.
    @Published var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Key.captureMode) }
    }

    /// Echo cancellation and automatic gain control. Off only makes sense with headphones.
    @Published var voiceProcessingEnabled: Bool {
        didSet { defaults.set(voiceProcessingEnabled, forKey: Key.voiceProcessing) }
    }

    /// Microphone level (dBFS) above which voice-activated mode starts transmitting.
    @Published var voxThresholdDB: Double {
        didSet { defaults.set(voxThresholdDB, forKey: Key.voxThresholdDB) }
    }

    @Published var outputVolume: Double {
        didSet { defaults.set(outputVolume, forKey: Key.outputVolume) }
    }

    /// Off by default: audio keeps flowing with the screen off or locked, and Apple asks audio apps not
    /// to disable the idle timer. Only applies while the app is in the foreground anyway.
    @Published var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    /// Silent local notifications while the app is in the background: connection lost/reconnected and
    /// "audio paused – open Intercom".
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// Short tones in the intercom's own output when the link connects, is lost or comes back.
    @Published var audioCuesEnabled: Bool {
        didSet { defaults.set(audioCuesEnabled, forKey: Key.audioCuesEnabled) }
    }

    /// Connection engine. Both phones must use the same one.
    @Published var transportKind: TransportKind {
        didSet { defaults.set(transportKind.rawValue, forKey: Key.transportKind) }
    }

    /// Shared secret the Network engine derives its encryption keys from. Both phones must use the same
    /// code; empty means the built-in default key (works out of the box, but is not private).
    @Published var pairingCode: String {
        didSet { defaults.set(pairingCode, forKey: Key.pairingCode) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayName = defaults.string(forKey: Key.displayName) ?? Self.defaultDisplayName(defaults: defaults)
        transmitMode = defaults.string(forKey: Key.transmitMode).flatMap(TransmitMode.init(rawValue:)) ?? .pushToTalk
        jitterTargetMs = (defaults.object(forKey: Key.jitterTargetMs) as? Double) ?? 60
        playoutAuto = (defaults.object(forKey: Key.playoutAuto) as? Bool) ?? true
        captureMode = defaults.string(forKey: Key.captureMode).flatMap(CaptureMode.init(rawValue:)) ?? .lowLatency
        voiceProcessingEnabled = (defaults.object(forKey: Key.voiceProcessing) as? Bool) ?? true
        voxThresholdDB = (defaults.object(forKey: Key.voxThresholdDB) as? Double) ?? -38
        outputVolume = (defaults.object(forKey: Key.outputVolume) as? Double) ?? 1
        keepScreenAwake = (defaults.object(forKey: Key.keepScreenAwake) as? Bool) ?? false
        notificationsEnabled = (defaults.object(forKey: Key.notificationsEnabled) as? Bool) ?? true
        audioCuesEnabled = (defaults.object(forKey: Key.audioCuesEnabled) as? Bool) ?? true
        transportKind = defaults.string(forKey: Key.transportKind).flatMap(TransportKind.init(rawValue:)) ?? .network
        pairingCode = defaults.string(forKey: Key.pairingCode) ?? ""
    }

    var jitterConfiguration: JitterBuffer.Configuration {
        Self.jitterConfiguration(targetMs: jitterTargetMs, adaptive: playoutAuto)
    }

    /// - Parameters:
    ///   - targetMs: fixed playout delay, used when `adaptive` is off.
    ///   - adaptive: follow `PlayoutDelayEstimator` (40–200 ms); the cap is raised to fit its ceiling.
    static func jitterConfiguration(targetMs: Double, adaptive: Bool) -> JitterBuffer.Configuration {
        var configuration = JitterBuffer.Configuration.default
        let frames = Int((targetMs / (IntercomProtocol.frameDuration * 1000)).rounded())
        configuration.targetDelayFrames = max(1, frames)
        configuration.adaptiveTarget = adaptive
        configuration.maxDelayFrames = max(configuration.targetDelayFrames + 4, 12)
        return configuration.normalized()
    }

    var audioEngineConfiguration: AudioEngineController.Configuration {
        AudioEngineController.Configuration(captureMode: captureMode, voiceProcessing: voiceProcessingEnabled)
    }

    /// Since iOS 16 `UIDevice.name` is just "iPhone" for most apps, so a short random suffix is
    /// appended once and remembered, making the two phones distinguishable in the peer list.
    private static func defaultDisplayName(defaults: UserDefaults) -> String {
        let base = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["iPhone", "iPad", "iPod", ""]
        guard generic.contains(base) else { return DisplayName.sanitized(base) }
        let suffix: String
        if let stored = defaults.string(forKey: Key.nameSuffix) {
            suffix = stored
        } else {
            suffix = String(format: "%02d", Int.random(in: 0...99))
            defaults.set(suffix, forKey: Key.nameSuffix)
        }
        return DisplayName.sanitized("\(base.isEmpty ? "iPhone" : base) \(suffix)")
    }
}
