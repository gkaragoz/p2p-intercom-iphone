import Foundation

/// The intercom's overall state as the status card, the Live Activity and the notifications show it.
///
/// Per-peer `LinkState`s say what each link is doing; this answers the question the user has: can I
/// talk right now, and if not, is the app still trying?
enum SessionLinkStatus: Equatable, Sendable, CustomStringConvertible {
    /// The intercom is not running.
    case idle
    /// Running and looking for a peer: never linked in this run, the transport was restarted, or the
    /// last link ended over a pairing or version mismatch (the warning explains that one).
    case searching
    /// The last link was ended on purpose, here or (`byPeer`) on the other phone, and no other peer is
    /// waiting to be dialled. Nothing reconnects until someone taps Connect, so this must not look
    /// like searching.
    case disconnected(byPeer: Bool)
    /// A first connection attempt is under way. `attempt` counts from 1.
    case connecting(attempt: Int)
    /// At least one link is up. `since` is when it came up (wall clock, for `Text(timerInterval:)`).
    case connected(since: Date, path: LinkPath)
    /// The link was lost without anyone asking for it and the transport is redialling. `attempt` is
    /// 0 until the first redial is reported.
    case reconnecting(since: Date, attempt: Int)
    /// Audio I/O is down (phone call, Siri, another app). With `needsForeground` iOS refuses to
    /// restart it from the background; only opening the app brings it back.
    case audioInterrupted(needsForeground: Bool)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .searching: return "searching"
        case .disconnected(let byPeer): return "disconnected(byPeer \(byPeer))"
        case .connecting(let attempt): return "connecting(attempt \(attempt))"
        case .connected(_, let path): return "connected(\(path.rawValue))"
        case .reconnecting(_, let attempt): return "reconnecting(attempt \(attempt))"
        case .audioInterrupted(let needsForeground): return "audioInterrupted(needsForeground \(needsForeground))"
        }
    }
}

/// Something about the setup the user can fix, most important first.
enum SessionWarning: Equatable, Sendable {
    /// Local Network privacy permission is off; nothing can be discovered.
    case localNetworkDenied
    /// A peer uses a different pairing code.
    case pairingMismatch(PeerID)
    /// A peer runs an incompatible protocol version.
    case versionMismatch(PeerID)
    /// No Wi-Fi interface is available while no link is up. Also reported when Wi-Fi is on but not
    /// joined to a network (the path monitor cannot tell those apart), so the copy states the
    /// requirement ("Wi-Fi must be on, no network needed") instead of claiming Wi-Fi is off.
    case wifiOff
}

/// A local notification the controller shows while the app is not active.
enum SessionNotice: Equatable, Sendable {
    case connectionLost(peerName: String?)
    case reconnected(peerName: String?)
    case audioPaused

    /// Notices in the same slot share one notification identifier, so a newer one replaces the older.
    enum Slot: String, CaseIterable, Sendable {
        case link
        case audio
    }

    var slot: Slot {
        switch self {
        case .connectionLost, .reconnected: return .link
        case .audioPaused: return .audio
        }
    }
}

/// Derives `SessionLinkStatus`, the last peer name, the link path and the user-facing warning from
/// the transport's per-peer events and the audio state, and decides when to play a cue or show a
/// notification. A pure reducer like `LinkStateMachine`: the controller feeds inputs with an explicit
/// clock and performs the effects, so the policy is unit-tested without UIKit.
///
/// Policy:
/// * Cues: `connected` when the first link of an episode comes up, `lost` when the last link drops
///   unexpectedly (or the peer disconnected on purpose), `reconnected` when a link comes back after
///   an unexpected loss. A suspect link is still connected: no cue for a hiccup the link survives.
/// * Deliberate endings (local Disconnect, the peer's Disconnect, a restart of the local transport,
///   pairing or version mismatch) never start a "reconnecting" episode or a notification.
/// * Notifications, only while the app is not active: "connection lost" once the loss lasted
///   `lostNoticeGrace` (a quick reconnect shows nothing, and neither does a loss the user already
///   saw while the app was active), replaced by "reconnected" in the same slot
///   when the link comes back; "audio paused" at once for `needsForeground`, or after
///   `audioPausedNoticeGrace` of an interruption that has not recovered on its own. Becoming active
///   removes both: the user is looking at the app.
struct SessionStatusMachine {
    struct Configuration: Equatable, Sendable {
        var lostNoticeGrace: TimeInterval = 3
        var audioPausedNoticeGrace: TimeInterval = 5
        /// How long "no Wi-Fi and no link" must last before the hint shows (avoids a flash at start).
        var wifiHintDelay: TimeInterval = 5

