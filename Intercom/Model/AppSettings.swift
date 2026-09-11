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
    }

    static let jitterRangeMs: ClosedRange<Double> = 20...300
    static let voxThresholdRange: ClosedRange<Double> = -60...(-10)

    @Published var displayName: String {
        didSet { defaults.set(displayName, forKey: Key.displayName) }
    }

    @Published var transmitMode: TransmitMode {
        didSet { defaults.set(transmitMode.rawValue, forKey: Key.transmitMode) }
    }

    /// Playout delay in milliseconds; larger absorbs more jitter but adds latency.
    @Published var jitterTargetMs: Double {
        didSet { defaults.set(jitterTargetMs, forKey: Key.jitterTargetMs) }
    }

    /// Microphone level (dBFS) above which voice-activated mode starts transmitting.
    @Published var voxThresholdDB: Double {
        didSet { defaults.set(voxThresholdDB, forKey: Key.voxThresholdDB) }
    }

    @Published var outputVolume: Double {
        didSet { defaults.set(outputVolume, forKey: Key.outputVolume) }
    }

    @Published var keepScreenAwake: Bool {
        didSet { defaults.set(keepScreenAwake, forKey: Key.keepScreenAwake) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayName = defaults.string(forKey: Key.displayName) ?? Self.defaultDisplayName(defaults: defaults)
        transmitMode = defaults.string(forKey: Key.transmitMode).flatMap(TransmitMode.init(rawValue:)) ?? .pushToTalk
        jitterTargetMs = (defaults.object(forKey: Key.jitterTargetMs) as? Double) ?? 60
        voxThresholdDB = (defaults.object(forKey: Key.voxThresholdDB) as? Double) ?? -38
        outputVolume = (defaults.object(forKey: Key.outputVolume) as? Double) ?? 1
        keepScreenAwake = (defaults.object(forKey: Key.keepScreenAwake) as? Bool) ?? true
    }

    var jitterConfiguration: JitterBuffer.Configuration {
        Self.jitterConfiguration(targetMs: jitterTargetMs)
    }

    static func jitterConfiguration(targetMs: Double) -> JitterBuffer.Configuration {
        var configuration = JitterBuffer.Configuration.default
        let frames = Int((targetMs / (IntercomProtocol.frameDuration * 1000)).rounded())
        configuration.targetDelayFrames = max(1, frames)
        configuration.maxDelayFrames = max(configuration.targetDelayFrames + 4, 12)
        return configuration
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
