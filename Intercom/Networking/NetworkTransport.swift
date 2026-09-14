import Foundation
import Network
import os

/// The default connection engine: Bonjour discovery plus one UDP flow per peer, on Network framework.
///
///     NWListener  ── advertises _intercom-nw._udp (instance = install UUID, TXT = DiscoveryRecord)
///     NWBrowser   ── finds peers; results keyed by the TXT install ID, never by endpoint
///     NWConnection ─ one UDP flow per link (dialled, or delivered by the listener), carrying the
///                    NetDatagram session protocol: HELLO/HELLO_ACK, heartbeats, control, audio, bye
///
/// Every decision — who dials, handshakes, duplicate flows, liveness, backoff, browser policy — is made
/// by `LinkStateMachine` in Core. This class is the glue its contract describes: it turns framework
/// callbacks into machine inputs and performs the effects. All of that happens on one serial `queue`
/// (listener, browser, path monitor, every connection and the 50 ms tick).
///
/// Audio bypasses the machine in both directions: `sendAudio` seals and sends straight from the capture
/// thread over the route the machine last selected (`.idempotent`, no per-packet callback), and
/// received audio on a bound flow goes straight to `onAudio`.
///
/// Parameters on everything: peer-to-peer Wi-Fi included (it must be set on listener, browser *and*
/// connections), `.interactiveVoice` service class, cellular prohibited. No IP version is forced (peer-to-
/// peer uses IPv6 link-local) and Wi-Fi is not required as interface type (awdl0 may not report as Wi-Fi).
final class NetworkTransport: PeerTransport, @unchecked Sendable {
    let kind: TransportKind = .network
    let localPeerID: PeerID

    var onEvent: (@Sendable (TransportEvent) -> Void)? {
        get { callbackLock.withLock { _onEvent } }
        set { callbackLock.withLock { _onEvent = newValue } }
    }

    var onAudio: (@Sendable (AudioPacket, PeerID) -> Void)? {
        get { callbackLock.withLock { _onAudio } }
        set { callbackLock.withLock { _onAudio = newValue } }
    }

    /// Delay before a failed listener or browser is created again: 0.5, 1, 2, 5, 5, … s.
    private static let rebuildDelays: [TimeInterval] = [0.5, 1, 2, 5]
    /// Seconds a listener may be ready without a Bonjour registration before it is rebuilt (doubles per strike).
    private static let registrationWatchdog: TimeInterval = 3
    /// Peers the previous browser listed but a new one has not listed after this long are reported lost.
    private static let staleResultCheckDelay: TimeInterval = 5
    /// Unsent datagrams (a final `bye`) get this long before their flow is cancelled regardless.
    private static let cancelGracePeriod: TimeInterval = 0.5
    /// `kDNSServiceErr_PolicyDenied`: how Bonjour reports a denied Local Network permission.
    private static let dnsPolicyDenied: DNSServiceErrorType = -65570
    private static let log = Logger(subsystem: "intercom", category: "transport.network")

    private let displayName: String
    private let appVersion: String
    private let pairingKey: PairingKey
    private let queue = DispatchQueue(label: "intercom.transport.network", qos: .userInitiated)

    private let callbackLock = NSLock()
    private var _onEvent: (@Sendable (TransportEvent) -> Void)?
    private var _onAudio: (@Sendable (AudioPacket, PeerID) -> Void)?

    // MARK: Capture-thread state (audioLock)

    /// What `sendAudio` needs, written by the queue and read by the capture thread.
    private struct AudioRoute {
        let peer: PeerID
        let connection: NWConnection
        let sealer: ChaChaPolySealer
        let linkID: UInt32
    }

    private let audioLock = UnfairLock()
    private var audioRoutesByPeer: [PeerID: AudioRoute] = [:]
    private var audioRoutes: [AudioRoute] = []
    private var audioEpoch: UInt32 = 0
    private var audioStatus = RemoteStatus()
    private var audioIsInBackground = false

    // MARK: Queue-confined state

    /// One `NWConnection` as the machine's `FlowID` sees it.
    private final class Flow {
        let id: FlowID
        let connection: NWConnection
        let isOutbound: Bool
        /// Dial target, or the peer a completed handshake bound the flow to.
        var remotePeer: PeerID?
        var sealer: ChaChaPolySealer?
        var pendingSends = 0
        var isCancelling = false
        var isCancelled = false
        var isReceiving = false
        var hasLoggedReady = false
        var consecutiveSendErrors = 0
        var receiveErrors = 0

        init(id: FlowID, connection: NWConnection, isOutbound: Bool) {
            self.id = id
            self.connection = connection
            self.isOutbound = isOutbound
        }
    }

