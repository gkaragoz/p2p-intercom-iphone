import Foundation

/// Decides who dials and which flow survives when both phones end up with more than one flow.
///
/// Generalises `PeerElection` for the Network framework transport (TN3213 "if local > remote drop
/// outgoing else drop incoming"). Every rule uses only facts both phones share — install IDs,
/// epochs and the dialer's flow sequence — so both sides reach the same verdict without talking:
///
/// * The lower install ID is the preferred dialer and dials as soon as it discovers the peer. The
///   higher one waits `dialHoldoff` and dials only if no HELLO arrived meanwhile, which also covers
///   one-sided Bonjour discovery.
/// * Between two established flows, the one dialled by the lower ID wins; between two flows from the
///   same dialer the newer one (higher dial sequence) wins, which is what a path migration looks like.
/// * An inbound HELLO with a different epoch means the peer restarted: once its flow carries a sealed
///   datagram (a replayed HELLO never does), it replaces everything.
/// * An inbound HELLO while our own flow to that peer is suspect or dead replaces it even if ours
///   would win the tie-break: the peer only redials when it has given up on that flow.
enum LinkArbiter {
    /// How long the higher ID waits for the preferred dialer's HELLO before dialling itself.
    static let dialHoldoff: TimeInterval = 0.75

    static func isPreferredDialer(local: PeerID, remote: PeerID) -> Bool {
        local < remote
    }

    /// Extra delay before the local side dials `remote` (on top of any backoff).
    static func dialDelay(local: PeerID, remote: PeerID, holdoff: TimeInterval = dialHoldoff) -> TimeInterval {
        isPreferredDialer(local: local, remote: remote) ? 0 : holdoff
    }

    /// The facts about a flow that its ranking depends on.
    struct Candidate: Equatable, Sendable {
        var dialer: PeerID
        var dialSequence: UInt32
    }

    /// `true` if flow `a` should be kept over flow `b` for the pair (`local`, `remote`).
    static func isPreferred(_ a: Candidate, over b: Candidate, local: PeerID, remote: PeerID) -> Bool {
        let lower = min(local, remote)
        let aByLower = a.dialer == lower
        let bByLower = b.dialer == lower
        if aByLower != bByLower { return aByLower }
        return a.dialSequence > b.dialSequence
    }

    /// The current primary flow to a peer, as far as an inbound HELLO decision needs to know.
    struct ExistingLink: Equatable, Sendable {
        var dialer: PeerID
        var remoteEpoch: UInt32
        var health: LivenessMonitor.Health
    }

    enum InboundHelloDecision: Equatable, Sendable {
        /// Handshake the new flow. When `supersedesPrimary` is set, the current primary is closed as
        /// soon as the new flow is established even though it would win the tie-break.
        case accept(supersedesPrimary: Bool)
        /// The peer restarted (new epoch): every flow of the old instance is stale once the new flow is
        /// confirmed by a sealed datagram.
        case acceptReplacingRestartedPeer
        /// Our healthy flow wins the tie-break; answer `bye(duplicate)`.
        case rejectDuplicate
    }

    static func decideInboundHello(local: PeerID, remote: PeerID, helloEpoch: UInt32,
                                   primary: ExistingLink?) -> InboundHelloDecision {
        guard let primary else { return .accept(supersedesPrimary: false) }
        if helloEpoch != primary.remoteEpoch {
            return .acceptReplacingRestartedPeer
        }
        if primary.dialer == remote {
            // Same dialer opened another flow: a migration or a redial. Newest wins by dial sequence.
            return .accept(supersedesPrimary: false)
        }
        if primary.health != .alive {
            return .accept(supersedesPrimary: true)
        }
        // Both sides dialled and ours is healthy: keep whichever the lower ID dialled.
        return remote < local ? .accept(supersedesPrimary: false) : .rejectDuplicate
    }

    /// When an inbound HELLO arrives while our own dial to that peer is still handshaking, our dial is
    /// pointless if the peer's flow would win the tie-break anyway.
    static func shouldAbandonOwnDialOnInboundHello(local: PeerID, remote: PeerID) -> Bool {
        remote < local
    }
}
