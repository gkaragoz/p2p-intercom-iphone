import Foundation
import os
import Security

/// The one identity of this app installation, independent of the display name and the transport.
///
/// A UUID created on first use. The Network framework transport uses it as the Bonjour instance name
/// and in every HELLO; Multipeer Connectivity advertises it as the election token. Because it never
/// changes (unlike the old per-launch random token), both phones always agree on who invites or dials,
/// even right after one of them relaunched.
///
/// It lives in the Keychain as a this-device-only item, so it is never restored onto another iPhone
/// from a backup or a device-to-device transfer: two phones with the same identity would drop each
/// other as "ourselves" and never connect. `UserDefaults` only keeps a copy for the rare launch where
/// the Keychain cannot be read (before the first unlock, or an unsigned simulator build without
/// Keychain access). Keychain items can outlive deleting the app; a new identity after a reinstall
/// would be harmless too, since the other phone simply sees a new peer.
enum InstallIdentity {
    private static let defaultsKey = "intercom.installID"
    private static let keychainService = "intercom.installID"
    private static let keychainAccount = "installID"
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "intercom", category: "identity")

    static func installID(defaults: UserDefaults = .standard) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let string = String(data: data, encoding: .utf8), let uuid = UUID(uuidString: string) {
            mirror(uuid, in: defaults)
            return uuid
        }
        guard status == errSecItemNotFound || status == errSecSuccess else {
            log.error("Keychain read of the install identity failed (\(status, privacy: .public)); using the stored copy")
            return storedCopy(in: defaults)
        }
        // Not on this device yet. A value in UserDefaults may have come from another iPhone's backup,
        // so it is not adopted: a fresh identity cannot collide.
        if status == errSecSuccess {
            SecItemDelete(baseQuery as CFDictionary)
        }
        let fresh = UUID()
        var attributes = baseQuery
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = Data(fresh.uuidString.lowercased().utf8)
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else {
            log.error("Keychain write of the install identity failed (\(added, privacy: .public)); using the stored copy")
            return storedCopy(in: defaults)
        }
        mirror(fresh, in: defaults)
        log.notice("Created install identity \(fresh.uuidString.lowercased(), privacy: .public)")
        return fresh
    }

    static func peerID(defaults: UserDefaults = .standard) -> PeerID {
        PeerID(installID: installID(defaults: defaults))
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func mirror(_ uuid: UUID, in defaults: UserDefaults) {
        let value = uuid.uuidString.lowercased()
        if defaults.string(forKey: defaultsKey) != value {
            defaults.set(value, forKey: defaultsKey)
        }
    }

    /// The `UserDefaults` copy, created if missing, for launches without Keychain access.
    private static func storedCopy(in defaults: UserDefaults) -> UUID {
        if let stored = defaults.string(forKey: defaultsKey), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        defaults.set(fresh.uuidString.lowercased(), forKey: defaultsKey)
        log.notice("Created install identity \(fresh.uuidString.lowercased(), privacy: .public) (not in the Keychain)")
        return fresh
    }
}