        static let `default` = Configuration()
    }

    enum Input: Equatable, Sendable {
        /// The intercom started running (audio up, transport started).
        case started(appActive: Bool)
        case stopped
        /// The transport was replaced (engine, name or pairing code changed): every link ended on purpose.
        case transportRestarted
        case appActiveChanged(Bool)
        case linkStateChanged(PeerID, LinkState)
        /// Best known display name of a peer (discovery, HELLO or the hello control message).
        case peerNamed(PeerID, String)
        case audioStateChanged(AudioRecoveryMachine.State)
        case transportWarning(TransportWarning)
        /// The transport withdrew a warning it reported earlier.
        case transportWarningCleared(TransportWarning)
        case wifiAvailabilityChanged(Bool)
        /// Periodic; drives the grace periods. Once per second is enough.
        case tick
    }

    enum Effect: Equatable, Sendable {
        case playCue(CueTone)
        case postNotice(SessionNotice)
        case removeNotice(SessionNotice.Slot)
        case log(String)
    }

    let configuration: Configuration

    private(set) var status: SessionLinkStatus = .idle
    /// Name of the peer of the most recent link; kept after the link is lost (and across stops).
    private(set) var lastPeerName: String?
    /// Path of the current link, `nil` while no link is up.
    private(set) var linkPath: LinkPath?
    private(set) var warning: SessionWarning?
    private(set) var isRunning = false
    private(set) var isAppActive = true

    private struct Peer {
        var state: LinkState = .discovered
        var name: String?
        var path: LinkPath = .unknown
        /// Orders links by when they came up; the oldest one is the primary for path display.
        var linkOrder: UInt64 = 0
    }

    private struct LossEpisode {
        var peer: PeerID
        var since: Date
        var startedAt: MonotonicTime
        var attempt = 0
        var isNoticePosted = false
        /// The app was active during this loss: the user has seen it, so no notification repeats it.
        var isSeen = false
    }

    private var peers: [PeerID: Peer] = [:]
    private var lastPeerID: PeerID?
    private var linkCounter: UInt64 = 0
    private var connectedSince: Date?
    private var loss: LossEpisode?
    private var audioState: AudioRecoveryMachine.State = .stopped
    private var audioTroubleSince: MonotonicTime?
    private var isAudioNoticePosted = false
    private var transportWarning: SessionWarning?
    private var isWiFiAvailable = true
    private var wifiHintSince: MonotonicTime?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func handle(_ input: Input, now: MonotonicTime, date: Date) -> [Effect] {
        var effects: [Effect] = []
        switch input {
        case .started(let appActive):
            clearRun()
            isRunning = true
            isAppActive = appActive

        case .stopped:
            guard isRunning else { return [] }
            clearRun()
            isRunning = false
            audioState = .stopped
            audioTroubleSince = nil
            effects += [.removeNotice(.link), .removeNotice(.audio)]

        case .transportRestarted:
            guard isRunning else { return [] }
            if loss?.isNoticePosted == true {
                effects.append(.removeNotice(.link))
            }
            peers.removeAll()
            connectedSince = nil
            loss = nil
            transportWarning = nil

        case .appActiveChanged(let active):
            guard active != isAppActive else { return [] }
            isAppActive = active
            if active {
                loss?.isNoticePosted = false
                loss?.isSeen = true
                isAudioNoticePosted = false
                effects += [.removeNotice(.link), .removeNotice(.audio)]
            }

        case .linkStateChanged(let id, let state):
            guard isRunning else { return [] }
            effects += linkStateChanged(id, state, now: now, date: date)

        case .peerNamed(let id, let name):
            peers[id, default: Peer()].name = name
            if id == lastPeerID {
                lastPeerName = name
            }

        case .audioStateChanged(let state):
            audioState = state
            if isRunning, Self.isAudioTrouble(state) {
                if audioTroubleSince == nil {
                    audioTroubleSince = now
                }
            } else {
                audioTroubleSince = nil
                if isAudioNoticePosted {
                    isAudioNoticePosted = false
                    effects.append(.removeNotice(.audio))
                }
            }

        case .transportWarning(let transportWarning):
            guard isRunning else { return [] }
            if let warning = Self.sessionWarning(for: transportWarning) {
                self.transportWarning = warning
            }

        case .transportWarningCleared(let cleared):
            guard isRunning else { return [] }
            // Only withdraws that very warning; a different one reported meanwhile stays.
            if let warning = Self.sessionWarning(for: cleared), transportWarning == warning {
                transportWarning = nil
            }

        case .wifiAvailabilityChanged(let available):
            isWiFiAvailable = available

        case .tick:
            break
        }
        effects += dueNotices(now: now)
        recompute(now: now, date: date)
        return effects
    }

