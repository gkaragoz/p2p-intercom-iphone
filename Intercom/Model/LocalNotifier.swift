import Foundation
import os
import UserNotifications

/// Shows the few local notifications the intercom posts while the app is not active ("connection
/// lost", "reconnected", "audio paused").
///
/// Local notifications need no capability, entitlement, push or internet, so they work on a free
/// Personal Team with both phones offline. They are silent on purpose: a notification sound would
/// duck or interrupt the voice session, and the audio cues already cover the ear.
///
/// Without a `UNUserNotificationCenterDelegate` iOS does not present notifications while the app is
/// in the foreground, which is exactly right: the app itself shows the state then.
@MainActor
final class LocalNotifier {
    private let center = UNUserNotificationCenter.current()
    private static let log = Logger(subsystem: "intercom", category: "notifications")

    /// Asks for permission once; later calls do nothing. Call only while the app is in the foreground:
    /// the prompt cannot appear from the background. `completion` runs once the answer is known (at
    /// once when permission was decided earlier).
    func requestAuthorizationIfNeeded(completion: (@MainActor () -> Void)? = nil) {
        let center = self.center
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    let granted = try await center.requestAuthorization(options: [.alert])
                    Self.log.notice("notification permission \(granted ? "granted" : "denied", privacy: .public)")
                } catch {
                    Self.log.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            completion?()
        }
    }

    /// The person turned notifications off for Intercom (at the prompt or later in Settings): posting
    /// silently does nothing until they turn them back on there.
    func isAuthorizationDenied() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    /// Posts `notice` now, replacing whatever is shown in its slot. `completion` runs once the system
    /// accepted (or rejected) the request.
    func post(_ notice: SessionNotice, completion: (@MainActor () -> Void)? = nil) {
        let content = UNMutableNotificationContent()
        content.body = Self.body(for: notice)
        content.sound = nil
        content.threadIdentifier = "intercom"
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: Self.identifier(for: notice.slot), content: content, trigger: nil)
        let kind = Self.kind(of: notice)
        let center = self.center
        Task {
            do {
                try await center.add(request)
                Self.log.notice("notification \(kind, privacy: .public) posted")
            } catch {
                Self.log.error("notification \(kind, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            completion?()
        }
    }

    func remove(_ slot: SessionNotice.Slot) {
        let identifiers = [Self.identifier(for: slot)]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAll() {
        for slot in SessionNotice.Slot.allCases {
            remove(slot)
        }
    }

    private static func identifier(for slot: SessionNotice.Slot) -> String {
        "intercom.\(slot.rawValue)"
    }

    private static func kind(of notice: SessionNotice) -> String {
        switch notice {
        case .connectionLost: return "connectionLost"
        case .reconnected: return "reconnected"
        case .audioPaused: return "audioPaused"
        }
    }

    private static func body(for notice: SessionNotice) -> String {
        switch notice {
        case .connectionLost(let name?):
            return String(localized: "Connection lost – reconnecting to \(name)")
        case .connectionLost(nil):
            return String(localized: "Connection lost – reconnecting")
        case .reconnected(let name?):
            return String(localized: "Reconnected to \(name)")
        case .reconnected(nil):
            return String(localized: "Reconnected")
        case .audioPaused:
            return String(localized: "Audio paused – open Intercom to resume")
        }
    }
}
