import Foundation

/// The whole session logic of the Network framework transport as a pure reducer:
/// `handle(input, now) -> [Effect]`.
///
/// `NetworkTransport` (app target) owns the `NWListener`, `NWBrowser` and one `NWConnection` per
/// flow and is reduced to glue: it turns framework callbacks into `Input`s, performs the returned
/// `Effect`s in order, and calls `.tick` every `recommendedTickInterval`. Everything that decides
/// *what* to do — who dials, handshakes, duplicate flows, liveness, reconnect backoff, browser
/// policy, reliable control — lives here, is deterministic for a given clock and seed, and is
/// unit-tested with two machines talking over a simulated network.
///
/// Glue contract:
/// * All calls happen on one serial queue.
/// * `.openFlow(id, to:, prohibitedInterfaceName:)`: create an `NWConnection` to the peer's last
///   known Bonjour endpoint and start it; report `.flowReady` / `.flowWaiting` / `.flowFailed`,
///   `.flowPathChanged`, `.flowViabilityChanged` and `.flowBetterPathAvailable` for it. If no
///   endpoint is known, report `.flowFailed` right away.
/// * A new inbound connection from the listener: `let id = machine.makeFlowID()`, start it, then
///   `.inboundFlow(id)`.
/// * `.send(datagram, on:)`: encode with the flow's sealer if the flow is bound (handshake payloads
///   are always plaintext — `NetDatagram.encoded` handles that), send with `.contentProcessed` and
///   report `.sendCompleted`.
/// * `.bindFlow(id, context)`: create the flow's `PacketSealer` from the context.
/// * Received datagrams: decode with the flow's sealer (or none). Audio on a bound flow goes straight
///   to the audio callback and never through the machine; everything else is `.datagram`, and decode
///   failures are `.undecodableDatagram`.
/// * `.setAudioRoute(peer, route)`: the flow `sendAudio` uses from the capture thread (lock- or
///   atomic-protected), with the link ID for the header; `nil` drops audio.
/// * `.cancelFlow`: cancel the connection once any `.send` emitted before it has been handed to it.
struct LinkStateMachine {
    static let recommendedTickInterval: TimeInterval = 0.05

    struct Configuration {
        var localID: PeerID
        /// Random per transport start; lets the peer tell a restart from a flapping link. Create a new
        /// machine with a fresh epoch for every start, otherwise the peer treats the restart as a resumption.
        var localEpoch: UInt32
        var displayName: String
        var appVersion: String
        /// The advertised `k` TXT value; peers with a different tag are not dialled automatically.
        var keyTag: String = ""
        var protocolVersion: UInt16 = IntercomProtocol.Network.protocolVersion
        var capabilities: UInt32 = 0
        /// When `false`, discovered peers are only reported and `.connect` must be used.
        var autoConnect = true
        var dialHoldoff: TimeInterval = LinkArbiter.dialHoldoff
        var helloRetryInterval: TimeInterval = 0.25
        /// A dialled flow that is not `.ready` within this time counts as a failed attempt.
        var flowReadyTimeout: TimeInterval = 3
        /// HELLO_ACK deadline after the flow became ready: first attempt, then later attempts.
        var handshakeTimeouts: [TimeInterval] = [1, 2]
        /// Listener side: time from HELLO_ACK to the dialer's first sealed datagram.
        var listenerHandshakeTimeout: TimeInterval = 2
        var unboundFlowTimeout: TimeInterval = 2
        var maxUnboundFlows = 8
        /// Losing duplicates are kept this long after `bye` so in-flight datagrams are not refused.
        var closingLinger: TimeInterval = 0.5
        /// The browser is stopped after every wanted peer has had a healthy link this long.
        var browserIdleAfterHealthy: TimeInterval = 3
        /// Browser and listener rebuilds recover discovery while no link is healthy; they are skipped
        /// while another peer's link is, because that link depends on both.
        var failedDialsPerBrowserRebuild = 3
        var failedDialsPerListenerRebuild = 6
        /// A peer the browser no longer lists is parked after this many failed dials while another
        /// peer's link is healthy: dialled only every `parkedRedialInterval` and not browsed for.
        var failedDialsBeforeParking = 3
        var parkedRedialInterval: TimeInterval = 30
        /// Handshake timeouts on one infrastructure interface before dialling around it.
        var handshakeTimeoutsBeforeProhibitingInterface = 2
        /// Minimum spacing of make-before-break migrations to a better path.
        var migrationInterval: TimeInterval = 5
        var roundTripReportInterval: TimeInterval = 1
        var controlRetryInterval: TimeInterval = 0.25
        var liveness: LivenessMonitor.Configuration = .default
        var backoff: ReconnectBackoff.Schedule = .network

        init(localID: PeerID, localEpoch: UInt32, displayName: String, appVersion: String) {
            self.localID = localID
            self.localEpoch = localEpoch
            self.displayName = displayName
            self.appVersion = appVersion
        }
    }