    // MARK: - Links

    private mutating func linkStateChanged(_ id: PeerID, _ state: LinkState, now: MonotonicTime, date: Date) -> [Effect] {
        var effects: [Effect] = []
        let wasLinked = hasLink
        var peer = peers[id] ?? Peer()
        let peerWasLinked = Self.isUp(peer.state)
        peer.state = state

        switch state {
        case .connected(let path, _):
            peer.path = path
            if !peerWasLinked {
                linkCounter += 1
                peer.linkOrder = linkCounter
            }
            peers[id] = peer
            guard !wasLinked else { break }
            connectedSince = date
            lastPeerID = id
            if let name = peer.name {
                lastPeerName = name
            }
            // Whatever blocked the connection before is evidently resolved.
            transportWarning = nil
            if let episode = loss {
                loss = nil
                effects += [.playCue(.reconnected),
                            .log(String(format: "link back after %.1f s", now - episode.startedAt))]
                if episode.isNoticePosted {
                    // Same slot: replaces the "connection lost" notification.
                    effects.append(.postNotice(.reconnected(peerName: lastPeerName)))
                }
            } else {
                effects.append(.playCue(.connected))
            }

        case .suspect, .discovered:
            peers[id] = peer

        case .connecting(let attempt):
            peers[id] = peer
            if loss?.peer == id {
                loss?.attempt = attempt
            }

        case .disconnected(let reason):
            peers[id] = peer
            switch reason {
            case .remoteBye(.authenticationFailed):
                transportWarning = .pairingMismatch(id)
            case .remoteBye(.incompatibleVersion):
                transportWarning = .versionMismatch(id)
            default:
                break
            }
            if !peerWasLinked, let episode = loss, episode.peer == id, Self.isDeliberateEnding(reason) {
                // The link was already down and being redialled when it turned out to be deliberate,
                // e.g. the peer's `bye(userDisconnect)` was lost and it said so later: nothing will
                // reconnect, so the "reconnecting" episode and its notification end here.
                loss = nil
                if episode.isNoticePosted {
                    effects.append(.removeNotice(.link))
                }
                effects.append(.log("link to \(id) ended on purpose (\(reason)) while reconnecting"))
            }
            guard peerWasLinked, !hasLink else { break }
            connectedSince = nil
            switch reason {
            case .userRequested, .stopped:
                effects.append(.log("link to \(id) ended on request"))
            case .remoteBye(.userDisconnect), .remoteBye(.authenticationFailed), .remoteBye(.incompatibleVersion):
                // The other side ended it and nothing reconnects automatically: say so, but there
                // is no "reconnecting" to announce.
                effects += [.playCue(.lost), .log("link to \(id) ended by the peer (\(reason))")]
            case .timeout, .transportError, .remoteBye:
                // A loss that starts while the app is active is on screen; going to the background
                // later must not announce it as news.
                loss = LossEpisode(peer: id, since: date, startedAt: now, isSeen: isAppActive)
                effects += [.playCue(.lost), .log("link to \(id) lost (\(reason)); reconnecting")]
            }
        }
        return effects
    }

    private var hasLink: Bool {
        peers.values.contains { Self.isUp($0.state) }
    }

    /// Endings after which the transport does not redial on its own.
    private static func isDeliberateEnding(_ reason: DisconnectReason) -> Bool {
        switch reason {
        case .userRequested, .stopped,
             .remoteBye(.userDisconnect), .remoteBye(.authenticationFailed), .remoteBye(.incompatibleVersion):
            return true
        case .timeout, .transportError, .remoteBye:
            return false
        }
    }

    private static func isUp(_ state: LinkState) -> Bool {
        switch state {
        case .connected, .suspect: return true
        case .discovered, .connecting, .disconnected: return false
        }
    }

