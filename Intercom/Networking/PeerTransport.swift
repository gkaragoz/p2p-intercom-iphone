import Foundation

/// A connection engine between intercoms, as the controller and the audio pipeline see it.
///
/// Two implementations exist and both phones must use the same one:
/// * `NetworkTransport` (default): Bonjour + one UDP flow per peer with the session protocol from
///   Core (`LinkStateMachine`), app-level liveness in about 2 s, AEAD keyed from the pairing code.
/// * `MultipeerTransport` (legacy): Multipeer Connectivity with app-level liveness on top.
///
/// Framework types never leak through this protocol: peers are `PeerID`s, everything that happens is a
/// `TransportEvent`, so the controller, the pipeline and the UI are identical for either engine.
protocol PeerTransport: AnyObject, Sendable {
    var kind: TransportKind { get }
    var localPeerID: PeerID { get }

    /// Delivered in order on the transport's private serial queue. Set before `start()`.
    var onEvent: (@Sendable (TransportEvent) -> Void)? { get set }
    /// Delivered on a network receive context for every audio packet; must be cheap and thread-safe.
    var onAudio: (@Sendable (AudioPacket, PeerID) -> Void)? { get set }

    /// Starts advertising and discovery; connects to compatible peers automatically.
    func start()
    /// Says a best-effort goodbye to connected peers and releases everything. A stopped transport
    /// can be started again, and the peer then treats it as a restarted instance.
    func stop()
    /// Clears a manual disconnect, resets the reconnect backoff and tries to connect right away.
    func connect(to peer: PeerID)
    /// Disconnects every peer on purpose; they are not reconnected automatically until `connect(to:)`.
    func disconnectAll()
    /// Sends one audio frame to every connected peer. Any thread, never blocks, drops without a link.
    func sendAudio(_ packet: AudioPacket)
    /// Delivers a control message reliably (retransmitted until acknowledged) to every connected peer.
    func sendControl(_ message: ControlMessage)
    /// The local talk/mute/mode/audio-paused state the peer shows; sent whenever it changes.
    func updateLocalStatus(_ status: RemoteStatus)
    /// Foreground: fast heartbeats, and a reconnect attempt right away. Background: slower heartbeats.
    func setAppActive(_ active: Bool)
}