    private var machine: LinkStateMachine?
    private var inputBacklog: [LinkStateMachine.Input] = []
    private var isDrainingInputs = false
    private var isAppActive = true
    private var localStatus = RemoteStatus()
    private var tickTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    /// Interfaces seen on flows and in the path monitor, for `prohibitedInterfaces` (needs the object, not the name).
    private var interfacesByName: [String: NWInterface] = [:]
    private var hasReportedLocalNetworkDenied = false

    private var listener: NWListener?
    private var listenerRegistrations = 0
    /// Bonjour name of our current registration (Bonjour renames it on a conflict).
    private var registeredServiceName: String?
    private var listenerFailures = 0
    private var listenerWatchdogStrikes = 0
    private var listenerWatchdog: DispatchWorkItem?
    private var listenerRetry: DispatchWorkItem?

    private var browser: NWBrowser?
    private var wantsBrowser = false
    private var browserFailures = 0
    private var browserRetry: DispatchWorkItem?
    /// Results of the current browser: endpoint → install ID.
    private var listedResults: [NWEndpoint: PeerID] = [:]
    /// Peers an earlier browser listed; reported lost unless the current browser lists them again.
    private var possiblyStalePeers: Set<PeerID> = []
    private var staleCheck: DispatchWorkItem?
    /// Last Bonjour endpoint of every peer seen this run. Kept after `.removed`: a peer that was linked
    /// is redialled even when discovery lost it (Bonjour removal over peer-to-peer Wi-Fi is unreliable).
    private var endpoints: [PeerID: NWEndpoint] = [:]

    private var flows: [FlowID: Flow] = [:]
    /// Flows waiting for their last datagrams to leave before `cancel()`.
    private var closingFlows: [ObjectIdentifier: Flow] = [:]

    init(localPeerID: PeerID, displayName: String, appVersion: String, pairingCode: String) {
        self.localPeerID = localPeerID
        self.displayName = DisplayName.sanitized(displayName)
        self.appVersion = appVersion
        pairingKey = PairingKey(code: pairingCode)
    }

    deinit {
        tickTimer?.cancel()
        pathMonitor?.cancel()
        listener?.cancel()
        browser?.cancel()
        for flow in flows.values {
            flow.connection.cancel()
        }
        for flow in closingFlows.values {
            flow.connection.cancel()
        }
    }

    // MARK: - PeerTransport

    func start() {
        queue.async { [self] in startNow() }
    }

    func stop() {
        queue.async { [self] in stopNow() }
    }

    func connect(to peer: PeerID) {
        queue.async { [self] in submit(.connect(peer)) }
    }

    func disconnectAll() {
        queue.async { [self] in submit(.disconnectAll) }
    }

    func sendControl(_ message: ControlMessage) {
        queue.async { [self] in submit(.sendControl(message)) }
    }

    func updateLocalStatus(_ status: RemoteStatus) {
        audioLock.withLock { audioStatus = status }
        queue.async { [self] in
            localStatus = status
            submit(.updateLocalStatus(status))
        }
    }

    func setAppActive(_ active: Bool) {
        audioLock.withLock { audioIsInBackground = !active }
        queue.async { [self] in
            guard active != isAppActive else { return }
            isAppActive = active
            submit(.setAppActive(active))
        }
    }

    /// Capture thread. Status and background bits ride in the header, so audio refreshes them as well.
    func sendAudio(_ packet: AudioPacket) {
        audioLock.lock()
        let routes = audioRoutes
        let epoch = audioEpoch
        let status = audioStatus
        let isInBackground = audioIsInBackground
        audioLock.unlock()
        for route in routes {
            let datagram = NetDatagram(linkID: route.linkID, senderEpoch: epoch, status: status,
                                       isSenderInBackground: isInBackground, payload: .audio(packet))
            guard let data = try? datagram.encoded(sealer: route.sealer) else { continue }
            route.connection.send(content: data, completion: .idempotent)
        }
    }

    // MARK: - Lifecycle (queue)

    private func startNow() {
        guard machine == nil else { return }
        var configuration = LinkStateMachine.Configuration(
            localID: localPeerID,
            // A new epoch per start: the peer must see a restart, not a resumption of the old instance.
            localEpoch: UInt32.random(in: 1...UInt32.max),
            displayName: displayName,
            appVersion: appVersion
        )
        configuration.keyTag = pairingKey.keyTag
        machine = LinkStateMachine(configuration: configuration, authenticator: pairingKey.helloAuthenticator,
                                   rng: SplitMix64())
        audioLock.withLock { audioEpoch = configuration.localEpoch }
        hasReportedLocalNetworkDenied = false
        lastPathSignature = nil
        listenerFailures = 0
        listenerWatchdogStrikes = 0
        browserFailures = 0
        Self.log.notice("""
            starting: id \(self.localPeerID.rawValue, privacy: .public) name "\(self.displayName, privacy: .public)" \
            epoch \(configuration.localEpoch, privacy: .public) key tag \(self.pairingKey.keyTag, privacy: .public)\
            \(self.pairingKey.isDefault ? " (default pairing code)" : "", privacy: .public) \
            app \(self.isAppActive ? "active" : "in background", privacy: .public)
            """)
        startPathMonitor()
        startTickTimer()
        submit(.start)
        if !isAppActive {
            submit(.setAppActive(false))
        }
        submit(.updateLocalStatus(localStatus))
    }

