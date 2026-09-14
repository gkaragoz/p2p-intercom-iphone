import Foundation

/// Authenticated encryption of one link's datagram payloads.
///
/// The 14-byte `NetDatagram` header travels in the clear but is passed as additional
/// authenticated data, so flipping a flag or a link ID is detected. The implementation used on the
/// phones (ChaChaPoly from CryptoKit, keyed per link from the pairing code) lives in the app target
/// because CryptoKit does not exist on Linux, where Core is unit-tested.
///
/// Thread safety: `seal` is called concurrently from the audio capture thread and the transport
/// queue, `open` from network receive contexts. Implementations must be safe for that (for example
/// an atomic nonce counter and a locked replay window).
protocol PacketSealer: AnyObject {
    /// Returns the sealed form of `payload`, or `nil` if it cannot be sealed (no key yet).
    func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8]?
    /// Returns the plaintext, or `nil` if authentication fails or the datagram is a replay.
    func open(_ sealed: [UInt8], header: [UInt8]) -> [UInt8]?
}

/// Pass-through sealer for unit tests and plain-UDP bring-up. Provides no confidentiality or
/// integrity whatsoever; never ship it as the default.
final class PlaintextSealer: PacketSealer {
    init() {}

    func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8]? {
        payload
    }

    func open(_ sealed: [UInt8], header: [UInt8]) -> [UInt8]? {
        sealed
    }
}

/// Proves knowledge of the pairing key inside HELLO / HELLO_ACK, so a wrong pairing code produces
/// an explicit `bye(authenticationFailed)` instead of a handshake that silently never completes.
///
/// The app implements it with HMAC-SHA256 over the bytes produced by `NetHello.authenticatedBytes`.
protocol HelloAuthenticator {
    func authenticationTag(for message: [UInt8]) -> [UInt8]
    func isValidAuthenticationTag(_ tag: [UInt8], for message: [UInt8]) -> Bool
}

/// No key: tags are empty and only empty tags are accepted, so an unauthenticated build still
/// rejects a peer that does authenticate (and vice versa) with a clear reason.
struct UnauthenticatedHello: HelloAuthenticator {
    init() {}

    func authenticationTag(for message: [UInt8]) -> [UInt8] {
        []
    }

    func isValidAuthenticationTag(_ tag: [UInt8], for message: [UInt8]) -> Bool {
        tag.isEmpty
    }
}

/// Everything both ends know once a handshake completes; the app derives the per-direction session
/// keys for `PacketSealer` from it (together with the long-term pairing key).
struct LinkKeyContext: Equatable, Sendable {
    var localID: PeerID
    var remoteID: PeerID
    var isLocalDialer: Bool
    var dialerNonce: UInt32
    var listenerNonce: UInt32
    var dialerEpoch: UInt32
    var listenerEpoch: UInt32
    var linkID: UInt32

    var localEpoch: UInt32 { isLocalDialer ? dialerEpoch : listenerEpoch }
    var remoteEpoch: UInt32 { isLocalDialer ? listenerEpoch : dialerEpoch }
    var dialerID: PeerID { isLocalDialer ? localID : remoteID }
    var listenerID: PeerID { isLocalDialer ? remoteID : localID }
}
