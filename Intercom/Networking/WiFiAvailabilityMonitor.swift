import Foundation
import Network
import os

/// Reports whether any Wi-Fi interface is available, for the "Wi-Fi must be on" hint.
///
/// The intercom needs the Wi-Fi radio on but no network: peer-to-peer Wi-Fi works unjoined. The path
/// monitor only lists interfaces that can carry traffic, so an unjoined Wi-Fi also reads as
/// unavailable; the hint therefore states the requirement rather than claiming Wi-Fi is off, and it is
/// only shown while no link is up (a link proves the radio works). Never drives connection logic.
final class WiFiAvailabilityMonitor: @unchecked Sendable {
    /// Called on the monitor's queue with the new value, only when it changes.
    var onChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "intercom.wifi-monitor", qos: .utility)
    private let monitor = NWPathMonitor()
    // queue only
    private var lastValue: Bool?
    private static let log = Logger(subsystem: "intercom", category: "controller")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    private func update(_ path: NWPath) {
        let available = path.availableInterfaces.contains { $0.type == .wifi }
        guard available != lastValue else { return }
        lastValue = available
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
        Self.log.notice("wifi interface available: \(available, privacy: .public) (interfaces: \(interfaces, privacy: .public))")
        onChange?(available)
    }
}
