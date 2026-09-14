import CryptoKit
import Foundation

/// Long-term key material both phones derive from the pairing code typed into Settings.
///
/// The code never leaves the phone. Everything on the wire is derived from it:
///
/// * `K = HKDF-SHA256(code, salt "p2p-intercom/nw/v2")`: the root key.
/// * `keyTag`: 8 hex digits of `HMAC(K, "key tag")`, advertised in the Bonjour TXT record so phones
///   with different codes see each other but never dial automatically.
/// * `helloAuthenticator`: HMAC over HELLO / HELLO_ACK, so a wrong code is an explicit
///   `bye(authenticationFailed)` ("pairing code differs") instead of a silent handshake timeout.
/// * `sessionKeys(for:)`: one ChaChaPoly key per direction per link, bound to both install IDs, both
///   nonces, both epochs and the link ID, so no key (and no nonce) is ever reused across links or restarts.
///
/// An empty code falls back to an app-wide constant so two phones work out of the box; that gives
/// integrity against accidents but no secrecy against someone running the same app. HKDF is not a
/// slow password hash, so a short code can be brute-forced offline from captured packets — the
/// Settings text recommends a long random code for real privacy.
struct PairingKey {
    static let salt = Data("p2p-intercom/nw/v2".utf8)
    static let linkSalt = Data("p2p-intercom/nw/v2/link".utf8)
    /// Key material used when no pairing code is set.
    static let defaultCodeMaterial = "p2p-intercom/default-pairing-code"

    /// `true` when no pairing code is set and the app-wide default key is in use.
    let isDefault: Bool
    /// 8 lowercase hex digits; see `DiscoveryRecord.normalizedKeyTag`.
    let keyTag: String
    private let rootKey: SymmetricKey
    private let helloKey: SymmetricKey

    init(code: String) {
        let normalized = Self.normalized(code)
        isDefault = normalized.isEmpty
        let material = SymmetricKey(data: Data((normalized.isEmpty ? Self.defaultCodeMaterial : normalized).utf8))
        rootKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: Self.salt,
                                         info: Data("pairing key".utf8), outputByteCount: 32)
        helloKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: rootKey, info: Data("hello authentication".utf8),
                                          outputByteCount: 32)
        let tag = HMAC<SHA256>.authenticationCode(for: Data("key tag".utf8), using: rootKey)
        keyTag = tag.prefix(4).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }

    /// Surrounding whitespace is ignored and Unicode is normalised (a precomposed "ö" typed on one
    /// phone must match a decomposed one); case is significant.
    static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    var helloAuthenticator: HelloAuthenticator {
        HMACHelloAuthenticator(key: helloKey)
    }

    /// The two ChaChaPoly keys of one link: dialer → listener and listener → dialer.
    func sessionKeys(for context: LinkKeyContext) -> (dialerToListener: SymmetricKey, listenerToDialer: SymmetricKey) {
        var info = [UInt8]("link keys".utf8)
        Self.appendIdentity(context.dialerID, to: &info)
        Self.appendIdentity(context.listenerID, to: &info)
        info.appendLittleEndian(context.dialerNonce)
        info.appendLittleEndian(context.listenerNonce)
        info.appendLittleEndian(context.dialerEpoch)
        info.appendLittleEndian(context.listenerEpoch)
        info.appendLittleEndian(context.linkID)
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: rootKey, salt: Self.linkSalt, info: info, outputByteCount: 64)
        return material.withUnsafeBytes { raw in
            (SymmetricKey(data: Data(raw[0..<32])), SymmetricKey(data: Data(raw[32..<64])))
        }
    }

    private static func appendIdentity(_ id: PeerID, to bytes: inout [UInt8]) {
        if let uuid = id.installID?.uuid {
            withUnsafeBytes(of: uuid) { bytes.append(contentsOf: $0) }
        } else {
            let utf8 = Array(id.rawValue.utf8.prefix(255))
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
    }
}

/// HELLO key confirmation: a truncated HMAC-SHA256 under a key derived from the pairing code.
struct HMACHelloAuthenticator: HelloAuthenticator {
    static let tagLength = 16

    let key: SymmetricKey

    func authenticationTag(for message: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: message, using: key).prefix(Self.tagLength))
    }

    func isValidAuthenticationTag(_ tag: [UInt8], for message: [UInt8]) -> Bool {
        guard tag.count == Self.tagLength else { return false }
        let expected = authenticationTag(for: message)
        // Constant time: the comparison must not reveal how many leading bytes matched.
        var difference: UInt8 = 0
        for index in 0..<Self.tagLength {
            difference |= expected[index] ^ tag[index]
        }
        return difference == 0
    }
}
