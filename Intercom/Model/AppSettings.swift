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
        static let wireRate = "settings.wireRate"
        static let latencyProfile = "settings.latencyProfile"
        static let transmitEffect = "settings.transmitEffect"
        static let transmitEQ = "settings.transmitEQ"
        static let playbackEQ = "settings.playbackEQ"
        static let sidetone = "settings.sidetone"
        static let sidetoneLevel = "settings.sidetoneLevel"
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

    /// Audio quality: the sample rate captured, sent over the wire and played back, in both
    /// directions. Rates other than the standard 16 kHz need this version of the app on both phones;
    /// with an older peer the controller falls back to the standard rate on its own.
    @Published var wireRate: WireRate {
        didSet { defaults.set(wireRate.rawValue, forKey: Key.wireRate) }
    }

    /// How much delay is traded for robustness: bounds the automatic playout delay and sets the
    /// hardware I/O buffer. The fixed playout slider is independent of it.
    @Published var latencyProfile: LatencyProfile {
        didSet { defaults.set(latencyProfile.rawValue, forKey: Key.latencyProfile) }
    }

    /// Voice effect on this microphone: what the *peer* hears. Applied before sending.
    @Published var transmitEffect: VoiceEffectPreset {
        didSet { defaults.set(transmitEffect.rawValue, forKey: Key.transmitEffect) }
    }

    /// Equaliser on this microphone: what the *peer* hears. Applied before sending, after the effect.
    @Published var transmitEQ: EQPreset {
        didSet { defaults.set(transmitEQ.rawValue, forKey: Key.transmitEQ) }
    }

    /// Equaliser on the peer's voice as heard here. Local only; the peer is not affected.
    @Published var playbackEQ: EQPreset {
        didSet { defaults.set(playbackEQ.rawValue, forKey: Key.playbackEQ) }
    }

    /// Hear the own microphone in the headset with the lowest delay the hardware allows (the raw
    /// microphone, not the effect the peer hears). Off by default. Only sounds on a wired headset or
    /// Bluetooth: on the loudspeaker or the receiver the microphone would pick it up again. A change
    /// rebuilds the audio graph, which the peer hears as a short gap.
    @Published var sidetone: Bool {
        didSet { defaults.set(sidetone, forKey: Key.sidetone) }
    }

    /// Sidetone gain, 0...1. Half by default: loud enough to hear oneself, quiet enough not to
    /// drown the peer.
    @Published var sidetoneLevel: Double {
        didSet { defaults.set(sidetoneLevel, forKey: Key.sidetoneLevel) }
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
        wireRate = defaults.string(forKey: Key.wireRate).flatMap(WireRate.init(rawValue:)) ?? .standard
        latencyProfile = defaults.string(forKey: Key.latencyProfile).flatMap(LatencyProfile.init(rawValue:)) ?? .balanced
        transmitEffect = defaults.string(forKey: Key.transmitEffect).flatMap(VoiceEffectPreset.init(rawValue:)) ?? .off
        transmitEQ = defaults.string(forKey: Key.transmitEQ).flatMap(EQPreset.init(rawValue:)) ?? .off
        playbackEQ = defaults.string(forKey: Key.playbackEQ).flatMap(EQPreset.init(rawValue:)) ?? .off
        sidetone = (defaults.object(forKey: Key.sidetone) as? Bool) ?? false
        sidetoneLevel = min(max((defaults.object(forKey: Key.sidetoneLevel) as? Double) ?? 0.5, 0), 1)
    }

    /// The jitter buffer for the *wanted* wire rate. The controller uses the static form with the
    /// rate actually in effect, which a legacy peer can pin to the standard rate.
    var jitterConfiguration: JitterBuffer.Configuration {
        Self.jitterConfiguration(targetMs: jitterTargetMs, adaptive: playoutAuto, wireRate: wireRate,
                                 profile: latencyProfile)
    }

    /// `JitterBuffer.Configuration.intercom` (Core, pinned by a test: `(.standard, .balanced)` is the
    /// pre-preset configuration exactly).
    ///
    /// - Parameters:
    ///   - targetMs: fixed playout delay, used when `adaptive` is off.
    ///   - adaptive: follow `PlayoutDelayEstimator` between the profile's floor and ceiling.
    ///   - wireRate: frame size, sample rate and crossfade length of the buffer.
    ///   - profile: bounds of the adaptive estimator.
    static func jitterConfiguration(targetMs: Double, adaptive: Bool, wireRate: WireRate,
                                    profile: LatencyProfile) -> JitterBuffer.Configuration {
        .intercom(targetMs: targetMs, adaptive: adaptive, wireRate: wireRate, profile: profile)
    }

    /// The engine configuration for the *wanted* wire rate; see `audioEngineConfiguration(wireRate:)`.
    var audioEngineConfiguration: AudioEngineController.Configuration {
        audioEngineConfiguration(wireRate: wireRate)
    }

    /// The engine configuration with `wireRate` in place of the setting, for the rate actually in
    /// effect (a legacy peer pins it to the standard rate).
    func audioEngineConfiguration(wireRate: WireRate) -> AudioEngineController.Configuration {
        AudioEngineController.Configuration(captureMode: captureMode,
                                            voiceProcessing: voiceProcessingEnabled,
                                            wireRate: wireRate,
                                            ioBufferDuration: latencyProfile.ioBufferDuration,
                                            transmitEffect: transmitEffect,
                                            transmitEQ: transmitEQ,
                                            sidetone: sidetone)
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
