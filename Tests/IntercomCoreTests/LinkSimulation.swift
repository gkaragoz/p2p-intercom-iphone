import Foundation
@testable import IntercomCore

/// Keys a flow by the session context both ends derive; opening fails unless both computed the
/// same context, which is what the app's HKDF-derived keys require too.
final class ContextCheckingSealer: PacketSealer {
    let tag: [UInt8]

    init(context: LinkKeyContext) {
        var bytes: [UInt8] = []
        bytes.appendLittleEndian(context.dialerNonce)
        bytes.appendLittleEndian(context.listenerNonce)
        bytes.appendLittleEndian(context.dialerEpoch)
        bytes.appendLittleEndian(context.listenerEpoch)
        bytes.appendLittleEndian(context.linkID)
        bytes.append(contentsOf: Array(context.dialerID.rawValue.utf8.prefix(8)))
        bytes.append(contentsOf: Array(context.listenerID.rawValue.utf8.prefix(8)))
        tag = bytes
    }

    func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8]? {
        payload + tag + Self.checksum(header + payload)
    }

    func open(_ sealed: [UInt8], header: [UInt8]) -> [UInt8]? {
        guard sealed.count >= tag.count + 1 else { return nil }
        let payload = Array(sealed[0..<(sealed.count - tag.count - 1)])
        let receivedTag = Array(sealed[(sealed.count - tag.count - 1)..<(sealed.count - 1)])
        guard receivedTag == tag, sealed.last == Self.checksum(header + payload).first else { return nil }
        return payload
    }

    private static func checksum(_ bytes: [UInt8]) -> [UInt8] {
        [bytes.reduce(UInt8(0x5A)) { ($0 &* 31) &+ $1 }]
    }
}

/// Authenticator with a shared "key"; different keys model different pairing codes.
struct KeyedHelloAuthenticator: HelloAuthenticator {
    let key: UInt8

    func authenticationTag(for message: [UInt8]) -> [UInt8] {
        [message.reduce(key) { ($0 &* 131) &+ $1 }, key]
    }

    func isValidAuthenticationTag(_ tag: [UInt8], for message: [UInt8]) -> Bool {
        tag == authenticationTag(for: message)
    }
}

/// One phone in the simulation: a machine plus the glue a real `NetworkTransport` would provide.
final class SimNode {
    struct Route {
        let remote: SimNode
        var remoteFlow: FlowID?
        let isOutbound: Bool
    }

    let id: PeerID
    var machine: LinkStateMachine
    unowned let network: SimNetwork
    var isRunning = false
    var listenerRunning = false
    var browserRunning = false
    var browserStarts = 0
    var browserStops = 0
    var browserRebuilds = 0
    var listenerRebuilds = 0
    var routes: [FlowID: Route] = [:]
    var sealers: [FlowID: PacketSealer] = [:]
    var cancelled: Set<FlowID> = []
    var opened: [(flow: FlowID, peer: PeerID, prohibited: String?)] = []
    var audioRoutes: [PeerID: LinkStateMachine.AudioRoute] = [:]
    var events: [(time: MonotonicTime, event: TransportEvent)] = []
    var logs: [String] = []
    var sent: [(time: MonotonicTime, flow: FlowID, datagram: NetDatagram)] = []
    /// Path reported for every flow this node opens.
    var reportedPath: (LinkPath, String?) = (.peerToPeerWiFi, "awdl0")
    var failSends = false
    var reportFlowsReady = true
    /// `false` models a dial that avoids an interface and finds no other route to the peer.
    var reportProhibitedFlowsReady = true

    init(id: PeerID, network: SimNetwork, configure: (inout LinkStateMachine.Configuration) -> Void = { _ in },
         authenticator: HelloAuthenticator = UnauthenticatedHello(), seed: UInt64) {
        self.id = id
        self.network = network
        var config = LinkStateMachine.Configuration(localID: id, localEpoch: UInt32(truncatingIfNeeded: seed &* 2_654_435_761) | 1,
                                                    displayName: "Phone \(id.rawValue.suffix(1))", appVersion: "1.0")
        configure(&config)
        machine = LinkStateMachine(configuration: config, authenticator: authenticator, rng: SplitMix64(seed: seed))
    }

    var record: DiscoveryRecord {
        DiscoveryRecord(peerID: id, displayName: machine.configuration.displayName, keyTag: machine.configuration.keyTag)
    }

    func handle(_ input: LinkStateMachine.Input) {
        let effects = machine.handle(input, now: network.now)
        for effect in effects {
            perform(effect)
        }
    }

    private func perform(_ effect: LinkStateMachine.Effect) {
        let now = network.now
        switch effect {
        case .startListener:
            listenerRunning = true
            isRunning = true
        case .stopListener:
            listenerRunning = false
            isRunning = false
        case .rebuildListener:
            listenerRebuilds += 1
        case .startBrowser:
            browserRunning = true
            browserStarts += 1
        case .stopBrowser:
            browserRunning = false
            browserStops += 1
        case .rebuildBrowser:
            browserRunning = true
            browserRebuilds += 1
        case .openFlow(let flow, let peer, let prohibited):
            opened.append((flow, peer, prohibited))
            guard let target = network.nodes[peer] else {
                network.schedule(after: network.latency) { [self] in handle(.flowFailed(flow, reason: "no endpoint")) }
                return
            }
            routes[flow] = Route(remote: target, remoteFlow: nil, isOutbound: true)
            guard reportFlowsReady, prohibited == nil || reportProhibitedFlowsReady else { return }
            let path = reportedPath
            network.schedule(after: network.latency) { [self] in
                guard !cancelled.contains(flow) else { return }
                handle(.flowPathChanged(flow, path.0, interfaceName: path.1))
                handle(.flowReady(flow))
            }
        case .bindFlow(let flow, let context):
            sealers[flow] = ContextCheckingSealer(context: context)
        case .send(let datagram, let flow):
            sent.append((now, flow, datagram))
            guard !cancelled.contains(flow) else { return }
            if datagram.type == .heartbeat || datagram.type == .control {
                let success = !failSends
                network.schedule(after: 0.001) { [self] in handle(.sendCompleted(flow, success: success)) }
            }
            guard !failSends, let data = try? datagram.encoded(sealer: sealers[flow]) else { return }
            network.transmit(data, from: self, on: flow)
        case .cancelFlow(let flow):
            cancelled.insert(flow)
            sealers[flow] = nil
        case .setAudioRoute(let peer, let route):
            audioRoutes[peer] = route
        case .event(let event):
            events.append((now, event))
        case .log(let line):
            logs.append(String(format: "[%.3f] ", now.seconds) + line)
        }
    }

