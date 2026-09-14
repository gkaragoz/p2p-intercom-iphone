import Foundation

/// Transport-neutral identity of a remote intercom.
///
/// For the Network framework transport this is the peer's install UUID (lowercased), which never
/// changes across launches or display-name edits. Multipeer Connectivity maps its `MCPeerID`s to
/// the same type so the controller, audio pipeline and UI never see framework types.
struct PeerID: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(installID: UUID) {
        rawValue = installID.uuidString.lowercased()
    }

    /// The install UUID behind this ID, if it is one.
    var installID: UUID? { UUID(uuidString: rawValue) }

    /// Lowercased UUID strings compare in the same order as their raw bytes, which is what
    /// `LinkArbiter` relies on for a deterministic tie-break both phones agree on.
    static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { rawValue }
}

/// Identifies one UDP flow (one `NWConnection`) inside a transport. Never sent over the wire.
struct FlowID: Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: UInt64

    static func < (lhs: FlowID, rhs: FlowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { "flow#\(rawValue)" }
}

/// Which engine carries the link. Both phones must use the same one.
enum TransportKind: String, CaseIterable, Codable, Sendable {
    case network
    case multipeer
}

/// The kind of network path a link currently uses. Shown in the UI and logs only.
enum LinkPath: String, CaseIterable, Codable, Sendable {
    /// Apple peer-to-peer Wi-Fi (AWDL); works with no router at all.
    case peerToPeerWiFi
    /// Both phones on the same infrastructure Wi-Fi network.
    case wifiNetwork
    case wired
    case other
    case unknown
}

/// Maps what Network framework reports about a path's interface to a `LinkPath`.
///
/// Interface names are not API (they are only used to recognise peer-to-peer Wi-Fi for display),
/// so the classifier takes plain values and never drives connection logic by itself.
enum LinkPathClassifier {
    /// Name prefixes of Apple's peer-to-peer Wi-Fi interfaces (`awdl0`, `llw0`).
    static let peerToPeerPrefixes = ["awdl", "llw"]

    static func classify(interfaceName: String?, isWiFi: Bool, isWired: Bool) -> LinkPath {
        if let name = interfaceName?.lowercased(),
           peerToPeerPrefixes.contains(where: { name.hasPrefix($0) }) {
            return .peerToPeerWiFi
        }
        if isWiFi { return .wifiNetwork }
        if isWired { return .wired }
        if let interfaceName, !interfaceName.isEmpty { return .other }
        return .unknown
    }
}

/// What the other phone is doing right now. Carried as flag bits in every datagram header, so it
/// needs no reliable delivery: the next heartbeat always carries the latest value.
struct RemoteStatus: Equatable, Sendable {
    var isTalking: Bool
    var isMuted: Bool
    /// `nil` when the peer did not say (e.g. a legacy peer).
    var mode: TransmitMode?
    /// The peer's audio session is interrupted (phone call, Siri, …); it cannot hear or speak.
    var isAudioPaused: Bool

    init(isTalking: Bool = false, isMuted: Bool = false, mode: TransmitMode? = nil, isAudioPaused: Bool = false) {
        self.isTalking = isTalking
        self.isMuted = isMuted
        self.mode = mode
        self.isAudioPaused = isAudioPaused
    }
}

/// Why a peer sent `bye`. Unknown values from newer builds decode as `.other`.
enum ByeReason: UInt8, Sendable {
    /// The intercom was stopped on the other phone.
    case stopped = 0
    /// The user pressed Disconnect; do not reconnect automatically.
    case userDisconnect = 1
    /// Both phones dialled; this flow lost the tie-break.
    case duplicate = 2
    /// HELLO authentication failed: the pairing codes differ.
    case authenticationFailed = 3
    case incompatibleVersion = 4
    /// A newer flow to the same peer took over (restart, migration, stale link).
    case replaced = 5
    case other = 255

    init(wireValue: UInt8) {
        self = ByeReason(rawValue: wireValue) ?? .other
    }
}

/// Why a link went down.
enum DisconnectReason: Equatable, Sendable {
    /// No datagram arrived for the liveness deadline, or sends kept failing.
    case timeout
    case remoteBye(ByeReason)
    case userRequested
    case stopped
    case transportError(String)
}

/// How a discovered peer relates to the local configuration.
enum PeerCompatibility: Equatable, Sendable {
    case compatible
    /// Different network protocol version: one phone needs an update.
    case incompatibleVersion
    /// The advertised key tag differs: the pairing codes are not the same.
    case pairingMismatch
}

/// A peer as seen through discovery (or a HELLO from a peer discovery never reported).
struct PeerAdvert: Equatable, Sendable {
    var id: PeerID
    var displayName: String
    var protocolVersion: Int?
    var compatibility: PeerCompatibility
}

/// Per-peer link state reported to the controller.
enum LinkState: Equatable, Sendable {
    case discovered
    /// Dialling (or waiting for the other side's dial). `attempt` counts from 1 since the last up link.
    case connecting(attempt: Int)
    /// `isResumption` is true when the peer is the same app instance as on the previous link
    /// (same epoch), so jitter-buffer and round-trip state should be kept and no "connected" cue played.
    case connected(path: LinkPath, isResumption: Bool)
    /// Nothing received for a while; audio may be interrupted but the link is not given up yet.
    case suspect
    case disconnected(DisconnectReason)
}

enum TransportWarning: Equatable, Sendable {
    /// Local Network privacy permission is denied (Settings › Privacy › Local Network).
    case localNetworkDenied
    case pairingMismatch(PeerID)
    case incompatibleVersion(PeerID)
    case listenerFailed(String)
    case browserFailed(String)
}

/// Everything a transport reports to the controller.
enum TransportEvent: Equatable, Sendable {
    /// A peer appeared, or its advertised details (name, compatibility) changed.
    case peerDiscovered(PeerAdvert)
    /// Discovery no longer lists the peer. A peer that was linked before is still redialled.
    case peerLost(PeerID)
    case linkStateChanged(PeerID, LinkState)
    case control(ControlMessage, from: PeerID)
    case remoteStatus(RemoteStatus, from: PeerID)
    case roundTrip(PeerID, ms: Double)
    case warning(TransportWarning)
    /// A warning reported earlier no longer applies (e.g. Local Network access was granted after all).
    case warningCleared(TransportWarning)
}
