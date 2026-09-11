import Foundation

/// Both iPhones browse and advertise at the same time, so without a rule each would invite the
/// other and MultipeerConnectivity would end up with two half-connected sessions.
/// The peer with the lexicographically smaller random token sends the invitation;
/// the other only accepts.
enum PeerElection {
    static func makeToken() -> String {
        UUID().uuidString.lowercased()
    }

    /// `true` when the local peer should send the invitation.
    /// A peer that did not publish a token (older build) is always invited.
    static func shouldInitiate(localToken: String, remoteToken: String?) -> Bool {
        guard let remoteToken, !remoteToken.isEmpty else { return true }
        return localToken < remoteToken
    }
}