    private static func sessionWarning(for warning: TransportWarning) -> SessionWarning? {
        switch warning {
        case .localNetworkDenied: return .localNetworkDenied
        case .pairingMismatch(let peer): return .pairingMismatch(peer)
        case .incompatibleVersion(let peer): return .versionMismatch(peer)
        // Transient: the transport rebuilds the object itself.
        case .listenerFailed, .browserFailed: return nil
        }
    }

    private static func isAudioTrouble(_ state: AudioRecoveryMachine.State) -> Bool {
        switch state {
        case .interrupted, .recovering, .needsForeground: return true
        case .running, .stopped: return false
        }
    }

    // MARK: - Notices and derived state

    private mutating func dueNotices(now: MonotonicTime) -> [Effect] {
        guard isRunning, !isAppActive else { return [] }
        var effects: [Effect] = []
        if var episode = loss, !episode.isNoticePosted, !episode.isSeen,
           now - episode.startedAt >= configuration.lostNoticeGrace {
            episode.isNoticePosted = true
            loss = episode
            effects.append(.postNotice(.connectionLost(peerName: lastPeerName)))
        }
        if !isAudioNoticePosted, let since = audioTroubleSince,
           audioState == .needsForeground || now - since >= configuration.audioPausedNoticeGrace {
            isAudioNoticePosted = true
            effects.append(.postNotice(.audioPaused))
        }
        return effects
    }

    private mutating func recompute(now: MonotonicTime, date: Date) {
        let primary = peers.values
            .filter { Self.isUp($0.state) }
            .min { $0.linkOrder < $1.linkOrder }
        linkPath = primary?.path
        if primary != nil, connectedSince == nil {
            connectedSince = date
        }

        let wifiHintCondition = isRunning && primary == nil && !isWiFiAvailable
        if !wifiHintCondition {
            wifiHintSince = nil
        } else if wifiHintSince == nil {
            wifiHintSince = now
        }
        if let transportWarning {
            warning = transportWarning
        } else if let since = wifiHintSince, now - since >= configuration.wifiHintDelay {
            warning = .wifiOff
        } else {
            warning = nil
        }

        guard isRunning else {
            status = .idle
            return
        }
        switch audioState {
        case .interrupted, .recovering:
            status = .audioInterrupted(needsForeground: false)
            return
        case .needsForeground:
            status = .audioInterrupted(needsForeground: true)
            return
        case .running, .stopped:
            break
        }
        if let primary {
            status = .connected(since: connectedSince ?? date, path: primary.path)
        } else if let loss {
            status = .reconnecting(since: loss.since, attempt: loss.attempt)
        } else if let attempt = peers.values.compactMap(Self.connectingAttempt).max() {
            status = .connecting(attempt: attempt)
        } else if let byPeer = deliberatelyDisconnectedByPeer() {
            status = .disconnected(byPeer: byPeer)
        } else {
            status = .searching
        }
    }

    private static func connectingAttempt(_ peer: Peer) -> Int? {
        if case .connecting(let attempt) = peer.state { return attempt }
        return nil
    }

    /// Whether a Disconnect ended the links, and on which side: `nil` unless some peer's last link was
    /// ended with Disconnect and no merely discovered peer could still be dialled automatically. The
    /// most recent peer decides the side; without it, the peer's side only if every such link was ended
    /// there. Pairing and version byes stay "searching": their warning already says what to do.
    private func deliberatelyDisconnectedByPeer() -> Bool? {
        var disconnectedByPeer: [PeerID: Bool] = [:]
        for (id, peer) in peers {
            switch peer.state {
            case .disconnected(.userRequested):
                disconnectedByPeer[id] = false
            case .disconnected(.remoteBye(.userDisconnect)):
                disconnectedByPeer[id] = true
            case .discovered:
                return nil
            case .connecting, .connected, .suspect, .disconnected:
                break
            }
        }
        guard !disconnectedByPeer.isEmpty else { return nil }
        if let lastPeerID, let byPeer = disconnectedByPeer[lastPeerID] {
            return byPeer
        }
        return disconnectedByPeer.values.allSatisfy { $0 }
    }

    private mutating func clearRun() {
        peers.removeAll()
        connectedSince = nil
        loss = nil
        isAudioNoticePosted = false
        transportWarning = nil
        wifiHintSince = nil
    }
}