    private func stopNow() {
        guard machine != nil else { return }
        Self.log.notice("stopping")
        // Sends `bye` on every up link and cancels every flow (after the byes left).
        submit(.stop)
        machine = nil
        inputBacklog.removeAll()
        tickTimer?.cancel()
        tickTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        wantsBrowser = false
        stopBrowser()
        stopListener()
        staleCheck?.cancel()
        staleCheck = nil
        possiblyStalePeers.removeAll()
        for id in flows.keys.sorted() {
            cancelFlow(id)
        }
        audioLock.withLock {
            audioRoutesByPeer.removeAll()
            audioRoutes.removeAll()
        }
        endpoints.removeAll()
        interfacesByName.removeAll()
    }

    private func startTickTimer() {
        tickTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = LinkStateMachine.recommendedTickInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.submit(.tick)
        }
        timer.resume()
        tickTimer = timer
    }

    // MARK: - Machine glue (queue)

    /// Feeds an input to the machine and performs its effects. Inputs raised while effects are being
    /// performed (for example `.flowFailed` for a dial without an endpoint) are queued and handled
    /// afterwards, so the effects of one input are always performed completely and in order.
    private func submit(_ input: LinkStateMachine.Input) {
        guard machine != nil else { return }
        inputBacklog.append(input)
        guard !isDrainingInputs else { return }
        isDrainingInputs = true
        var index = 0
        while index < inputBacklog.count {
            let next = inputBacklog[index]
            index += 1
            guard let effects = machine?.handle(next, now: .now()) else { break }
            for effect in effects {
                perform(effect)
            }
        }
        inputBacklog.removeAll(keepingCapacity: true)
        isDrainingInputs = false
    }

    private func perform(_ effect: LinkStateMachine.Effect) {
        switch effect {
        case .startListener:
            startListener()
        case .stopListener:
            stopListener()
        case .rebuildListener:
            Self.log.notice("rebuilding listener (new port and Bonjour registration)")
            stopListener()
            startListener()
        case .startBrowser:
            wantsBrowser = true
            startBrowser()
        case .stopBrowser:
            wantsBrowser = false
            stopBrowser()
        case .rebuildBrowser:
            wantsBrowser = true
            stopBrowser()
            startBrowser()
        case .openFlow(let id, let peer, let prohibitedInterfaceName):
            openFlow(id, to: peer, prohibiting: prohibitedInterfaceName)
        case .bindFlow(let id, let context):
            bindFlow(id, context: context)
        case .send(let datagram, let id):
            send(datagram, on: id)
        case .cancelFlow(let id):
            cancelFlow(id)
        case .setAudioRoute(let peer, let route):
            setAudioRoute(route, for: peer)
        case .event(let event):
            deliver(event)
        case .log(let line):
            // Notice, not info: the state machine logs per event (never per packet; undecodable
            // datagrams are rate-limited), and info lines stay in memory only on iOS, so a
            // `log collect` after a background test would lose disconnect reasons and backoffs.
            Self.log.notice("\(line, privacy: .public)")
        }
    }

    private func deliver(_ event: TransportEvent) {
        switch event {
        case .linkStateChanged(let peer, let state):
            Self.log.notice("link \(peer.rawValue, privacy: .public): \(String(describing: state), privacy: .public)")
        case .warning(let warning):
            Self.log.error("warning: \(String(describing: warning), privacy: .public)")
        case .warningCleared(let warning):
            Self.log.notice("warning cleared: \(String(describing: warning), privacy: .public)")
        case .peerDiscovered(let advert):
            Self.log.info("""
                peer \(advert.id.rawValue, privacy: .public) "\(advert.displayName, privacy: .public)" \
                \(String(describing: advert.compatibility), privacy: .public)
                """)
        case .peerLost, .control, .remoteStatus, .roundTrip:
            break
        }
        onEvent?(event)
    }

    private func reportLocalNetworkDenied(source: String) {
        Self.log.error("\(source, privacy: .public): Local Network permission denied")
        guard !hasReportedLocalNetworkDenied else { return }
        hasReportedLocalNetworkDenied = true
        deliver(.warning(.localNetworkDenied))
    }

    /// Bonjour works after all: TN3179 says the policy check can fail while the permission alert is
    /// still on screen, and the system retries on its own once the user allows access.
    private func reportLocalNetworkAllowed(source: String) {
        guard hasReportedLocalNetworkDenied else { return }
        hasReportedLocalNetworkDenied = false
        Self.log.notice("\(source, privacy: .public): Local Network access works now")
        deliver(.warningCleared(.localNetworkDenied))
    }

    private static func isLocalNetworkDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == dnsPolicyDenied
        }
        return false
    }

    private static func parameters(prohibiting interface: NWInterface?) -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVoice
        parameters.prohibitedInterfaceTypes = [.cellular]
        if let interface {
            parameters.prohibitedInterfaces = [interface]
        }
        return parameters
    }

    // MARK: - Path monitor (queue)

    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.cellular])
        monitor.pathUpdateHandler = { [weak self] path in
            self?.networkPathUpdated(path)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func networkPathUpdated(_ path: NWPath) {
        guard machine != nil else { return }
        for interface in path.availableInterfaces {
            interfacesByName[interface.name] = interface
        }
        var seen = Set<String>()
        let interfaces = path.availableInterfaces
            .filter { seen.insert($0.name).inserted }
            .map { "\($0.name)(\($0.type))" }
            .joined(separator: ",")
        let signature = "\(path.status) [\(interfaces)]"
        guard signature != lastPathSignature else { return }
        let isFirst = lastPathSignature == nil
        lastPathSignature = signature
        Self.log.notice("network path \(signature, privacy: .public)")
        if !isFirst {
            submit(.pathChanged)
        }
    }

    // MARK: - Listener (queue)

    private func startListener() {
        guard listener == nil, machine != nil else { return }
        listenerRetry?.cancel()
        listenerRetry = nil
        let listener: NWListener
        do {
            listener = try NWListener(using: Self.parameters(prohibiting: nil))
        } catch {
            Self.log.error("listener could not be created: \(String(describing: error), privacy: .public)")
            deliver(.warning(.listenerFailed(String(describing: error))))
            scheduleListenerRetry()
            return
        }
        let record = DiscoveryRecord(peerID: localPeerID, displayName: displayName, keyTag: pairingKey.keyTag)
        listener.service = NWListener.Service(name: localPeerID.rawValue, type: IntercomProtocol.Network.serviceType,
                                              domain: nil, txtRecord: NWTXTRecord(record.txtRecord))
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            self.listenerStateChanged(state, port: listener.port)
        }
        listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
            guard let self, let listener, self.listener === listener else { return }
            self.listenerRegistrationChanged(change)
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.listener === listener else {
                connection.cancel()
                return
            }
            self.acceptInbound(connection)
        }
        self.listener = listener
        listenerRegistrations = 0
        listener.start(queue: queue)
        Self.log.info("listener starting (\(IntercomProtocol.Network.serviceType, privacy: .public))")
    }

    private func stopListener() {
        listenerWatchdog?.cancel()
        listenerWatchdog = nil
        listenerRetry?.cancel()
        listenerRetry = nil
        guard let listener else { return }
        self.listener = nil
        listenerRegistrations = 0
        registeredServiceName = nil
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        Self.log.info("listener stopped")
    }

    private func listenerStateChanged(_ state: NWListener.State, port: NWEndpoint.Port?) {
        switch state {
        case .setup:
            break
        case .waiting(let error):
            Self.log.error("listener waiting: \(String(describing: error), privacy: .public)")
            if Self.isLocalNetworkDenied(error) {
                reportLocalNetworkDenied(source: "listener")
            }
        case .ready:
            Self.log.notice("listener ready on port \(port.map { String($0.rawValue) } ?? "?", privacy: .public)")
            armListenerWatchdog()
        case .failed(let error):
            Self.log.error("listener failed: \(String(describing: error), privacy: .public)")
            if Self.isLocalNetworkDenied(error) {
                reportLocalNetworkDenied(source: "listener")
            }
            deliver(.warning(.listenerFailed(String(describing: error))))
            stopListener()
            scheduleListenerRetry()
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func listenerRegistrationChanged(_ change: NWListener.ServiceRegistrationChange) {
        switch change {
        case .add(let endpoint):
            listenerRegistrations += 1
            listenerFailures = 0
            listenerWatchdogStrikes = 0
            listenerWatchdog?.cancel()
            listenerWatchdog = nil
            reportLocalNetworkAllowed(source: "listener registration")
            if case .service(let name, _, _, _) = endpoint {
                registeredServiceName = name
            }
            Self.log.notice("listener registered \(String(describing: endpoint), privacy: .public)")
        case .remove(let endpoint):
            listenerRegistrations = max(0, listenerRegistrations - 1)
            Self.log.notice("listener registration removed \(String(describing: endpoint), privacy: .public)")
            if listenerRegistrations == 0 {
                armListenerWatchdog()
            }
        @unknown default:
            break
        }
    }

    /// A listener can be `.ready` without ever being registered with Bonjour (mDNSResponder restarts,
    /// interface churn); nobody can dial it then, so it is rebuilt. The delay doubles per strike so an
    /// environment where registration is impossible (Wi-Fi off) does not rebuild in a tight loop.
    private func armListenerWatchdog() {
        listenerWatchdog?.cancel()
        guard listenerRegistrations == 0 else { return }
        let delay = Self.registrationWatchdog * pow(2, Double(min(listenerWatchdogStrikes, 3)))
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.machine != nil, self.listener != nil, self.listenerRegistrations == 0 else { return }
            self.listenerWatchdogStrikes += 1
            Self.log.error("listener not registered with Bonjour after \(delay, privacy: .public)s: rebuilding")
            self.stopListener()
            self.startListener()
        }
        listenerWatchdog = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleListenerRetry() {
        let delay = Self.rebuildDelays[min(listenerFailures, Self.rebuildDelays.count - 1)]
        listenerFailures += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.machine != nil, self.listener == nil else { return }
            self.listenerRetry = nil
            self.startListener()
        }
        listenerRetry?.cancel()
        listenerRetry = item
        Self.log.notice("listener retry in \(delay, privacy: .public)s")
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Browser (queue)

    private func startBrowser() {
        guard browser == nil, machine != nil, wantsBrowser else { return }
        browserRetry?.cancel()
        browserRetry = nil
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: IntercomProtocol.Network.serviceType, domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            self.browserStateChanged(state)
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] _, changes in
            guard let self, let browser, self.browser === browser else { return }
            self.browseResultsChanged(changes)
        }
        self.browser = browser
        possiblyStalePeers.formUnion(listedResults.values)
        listedResults.removeAll()
        scheduleStaleResultCheck()
        browser.start(queue: queue)
        Self.log.info("browser started")
    }

    private func stopBrowser() {
        browserRetry?.cancel()
        browserRetry = nil
        staleCheck?.cancel()
        staleCheck = nil
        guard let browser else { return }
        self.browser = nil
        possiblyStalePeers.formUnion(listedResults.values)
        listedResults.removeAll()
        browser.stateUpdateHandler = nil
        browser.browseResultsChangedHandler = nil
        browser.cancel()
        Self.log.info("browser stopped")
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .setup:
            break
        case .ready:
            browserFailures = 0
            Self.log.info("browser ready")
        case .waiting(let error):
            Self.log.error("browser waiting: \(String(describing: error), privacy: .public)")
            if Self.isLocalNetworkDenied(error) {
                reportLocalNetworkDenied(source: "browser")
            }
        case .failed(let error):
            Self.log.error("browser failed: \(String(describing: error), privacy: .public)")
            if Self.isLocalNetworkDenied(error) {
                reportLocalNetworkDenied(source: "browser")
            }
            deliver(.warning(.browserFailed(String(describing: error))))
            stopBrowser()
            scheduleBrowserRetry()
        case .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func scheduleBrowserRetry() {
        let delay = Self.rebuildDelays[min(browserFailures, Self.rebuildDelays.count - 1)]
        browserFailures += 1
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.browserRetry = nil
            self.startBrowser()
        }
        browserRetry?.cancel()
        browserRetry = item
        Self.log.notice("browser retry in \(delay, privacy: .public)s")
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func browseResultsChanged(_ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                resultListed(result)
            case .removed(let result):
                resultUnlisted(result)
            case .changed(old: let old, new: let new, flags: let flags):
                Self.log.info("browser result changed (\(String(describing: flags), privacy: .public))")
                let previous = listedResults.removeValue(forKey: old.endpoint)
                let current = resultListed(new)
                if let previous, previous != current {
                    if let remaining = listedResults.first(where: { $0.value == previous }) {
                        endpoints[previous] = remaining.key
                    } else {
                        submit(.peerLost(previous))
                    }
                }
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    @discardableResult
    private func resultListed(_ result: NWBrowser.Result) -> PeerID? {
        guard case .bonjour(let txt) = result.metadata, let record = DiscoveryRecord(txtRecord: txt.dictionary) else {
            Self.log.info("browser result without a usable TXT record: \(String(describing: result.endpoint), privacy: .public)")
            return nil
        }
        // Any listed result, our own included, proves browsing is allowed.
        reportLocalNetworkAllowed(source: "browser result")
        // Our own listener shows up in our own browser.
        guard record.peerID != localPeerID else {
            if case .service(let name, _, _, _) = result.endpoint, let registered = registeredServiceName, name != registered {
                // Same install ID under another Bonjour name: a second device carries our identity, and
                // the two phones would ignore each other for good.
                Self.log.error("""
                    another device advertises our install ID as "\(name, privacy: .public)" \
                    (ours: "\(registered, privacy: .public)"); it is ignored as ourselves
                    """)
            } else {
                Self.log.debug("browser lists our own listener at \(String(describing: result.endpoint), privacy: .public)")
            }
            return nil
        }
        listedResults[result.endpoint] = record.peerID
        endpoints[record.peerID] = result.endpoint
        possiblyStalePeers.remove(record.peerID)
        for interface in result.interfaces {
            interfacesByName[interface.name] = interface
        }
        let interfaces = result.interfaces.map(\.name).joined(separator: ",")
        Self.log.info("""
            browser lists \(record.peerID.rawValue, privacy: .public) at \(String(describing: result.endpoint), privacy: .public) \
            via [\(interfaces, privacy: .public)]
            """)
        submit(.peerDiscovered(record))
        return record.peerID
    }

    private func resultUnlisted(_ result: NWBrowser.Result) {
        var peer = listedResults.removeValue(forKey: result.endpoint)
        if peer == nil, case .bonjour(let txt) = result.metadata {
            peer = DiscoveryRecord(txtRecord: txt.dictionary)?.peerID
        }
        guard let peer, peer != localPeerID else { return }
        if let remaining = listedResults.first(where: { $0.value == peer }) {
            // Still listed under another endpoint (e.g. a restarted listener registered before the old
            // registration went away): dial that one from now on.
            endpoints[peer] = remaining.key
            return
        }
        Self.log.info("browser no longer lists \(peer.rawValue, privacy: .public)")
        submit(.peerLost(peer))
    }

    /// A rebuilt or restarted browser starts with no results; peers the previous one listed are only
    /// reported lost if the new one does not find them again within a few seconds.
    private func scheduleStaleResultCheck() {
        staleCheck?.cancel()
        staleCheck = nil
        guard !possiblyStalePeers.isEmpty else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.browser != nil else { return }
            self.staleCheck = nil
            let listed = Set(self.listedResults.values)
            let gone = self.possiblyStalePeers.subtracting(listed)
            self.possiblyStalePeers.removeAll()
            for peer in gone.sorted() {
                Self.log.info("\(peer.rawValue, privacy: .public) not listed again by the new browser")
                self.submit(.peerLost(peer))
            }
        }
        staleCheck = item
        queue.asyncAfter(deadline: .now() + Self.staleResultCheckDelay, execute: item)
    }

    // MARK: - Flows (queue)

    private func acceptInbound(_ connection: NWConnection) {
        guard let id = machine?.makeFlowID() else {
            connection.cancel()
            return
        }
        let flow = Flow(id: id, connection: connection, isOutbound: false)
        flows[id] = flow
        configureHandlers(of: flow)
        Self.log.info("\(id, privacy: .public) inbound from \(String(describing: connection.endpoint), privacy: .public)")
        connection.start(queue: queue)
        receiveNext(on: flow)
        submit(.inboundFlow(id))
    }

    private func openFlow(_ id: FlowID, to peer: PeerID, prohibiting interfaceName: String?) {
        guard let endpoint = endpoints[peer] else {
            Self.log.error("\(id, privacy: .public): no Bonjour endpoint known for \(peer.rawValue, privacy: .public)")
            submit(.flowFailed(id, reason: "no endpoint known"))
            return
        }
        var prohibited: NWInterface?
        if let interfaceName {
            prohibited = interfacesByName[interfaceName]
            if prohibited == nil {
                Self.log.error("\(id, privacy: .public): cannot avoid \(interfaceName, privacy: .public), interface unknown")
            }
        }
        let connection = NWConnection(to: endpoint, using: Self.parameters(prohibiting: prohibited))
        let flow = Flow(id: id, connection: connection, isOutbound: true)
        flow.remotePeer = peer
        flows[id] = flow
        configureHandlers(of: flow)
        Self.log.info("""
            \(id, privacy: .public) dialling \(peer.rawValue, privacy: .public) at \(String(describing: endpoint), privacy: .public)\
            \(prohibited.map { " avoiding \($0.name)" } ?? "", privacy: .public)
            """)
        connection.start(queue: queue)
        receiveNext(on: flow)
    }

    private func configureHandlers(of flow: Flow) {
        let connection = flow.connection
        connection.stateUpdateHandler = { [weak self, weak flow] state in
            guard let self, let flow else { return }
            self.flowStateChanged(flow, state: state)
        }
        connection.pathUpdateHandler = { [weak self, weak flow] path in
            guard let self, let flow else { return }
            self.flowPathUpdated(flow, path: path)
        }
        connection.viabilityUpdateHandler = { [weak self, weak flow] isViable in
            guard let self, let flow, self.isCurrent(flow) else { return }
            self.submit(.flowViabilityChanged(flow.id, isViable: isViable))
        }
        connection.betterPathUpdateHandler = { [weak self, weak flow] isBetterPathAvailable in
            guard let self, let flow, isBetterPathAvailable, self.isCurrent(flow) else { return }
            Self.log.info("\(flow.id, privacy: .public) better path available")
            self.submit(.flowBetterPathAvailable(flow.id))
        }
    }

    private func isCurrent(_ flow: Flow) -> Bool {
        !flow.isCancelling && flows[flow.id] === flow
    }

    private func flowStateChanged(_ flow: Flow, state: NWConnection.State) {
        let connection = flow.connection
        switch state {
        case .setup, .preparing:
            break
        case .ready:
            if !flow.hasLoggedReady {
                flow.hasLoggedReady = true
                Self.log.info("\(flow.id, privacy: .public) ready, max datagram \(connection.maximumDatagramSize, privacy: .public) bytes")
            }
            if !flow.isReceiving, !flow.isCancelled {
                receiveNext(on: flow)
            }
            guard isCurrent(flow) else { return }
            if let path = connection.currentPath {
                flowPathUpdated(flow, path: path)
            }
            submit(.flowReady(flow.id))
        case .waiting(let error):
            let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied || Self.isLocalNetworkDenied(error)
            Self.log.error("""
                \(flow.id, privacy: .public) waiting: \(String(describing: error), privacy: .public)\
                \(denied ? " (Local Network permission denied)" : "", privacy: .public)
                """)
            guard isCurrent(flow) else { return }
            submit(.flowWaiting(flow.id, localNetworkDenied: denied))
        case .failed(let error):
            Self.log.error("\(flow.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if isCurrent(flow) {
                submit(.flowFailed(flow.id, reason: String(describing: error)))
            }
            // The machine cancels flows it knows; make sure an unknown or lingering one goes too.
            if flows[flow.id] === flow {
                cancelFlow(flow.id)
            } else if !flow.isCancelled {
                finishCancel(flow)
            }
        case .cancelled:
            closingFlows[ObjectIdentifier(flow)] = nil
        @unknown default:
            break
        }
    }

    private func flowPathUpdated(_ flow: Flow, path: NWPath) {
        let interface = Self.interfaceInUse(path)
        if let interface {
            interfacesByName[interface.name] = interface
        }
        guard isCurrent(flow) else { return }
        let linkPath = LinkPathClassifier.classify(interfaceName: interface?.name,
                                                   isWiFi: interface?.type == .wifi,
                                                   isWired: interface?.type == .wiredEthernet)
        submit(.flowPathChanged(flow.id, linkPath, interfaceName: interface?.name))
    }

    /// The scope of a link-local remote address names the interface the flow really uses (awdl0 for
    /// peer-to-peer Wi-Fi); otherwise the first available interface is the one Network framework prefers.
    /// Interface names are for display and the black-hole fallback only, never for other decisions.
    private static func interfaceInUse(_ path: NWPath) -> NWInterface? {
        if case .hostPort(let host, _)? = path.remoteEndpoint {
            switch host {
            case .ipv6(let address):
                if let interface = address.interface { return interface }
            case .ipv4(let address):
                if let interface = address.interface { return interface }
            default:
                break
            }
        }
        return path.availableInterfaces.first
    }

    private func bindFlow(_ id: FlowID, context: LinkKeyContext) {
        guard let flow = flows[id] else { return }
        flow.sealer = ChaChaPolySealer(key: pairingKey, context: context)
        flow.remotePeer = context.remoteID
        Self.log.info("""
            \(id, privacy: .public) keyed for link \(context.linkID, privacy: .public) with \(context.remoteID.rawValue, privacy: .public) \
            (\(context.isLocalDialer ? "we dialled" : "they dialled", privacy: .public))
            """)
    }

    private func send(_ datagram: NetDatagram, on id: FlowID) {
        guard let flow = flows[id], !flow.isCancelling else { return }
        let reportsCompletion = datagram.type == .heartbeat || datagram.type == .control
        let data: Data
        do {
            data = try datagram.encoded(sealer: flow.sealer)
        } catch {
            Self.log.error("\(id, privacy: .public): cannot encode \(String(describing: datagram.type), privacy: .public): \(String(describing: error), privacy: .public)")
            if reportsCompletion {
                submit(.sendCompleted(id, success: false))
            }
            return
        }
        flow.pendingSends += 1
        flow.connection.send(content: data, completion: .contentProcessed { [weak self, weak flow] error in
            guard let self, let flow else { return }
            flow.pendingSends -= 1
            if let error {
                flow.consecutiveSendErrors += 1
                if flow.consecutiveSendErrors == 1 || flow.consecutiveSendErrors % 50 == 0 {
                    Self.log.error("\(flow.id, privacy: .public) send error #\(flow.consecutiveSendErrors, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            } else {
                flow.consecutiveSendErrors = 0
            }
            if flow.isCancelling {
                if flow.pendingSends == 0 {
                    self.finishCancel(flow)
                }
                return
            }
            if reportsCompletion, self.isCurrent(flow) {
                self.submit(.sendCompleted(flow.id, success: error == nil))
            }
        })
    }

    private func cancelFlow(_ id: FlowID) {
        guard let flow = flows.removeValue(forKey: id) else { return }
        flow.isCancelling = true
        audioLock.withLock {
            if audioRoutes.contains(where: { $0.connection === flow.connection }) {
                audioRoutesByPeer = audioRoutesByPeer.filter { $0.value.connection !== flow.connection }
                audioRoutes = Array(audioRoutesByPeer.values)
            }
        }
        guard flow.pendingSends > 0 else {
            finishCancel(flow)
            return
        }
        // Let a final bye leave first; `send`'s completion finishes the cancel, this is the backstop.
        // It holds the transport strongly, so a `stop()` right before release still says goodbye.
        closingFlows[ObjectIdentifier(flow)] = flow
        queue.asyncAfter(deadline: .now() + Self.cancelGracePeriod) { [self, flow] in
            finishCancel(flow)
        }
    }

    private func finishCancel(_ flow: Flow) {
        closingFlows[ObjectIdentifier(flow)] = nil
        guard !flow.isCancelled else { return }
        flow.isCancelled = true
        flow.isCancelling = true
        flow.connection.cancel()
        Self.log.info("\(flow.id, privacy: .public) cancelled")
    }

    private func setAudioRoute(_ route: LinkStateMachine.AudioRoute?, for peer: PeerID) {
        var newRoute: AudioRoute?
        if let route {
            if let flow = flows[route.flow], let sealer = flow.sealer {
                newRoute = AudioRoute(peer: peer, connection: flow.connection, sealer: sealer, linkID: route.linkID)
            } else {
                Self.log.error("audio route to \(peer.rawValue, privacy: .public) names \(route.flow, privacy: .public), which is not keyed")
            }
        }
        audioLock.withLock {
            audioRoutesByPeer[peer] = newRoute
            audioRoutes = Array(audioRoutesByPeer.values)
        }
        if let route, newRoute != nil {
            Self.log.notice("audio to \(peer.rawValue, privacy: .public) on \(route.flow, privacy: .public) link \(route.linkID, privacy: .public)")
        } else {
            Self.log.notice("audio to \(peer.rawValue, privacy: .public) paused (no link)")
        }
    }

    // MARK: - Receiving (queue)

    private func receiveNext(on flow: Flow) {
        guard !flow.isCancelled, !flow.isReceiving else { return }
        flow.isReceiving = true
        flow.connection.receiveMessage { [weak self, weak flow] content, _, _, error in
            guard let self, let flow else { return }
            flow.isReceiving = false
            guard !flow.isCancelled else { return }
            if let content, !content.isEmpty {
                self.received(content, on: flow)
            }
            if let error {
                // UDP surfaces ICMP errors (port unreachable after a peer restart) here. Real failures
                // arrive through the state handler; keep listening while the flow is still ready, and
                // resume on the next `.ready` otherwise.
                flow.receiveErrors += 1
                if flow.receiveErrors == 1 || flow.receiveErrors % 100 == 0 {
                    Self.log.error("\(flow.id, privacy: .public) receive error #\(flow.receiveErrors, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                guard case .ready = flow.connection.state else { return }
                self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self, weak flow] in
                    guard let self, let flow else { return }
                    self.receiveNext(on: flow)
                }
                return
            }
            self.receiveNext(on: flow)
        }
    }

    private func received(_ content: Data, on flow: Flow) {
        guard isCurrent(flow) else { return }
        let datagram: NetDatagram
        do {
            datagram = try NetDatagram.decode(content, opener: flow.sealer)
        } catch let error as NetDatagramError {
            submit(.undecodableDatagram(flow.id, error))
            return
        } catch {
            return
        }
        if case .audio(let packet) = datagram.payload {
            // Audio never goes through the machine, and only a flow keyed by a completed handshake may play it.
            guard datagram.isSealed, flow.sealer != nil, let peer = flow.remotePeer else { return }
            onAudio?(packet, peer)
            return
        }
        submit(.datagram(datagram, on: flow.id))
    }
}
