import Foundation
import MultipeerConnectivity

/// Creates a stable `MCPeerID` for the local device.
///
/// Apple recommends archiving the peer ID and reusing it: creating a fresh `MCPeerID` with the
/// same display name on every launch confuses peers that still remember the old one.
enum PeerIdentity {
    private static let defaultsKeyPrefix = "intercom.peerID."

    static func peerID(displayName: String, defaults: UserDefaults = .standard) -> MCPeerID {
        let name = DisplayName.sanitized(displayName)
        let key = defaultsKeyPrefix + name
        if let data = defaults.data(forKey: key),
           let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data),
           stored.displayName == name {
            return stored
        }
        let fresh = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: fresh, requiringSecureCoding: true) {
            defaults.set(data, forKey: key)
        }
        return fresh
    }
}
