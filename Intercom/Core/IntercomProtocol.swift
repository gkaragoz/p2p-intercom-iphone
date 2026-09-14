import Foundation

/// Constants shared by both ends of an intercom link.
///
/// Everything that must be identical on the sending and receiving iPhone lives here so the
/// wire format cannot drift between the audio layer and the networking layer.
enum IntercomProtocol {
    /// Bumped whenever the Multipeer Connectivity wire format changes incompatibly.
    /// 2: link-management frames (`MultipeerFrame` ping/pong/status/bye) that the liveness check relies on.
    static let version: Int = 2

    /// Wire audio format: 16 kHz, mono, 16-bit signed little-endian PCM.
    /// 16 kHz matches the wideband HFP profile AirPods fall back to while their microphone is in use,
    /// so sending more than that would only waste bandwidth.
    static let sampleRate: Double = 16_000
    static let channelCount: Int = 1

    /// Every packet carries exactly one 20 ms frame.
    static let frameDuration: TimeInterval = 0.020
    static let frameSamples: Int = 320 // 16_000 * 0.020
    static let frameBytes: Int = frameSamples * MemoryLayout<Int16>.size

    /// MultipeerConnectivity service type. Must be 1–15 characters of lowercase ASCII letters,
    /// digits and hyphens, and must match the `NSBonjourServices` entries in Info.plist.
    static let serviceType = "p2p-intercom"

    /// Constants of the Network framework transport (one Bonjour UDP service, one UDP flow per peer).
    enum Network {
        /// Bonjour service type. Distinct from the Multipeer Connectivity types so the two engines
        /// never see each other's adverts; must be listed in `NSBonjourServices`.
        static let serviceType = "_intercom-nw._udp"
        /// Version byte in every `NetDatagram` header. Datagrams with another value are rejected.
        static let wireVersion: UInt8 = 2
        /// Session protocol version carried in HELLO and the TXT record; peers must match exactly.
        static let protocolVersion: UInt16 = 2
    }

    /// Keys used in the MultipeerConnectivity discovery info dictionary.
    enum DiscoveryKey {
        static let token = "token"
        static let name = "name"
        static let version = "v"
        /// Random per transport start (decimal `UInt32`): a changed value means the peer restarted.
        static let epoch = "epoch"
    }
}