    enum Input {
        case start
        case stop
        case setAppActive(Bool)
        /// NWPathMonitor reported a change: reset backoff and try again right away.
        case pathChanged
        /// A browser result (already parsed). Results for the local install ID are ignored.
        case peerDiscovered(DiscoveryRecord)
        case peerLost(PeerID)
        /// User asked to connect: clears suppression and backoff, dials now.
        case connect(PeerID)
        /// User pressed Disconnect: `bye` to everyone, no automatic reconnect until `.connect`.
        case disconnectAll
        case inboundFlow(FlowID)
        case flowReady(FlowID)
        case flowWaiting(FlowID, localNetworkDenied: Bool)
        case flowFailed(FlowID, reason: String)
        case flowPathChanged(FlowID, LinkPath, interfaceName: String?)
        case flowViabilityChanged(FlowID, isViable: Bool)
        case flowBetterPathAvailable(FlowID)
        case datagram(NetDatagram, on: FlowID)
        case undecodableDatagram(FlowID, NetDatagramError)
        case sendCompleted(FlowID, success: Bool)
        case sendControl(ControlMessage)
        case updateLocalStatus(RemoteStatus)
        case tick
    }

    struct AudioRoute: Equatable, Sendable {
        var flow: FlowID
        var linkID: UInt32
    }

    enum Effect: Equatable {
        case startListener
        case stopListener
        case rebuildListener
        case startBrowser
        case stopBrowser
        /// Tear the browser down and create a new one (flushes stale Bonjour results).
        case rebuildBrowser
        case openFlow(FlowID, to: PeerID, prohibitedInterfaceName: String?)
        case bindFlow(FlowID, LinkKeyContext)
        case send(NetDatagram, on: FlowID)
        case cancelFlow(FlowID)
        case setAudioRoute(PeerID, AudioRoute?)
        case event(TransportEvent)
        /// Human-readable lifecycle line for the transport log.
        case log(String)
    }

    // MARK: - State

    let configuration: Configuration
    var authenticator: HelloAuthenticator
    var rng: SplitMix64

    private(set) var isRunning = false
    private(set) var isAppActive = true
    var isBrowserRunning = false
    var localStatus = RemoteStatus()

    var peers: [PeerID: PeerRecord] = [:]
    var flows: [FlowID: FlowRecord] = [:]
    var links: [FlowID: LinkRecord] = [:]
    /// Inbound flows that have not presented a valid HELLO yet, oldest first.
    var unboundFlows: [FlowID] = []
    var browserHealthySince: MonotonicTime?
    var nextFlowID: UInt64 = 1
    var dialSequence: UInt32 = 0
    var hasReportedLocalNetworkDenied = false
    var pendingEffects: [Effect] = []

    init(configuration: Configuration,
         authenticator: HelloAuthenticator = UnauthenticatedHello(),
         rng: SplitMix64 = SplitMix64()) {
        var config = configuration
        config.displayName = DisplayName.sanitized(config.displayName)
        if config.handshakeTimeouts.isEmpty { config.handshakeTimeouts = [1] }
        config.maxUnboundFlows = max(1, config.maxUnboundFlows)
        config.failedDialsPerBrowserRebuild = max(1, config.failedDialsPerBrowserRebuild)
        config.failedDialsPerListenerRebuild = max(1, config.failedDialsPerListenerRebuild)
        config.failedDialsBeforeParking = max(1, config.failedDialsBeforeParking)
        self.configuration = config
        self.authenticator = authenticator
        self.rng = rng
    }

    /// Allocates an ID for an inbound flow before reporting it with `.inboundFlow`.
    mutating func makeFlowID() -> FlowID {
        let id = FlowID(rawValue: nextFlowID)
        nextFlowID += 1
        return id
    }

    // MARK: - Queries

    func linkState(of peer: PeerID) -> LinkState? {
        peers[peer]?.reportedState
    }

    func audioRoute(for peer: PeerID) -> AudioRoute? {
        guard let flow = peers[peer]?.primary, let link = links[flow] else { return nil }
        return AudioRoute(flow: flow, linkID: link.linkID)
    }

    var knownPeers: [PeerID] {
        peers.keys.sorted()
    }

    // MARK: - Reducer

    mutating func handle(_ input: Input, now: MonotonicTime) -> [Effect] {
        pendingEffects = []
        switch input {
        case .start:
            start(now: now)
        case .stop:
            stop(now: now)
        default:
            guard isRunning else { return [] }
            dispatch(input, now: now)
            serviceDials(now: now)
            updateBrowser(now: now)
        }
        let effects = pendingEffects
        pendingEffects = []
        return effects
    }