    /// Called by the network when a datagram for this node arrives from `source` on its flow `sourceFlow`.
    func deliver(_ data: Data, from source: SimNode, sourceFlow: FlowID, sourceRoute: Route) {
        guard isRunning else { return }
        var localFlow: FlowID
        if sourceRoute.isOutbound {
            if let existing = sourceRoute.remoteFlow, !cancelled.contains(existing), routes[existing] != nil {
                localFlow = existing
            } else {
                localFlow = machine.makeFlowID()
                routes[localFlow] = Route(remote: source, remoteFlow: sourceFlow, isOutbound: false)
                source.routes[sourceFlow]?.remoteFlow = localFlow
                handle(.inboundFlow(localFlow))
            }
        } else {
            guard let target = sourceRoute.remoteFlow else { return }
            localFlow = target
        }
        guard !cancelled.contains(localFlow) else { return }
        do {
            let datagram = try NetDatagram.decode(data, opener: sealers[localFlow])
            handle(.datagram(datagram, on: localFlow))
        } catch let error as NetDatagramError {
            handle(.undecodableDatagram(localFlow, error))
        } catch {}
    }

    func linkEvents(for peer: PeerID) -> [LinkState] {
        events.compactMap {
            if case .linkStateChanged(let id, let state) = $0.event, id == peer { return state }
            return nil
        }
    }

    func lastLinkState(for peer: PeerID) -> LinkState? {
        linkEvents(for: peer).last
    }
}

/// Discrete-event network with a synthetic monotonic clock.
final class SimNetwork {
    var now = MonotonicTime(seconds: 1_000)
    var latency: TimeInterval = 0.005
    var nodes: [PeerID: SimNode] = [:]
    /// Return `true` to drop a datagram.
    var dropFilter: ((_ from: SimNode, _ datagram: NetDatagram) -> Bool)?
    var isPartitioned = false
    private var queue: [(at: MonotonicTime, order: Int, action: () -> Void)] = []
    private var order = 0
    private var nextTick: [PeerID: MonotonicTime] = [:]

    static let lowID = PeerID(installID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    static let highID = PeerID(installID: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

    @discardableResult
    func addNode(_ id: PeerID, seed: UInt64, authenticator: HelloAuthenticator = UnauthenticatedHello(),
                 configure: (inout LinkStateMachine.Configuration) -> Void = { _ in }) -> SimNode {
        let node = SimNode(id: id, network: self, configure: configure, authenticator: authenticator, seed: seed)
        nodes[id] = node
        return node
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        order += 1
        queue.append((now + delay, order, action))
    }

    func transmit(_ data: Data, from node: SimNode, on flow: FlowID) {
        guard let route = node.routes[flow] else { return }
        if isPartitioned { return }
        if let dropFilter, let datagram = try? NetDatagram.decode(data, opener: node.sealers[flow]),
           dropFilter(node, datagram) {
            return
        }
        let target = route.remote
        schedule(after: latency) {
            // Re-read the route: the listener side may have been created by an earlier datagram.
            guard let current = node.routes[flow] else { return }
            target.deliver(data, from: node, sourceFlow: flow, sourceRoute: current)
        }
    }

    /// Runs events and 50 ms ticks for every running node until `now + duration`.
    func run(for duration: TimeInterval, until condition: (() -> Bool)? = nil) {
        let end = now + duration
        while true {
            if let condition, condition() { return }
            let earliestEvent = queue.min { ($0.at, $0.order) < ($1.at, $1.order) }
            let running = nodes.values.filter { $0.isRunning }
            var earliestTick: (MonotonicTime, SimNode)?
            for node in running {
                let at = nextTick[node.id] ?? now
                if earliestTick == nil || at < earliestTick!.0 { earliestTick = (at, node) }
            }
            let eventTime = earliestEvent?.at
            let tickTime = earliestTick?.0
            guard let nextTime = [eventTime, tickTime].compactMap({ $0 }).min(), nextTime <= end else {
                now = end
                return
            }
            now = max(now, nextTime)
            if let event = earliestEvent, event.at == nextTime {
                queue.removeAll { $0.order == event.order }
                event.action()
            } else if let (_, node) = earliestTick {
                nextTick[node.id] = now + LinkStateMachine.recommendedTickInterval
                node.handle(.tick)
            }
        }
    }

    /// Replaces a node with a fresh app instance (new epoch), as after a crash and relaunch.
    @discardableResult
    func restart(_ id: PeerID, seed: UInt64, authenticator: HelloAuthenticator = UnauthenticatedHello()) -> SimNode {
        nodes[id]?.isRunning = false
        let fresh = addNode(id, seed: seed, authenticator: authenticator)
        nextTick[id] = nil
        return fresh
    }
}
