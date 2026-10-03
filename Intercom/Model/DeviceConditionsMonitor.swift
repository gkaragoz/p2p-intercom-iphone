import Foundation
import UIKit

/// Writes the conditions that change how the radio and the CPU behave into the link journal: Low
/// Power Mode, thermal state and battery. A ride leaves the phone in a pocket for hours; this is
/// what explains a stall that has no network cause (the radio throttled, the process starved).
@MainActor
final class DeviceConditionsMonitor {
    private let journal: LinkJournal
    private var tokens: [NSObjectProtocol] = []

    init(journal: LinkJournal = .shared) {
        self.journal = journal
    }

    func start() {
        guard tokens.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        snapshot(reason: "start")
        let changes: [(Notification.Name, String)] = [
            (.NSProcessInfoPowerStateDidChange, "low power mode changed"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal state changed"),
            (UIDevice.batteryStateDidChangeNotification, "battery state changed"),
        ]
        tokens = changes.map { name, reason in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapshot(reason: reason) }
            }
        }
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    private func snapshot(reason: String) {
        journal.record("device", "\(reason): \(Self.summary())")
    }

    /// `battery=87% lowPower=false thermal=nominal`, for the journal and the health line.
    static func summary() -> String {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let level = device.batteryLevel
        let battery = level < 0 ? "-" : "\(Int((level * 100).rounded()))%"
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return "battery=\(battery) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(thermal)"
    }
}
