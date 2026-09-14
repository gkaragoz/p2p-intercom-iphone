import Foundation

/// Both iPhones browse and advertise at the same time, so without a rule each would invite the
/// other and MultipeerConnectivity would end up with two half-connected sessions.
/// Exactly one side — decided the same way on both phones — sends the invitation; the other only accepts.
///
/// The Network framework transport uses `LinkArbiter` instead.
enum PeerElection {
    static func makeToken() -> String {
        UUID().uuidString.lowercased()
    }

    /// `true` when the local peer should send the invitation.
    ///
    /// The decision must not depend on information only one side has. Discovery info (and with it
    /// the remote token) can be stale or missing on one phone while the other has it, so the primary
    /// tie-break is a value both sides always know about each other — the Multipeer display names.
    /// Tokens (which the app must persist, not regenerate per launch) only break ties between equal
    /// names. Only when even that is impossible does the local side invite, because an invitation
    /// collision is recoverable while two phones that both wait never connect.
    static func shouldInitiate(localToken: String, remoteToken: String?,
                               localTieBreaker: String, remoteTieBreaker: String) -> Bool {
        if !localTieBreaker.isEmpty, !remoteTieBreaker.isEmpty, localTieBreaker != remoteTieBreaker {
            return localTieBreaker < remoteTieBreaker
        }
        guard let remoteToken, !remoteToken.isEmpty, !localToken.isEmpty else { return true }
        return localToken < remoteToken
    }
}
