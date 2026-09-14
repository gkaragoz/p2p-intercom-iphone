import Foundation

/// The Bonjour TXT record the Network framework transport advertises, as a plain model.
///
/// Kept static for the whole session (no live TXT updates needed): the real display name and app
/// version travel in HELLO, so the `n` entry is informational only. The `NWTXTRecord` conversion
/// itself stays in the app target.
///
/// | key | value |
/// |-----|-------|
/// | `v` | session protocol version (decimal) |
/// | `id`| install UUID; also the service instance name |
/// | `n` | display name, ≤ 63 UTF-8 bytes |
/// | `k` | 8 lowercase hex digits derived from the pairing key, so phones with different codes don't auto-dial |
/// | `c` | capability bits (hex) |
struct DiscoveryRecord: Equatable, Sendable {
    enum Key {
        static let version = "v"
        static let id = "id"
        static let name = "n"
        static let keyTag = "k"
        static let capabilities = "c"
    }

    static let keyTagLength = 8

    var protocolVersion: Int
    var peerID: PeerID
    var displayName: String
    /// Empty when the advertiser has no key tag.
    var keyTag: String
    var capabilities: UInt32

    init(peerID: PeerID, displayName: String, keyTag: String,
         protocolVersion: Int = Int(IntercomProtocol.Network.protocolVersion), capabilities: UInt32 = 0) {
        self.peerID = peerID
        self.displayName = DisplayName.sanitized(displayName)
        self.keyTag = Self.normalizedKeyTag(keyTag) ?? ""
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

    /// Parses a TXT dictionary. Returns `nil` without a usable version or install ID; every other
    /// entry is optional so a slightly different build still shows up (as incompatible if need be).
    init?(txtRecord: [String: String]) {
        guard let versionText = txtRecord[Key.version],
              let version = Int(versionText.trimmingCharacters(in: .whitespaces)),
              let idText = txtRecord[Key.id],
              let uuid = UUID(uuidString: idText) else { return nil }
        protocolVersion = version
        peerID = PeerID(installID: uuid)
        displayName = DisplayName.sanitized(txtRecord[Key.name] ?? "")
        keyTag = txtRecord[Key.keyTag].flatMap(Self.normalizedKeyTag) ?? ""
        capabilities = txtRecord[Key.capabilities].flatMap { UInt32($0, radix: 16) } ?? 0
    }

    var txtRecord: [String: String] {
        var record = [
            Key.version: String(protocolVersion),
            Key.id: peerID.rawValue,
            Key.name: displayName,
            Key.capabilities: String(capabilities, radix: 16),
        ]
        if !keyTag.isEmpty {
            record[Key.keyTag] = keyTag
        }
        return record
    }

    func compatibility(localProtocolVersion: Int = Int(IntercomProtocol.Network.protocolVersion),
                       localKeyTag: String) -> PeerCompatibility {
        guard protocolVersion == localProtocolVersion else { return .incompatibleVersion }
        guard keyTag == (Self.normalizedKeyTag(localKeyTag) ?? "") else { return .pairingMismatch }
        return .compatible
    }

    func advert(localKeyTag: String) -> PeerAdvert {
        PeerAdvert(
            id: peerID,
            displayName: displayName,
            protocolVersion: protocolVersion,
            compatibility: compatibility(localKeyTag: localKeyTag)
        )
    }

    /// Lowercased tag if it is exactly `keyTagLength` hex digits, otherwise `nil`.
    static func normalizedKeyTag(_ raw: String) -> String? {
        let tag = raw.lowercased()
        guard tag.count == keyTagLength, tag.allSatisfy({ $0.isHexDigit }) else { return nil }
        return tag
    }
}

/// RFC 6335 rules for DNS-SD service types such as `_intercom-nw._udp`.
///
/// A wrong type fails only at runtime with an unhelpful DNS error (and must also match
/// `NSBonjourServices`), so it is checked in tests instead.
enum ServiceTypeValidator {
    static func isValid(_ serviceType: String) -> Bool {
        let parts = serviceType.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[1] == "_udp" || parts[1] == "_tcp",
              parts[0].hasPrefix("_") else { return false }
        return isValidServiceName(String(parts[0].dropFirst()))
    }

    /// 1–15 ASCII letters, digits and hyphens; at least one letter; no leading, trailing or double hyphen.
    static func isValidServiceName(_ name: String) -> Bool {
        guard (1...15).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              name.contains(where: { $0.isLetter }),
              !name.hasPrefix("-"), !name.hasSuffix("-"),
              !name.contains("--") else { return false }
        return true
    }
}