    private mutating func dispatch(_ input: Input, now: MonotonicTime) {
        switch input {
        case .start, .stop:
            break
        case .setAppActive(let active):
            setAppActive(active, now: now)
        case .pathChanged:
            pathChanged(now: now)
        case .peerDiscovered(let record):
            peerDiscovered(record, now: now)
        case .peerLost(let id):
            peerLost(id, now: now)
        case .connect(let id):
            connect(id, now: now)
        case .disconnectAll:
            disconnectAll(now: now)
        case .inboundFlow(let id):
            inboundFlow(id, now: now)
        case .flowReady(let id):
            flowReady(id, now: now)
        case .flowWaiting(let id, let denied):
            flowWaiting(id, localNetworkDenied: denied, now: now)
        case .flowFailed(let id, let reason):
            flowFailed(id, reason: reason, now: now)
        case .flowPathChanged(let id, let path, let name):
            flowPathChanged(id, path: path, interfaceName: name, now: now)
        case .flowViabilityChanged(let id, let viable):
            if links[id] != nil {
                links[id]?.isViable = viable
                log("\(id) viability \(viable ? "restored" : "lost")")
                if let peer = links[id]?.peer { updateReportedState(peer, now: now) }
            }
        case .flowBetterPathAvailable(let id):
            betterPathAvailable(id, now: now)
        case .datagram(let datagram, let id):
            received(datagram, on: id, now: now)
        case .undecodableDatagram(let id, let error):
            undecodable(error, on: id, now: now)
        case .sendCompleted(let id, let success):
            sendCompleted(on: id, success: success, now: now)
        case .sendControl(let message):
            sendControl(message, now: now)
        case .updateLocalStatus(let status):
            updateLocalStatus(status, now: now)
        case .tick:
            tick(now: now)
        }
    }

    // MARK: - Effects helpers

    mutating func emit(_ effect: Effect) {
        pendingEffects.append(effect)
    }

    mutating func emitEvent(_ event: TransportEvent) {
        pendingEffects.append(.event(event))
    }

    mutating func log(_ message: String) {
        pendingEffects.append(.log(message))
    }

    mutating func randomNonZeroUInt32() -> UInt32 {
        var value: UInt32 = 0
        while value == 0 {
            value = UInt32(truncatingIfNeeded: rng.next())
        }
        return value
    }

    // MARK: - Lifecycle

    private mutating func start(now: MonotonicTime) {
        guard !isRunning else { return }
        isRunning = true
        browserHealthySince = nil
        hasReportedLocalNetworkDenied = false
        log("start: id \(configuration.localID) epoch \(configuration.localEpoch)")
        emit(.startListener)
        emit(.startBrowser)
        isBrowserRunning = true
    }

    private mutating func stop(now: MonotonicTime) {
        guard isRunning else { return }
        log("stop")
        for link in links.values.sorted(by: { $0.flow < $1.flow }) where link.isEstablished {
            send(.bye(.stopped), on: link)
        }
        for id in flows.keys.sorted() {
            emit(.cancelFlow(id))
        }
        for peer in peers.values.sorted(by: { $0.id < $1.id }) {
            if peer.primary != nil {
                emit(.setAudioRoute(peer.id, nil))
            }
            if peer.reportedState.map(Self.isUp) == true {
                emitEvent(.linkStateChanged(peer.id, .disconnected(.stopped)))
            }
        }
        peers.removeAll()
        flows.removeAll()
        links.removeAll()
        unboundFlows.removeAll()
        if isBrowserRunning {
            emit(.stopBrowser)
        }
        emit(.stopListener)
        isBrowserRunning = false
        isRunning = false
    }

    private mutating func setAppActive(_ active: Bool, now: MonotonicTime) {
        guard active != isAppActive else { return }
        isAppActive = active
        log(active ? "app active: foreground heartbeats, backoff reset" : "app inactive: background heartbeats")
        for id in Array(links.keys) {
            links[id]?.liveness.isLocalInBackground = !active
            // Tell the peer about the new cadence right away so it adjusts its thresholds.
            if links[id]?.isEstablished == true {
                links[id]?.nextHeartbeatAt = now
            }
        }
        if active {
            resetBackoffAndRedial(now: now)
            restartBrowser(now: now)
        }
    }

    private mutating func pathChanged(now: MonotonicTime) {
        log("network path changed: backoff reset, redial")
        resetBackoffAndRedial(now: now)
        restartBrowser(now: now)
    }

    /// Also forgets any black-hole verdict: after a path change or a return to the foreground the
    /// network may well have recovered.
    private mutating func resetBackoffAndRedial(now: MonotonicTime) {
        for id in Array(peers.keys) {
            guard var peer = peers[id] else { continue }
            peer.backoff.reset()
            peer.clearInterfaceAvoidance()
            peer.isParked = false
            if peer.primary == nil, !hasHandshakingLink(id), canDial(peer) {
                peer.nextDialAt = now + LinkArbiter.dialDelay(local: configuration.localID, remote: id,
                                                              holdoff: configuration.dialHoldoff)
            }
            peers[id] = peer
        }
    }

    static func isUp(_ state: LinkState) -> Bool {
        switch state {
        case .connected, .suspect: return true
        default: return false
        }
    }
}
