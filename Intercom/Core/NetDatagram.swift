import Foundation

/// Datagram types of the Network framework session protocol.
enum NetDatagramType: UInt8, CaseIterable, Sendable {
    case hello = 1
    case helloAck = 2
    case heartbeat = 3
    case control = 4
    case controlAck = 5
    case audio = 6
    case bye = 7

    /// HELLO and HELLO_ACK are always sent in the clear: they carry the nonces the session keys are
    /// derived from, so neither side could open them yet. They are authenticated with a tag instead.
    var isHandshake: Bool {
        self == .hello || self == .helloAck
    }
}

enum NetDatagramError: Error, Equatable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    /// A handshake datagram claimed to be sealed.
    case sealedHandshake
    /// A sealed datagram arrived on a flow without keys, or sealing was requested without a key.
    case missingKey
    case authenticationFailed
    case malformedPayload(NetDatagramType)
}

/// The fixed 14-byte header in front of every datagram. All integers little-endian.
///
///     0   "I" (0x49)
///     1   "N" (0x4E)
///     2   version (2)
///     3   type (`NetDatagramType`)
///     4   flags: bit0 sealed, bit1 talking, bit2 muted, bits3-4 transmit mode
///         (0 unknown, 1 push-to-talk, 2 voice, 3 always on), bit5 audio paused,
///         bit6 sender in background (slower heartbeats), bit7 reserved
///     5   reserved (sent as 0, ignored)
///     6   link ID (UInt32, 0 until HELLO_ACK assigns one)
///     10  sender epoch (UInt32, random per transport start)
///     14  payload (sealed unless the type is a handshake)
///
/// The magic differs from `AudioPacket`'s "IC", so a datagram can never be mistaken for a bare
/// audio packet from the Multipeer Connectivity wire format.
struct NetDatagramHeader: Equatable, Sendable {
    static let size = 14
    static let magic0: UInt8 = 0x49
    static let magic1: UInt8 = 0x4E

    var type: NetDatagramType
    var isSealed: Bool
    var status: RemoteStatus
    var isSenderInBackground: Bool
    var linkID: UInt32
    var senderEpoch: UInt32

    private enum Flag {
        static let sealed: UInt8 = 1 << 0
        static let talking: UInt8 = 1 << 1
        static let muted: UInt8 = 1 << 2
        static let modeShift: UInt8 = 3
        static let modeMask: UInt8 = 0b11 << 3
        static let audioPaused: UInt8 = 1 << 5
        static let background: UInt8 = 1 << 6
    }

    var flags: UInt8 {
        var value: UInt8 = 0
        if isSealed { value |= Flag.sealed }
        if status.isTalking { value |= Flag.talking }
        if status.isMuted { value |= Flag.muted }
        value |= Self.modeBits(status.mode) << Flag.modeShift
        if status.isAudioPaused { value |= Flag.audioPaused }
        if isSenderInBackground { value |= Flag.background }
        return value
    }

    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.size)
        append(to: &bytes)
        return bytes
    }

    func append(to bytes: inout [UInt8]) {
        bytes.append(Self.magic0)
        bytes.append(Self.magic1)
        bytes.append(IntercomProtocol.Network.wireVersion)
        bytes.append(type.rawValue)
        bytes.append(flags)
        bytes.append(0)
        bytes.appendLittleEndian(linkID)
        bytes.appendLittleEndian(senderEpoch)
    }

    /// Parses the header only; used to pick the flow's sealer and to route audio quickly.
    static func decode(_ bytes: [UInt8]) throws -> NetDatagramHeader {
        guard bytes.count >= size else { throw NetDatagramError.truncated }
        var reader = ByteReader(bytes)
        guard reader.readUInt8() == magic0, reader.readUInt8() == magic1 else { throw NetDatagramError.badMagic }
        let version = reader.readUInt8()
        guard version == IntercomProtocol.Network.wireVersion else { throw NetDatagramError.unsupportedVersion(version) }
        let rawType = reader.readUInt8()
        guard let type = NetDatagramType(rawValue: rawType) else { throw NetDatagramError.unknownType(rawType) }
        let flags = reader.readUInt8()
        _ = reader.readUInt8()
        let linkID = reader.readUInt32()
        let epoch = reader.readUInt32()
        guard reader.isValid else { throw NetDatagramError.truncated }
        let status = RemoteStatus(
            isTalking: flags & Flag.talking != 0,
            isMuted: flags & Flag.muted != 0,
            mode: modeFromBits((flags & Flag.modeMask) >> Flag.modeShift),
            isAudioPaused: flags & Flag.audioPaused != 0
        )
        return NetDatagramHeader(
            type: type,
            isSealed: flags & Flag.sealed != 0,
            status: status,
            isSenderInBackground: flags & Flag.background != 0,
            linkID: linkID,
            senderEpoch: epoch
        )
    }

    private static func modeBits(_ mode: TransmitMode?) -> UInt8 {
        switch mode {
        case nil: return 0
        case .pushToTalk?: return 1
        case .voiceActivated?: return 2
        case .alwaysOn?: return 3
        }
    }

    private static func modeFromBits(_ bits: UInt8) -> TransmitMode? {
        switch bits {
        case 1: return .pushToTalk
        case 2: return .voiceActivated
        case 3: return .alwaysOn
        default: return nil
        }
    }
}

/// The identity and capabilities a peer presents in HELLO (dialer) and HELLO_ACK (listener).
///
/// Payload layout:
///
///     installID (16 raw UUID bytes) | epoch u32 | nonce u32 | protocolVersion u16 |
///     capabilities u32 | dialSequence u32 | nameLength u8 | name UTF-8 |
///     appVersionLength u8 | appVersion UTF-8 | tagLength u8 | authentication tag |
///     extension bytes (ignored; lets later versions append fields)
struct NetHello: Equatable, Sendable {
    static let maxDisplayNameBytes = 255
    static let maxAppVersionBytes = 32
    static let maxAuthenticationTagBytes = 64

    var peerID: PeerID
    var epoch: UInt32
    /// Fresh random value per handshake; echoed in HELLO_ACK and mixed into the session keys.
    var nonce: UInt32
    var protocolVersion: UInt16
    var capabilities: UInt32
    /// Increments with every flow the dialer opens within one epoch. Both phones order duplicate
    /// flows from the same dialer by it, so "newest wins" is decided identically on both. 0 in HELLO_ACK.
    var dialSequence: UInt32
    var displayName: String
    var appVersion: String
    var authenticationTag: [UInt8]

    init(peerID: PeerID, epoch: UInt32, nonce: UInt32,
         protocolVersion: UInt16 = IntercomProtocol.Network.protocolVersion,
         capabilities: UInt32 = 0, dialSequence: UInt32 = 0,
         displayName: String, appVersion: String, authenticationTag: [UInt8] = []) {
        self.peerID = peerID
        self.epoch = epoch
        self.nonce = nonce
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.dialSequence = dialSequence
        self.displayName = displayName
        self.appVersion = appVersion
        self.authenticationTag = authenticationTag
    }

    func append(to bytes: inout [UInt8]) {
        appendFields(to: &bytes)
        let tag = authenticationTag.prefix(Self.maxAuthenticationTagBytes)
        bytes.append(UInt8(tag.count))
        bytes.append(contentsOf: tag)
    }

    /// The bytes the authentication tag covers: a context prefix (role and, for HELLO_ACK, the echoed
    /// nonce and link ID) followed by every field except the tag itself.
    func authenticatedBytes(context: [UInt8]) -> [UInt8] {
        var bytes = context
        appendFields(to: &bytes)
        return bytes
    }

    private func appendFields(to bytes: inout [UInt8]) {
        let uuid = peerID.installID?.uuid ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeBytes(of: uuid) { bytes.append(contentsOf: $0) }
        bytes.appendLittleEndian(epoch)
        bytes.appendLittleEndian(nonce)
        bytes.appendLittleEndian(protocolVersion)
        bytes.appendLittleEndian(capabilities)
        bytes.appendLittleEndian(dialSequence)
        Self.appendString(displayName, maxBytes: Self.maxDisplayNameBytes, to: &bytes)
        Self.appendString(appVersion, maxBytes: Self.maxAppVersionBytes, to: &bytes)
    }

    static func decode(from reader: inout ByteReader) -> NetHello? {
        let uuidBytes = reader.readBytes(16)
        let epoch = reader.readUInt32()
        let nonce = reader.readUInt32()
        let protocolVersion = reader.readUInt16()
        let capabilities = reader.readUInt32()
        let dialSequence = reader.readUInt32()
        guard reader.isValid,
              let displayName = readString(from: &reader, maxBytes: maxDisplayNameBytes),
              let appVersion = readString(from: &reader, maxBytes: maxAppVersionBytes) else { return nil }
        let tagLength = Int(reader.readUInt8())
        guard reader.isValid, tagLength <= maxAuthenticationTagBytes else { return nil }
        let tag = reader.readBytes(tagLength)
        guard reader.isValid else { return nil }
        let b = uuidBytes
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return NetHello(
            peerID: PeerID(installID: uuid),
            epoch: epoch,
            nonce: nonce,
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            dialSequence: dialSequence,
            displayName: displayName,
            appVersion: appVersion,
            authenticationTag: tag
        )
    }

    /// Appends a u8 length and at most `maxBytes` of UTF-8, cut at a character boundary.
    private static func appendString(_ string: String, maxBytes: Int, to bytes: inout [UInt8]) {
        var value = string
        while value.utf8.count > maxBytes {
            value.removeLast()
        }
        let utf8 = Array(value.utf8)
        bytes.append(UInt8(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    private static func readString(from reader: inout ByteReader, maxBytes: Int) -> String? {
        let length = Int(reader.readUInt8())
        guard reader.isValid, length <= maxBytes else { return nil }
        let raw = reader.readBytes(length)
        guard reader.isValid else { return nil }
        // Round-trip check instead of `String(bytes:encoding:)`, whose handling of invalid UTF-8
        // differs between Foundation implementations (Core also runs on Linux).
        let string = String(decoding: raw, as: UTF8.self)
        return Array(string.utf8) == raw ? string : nil
    }
}

/// The listener's answer to HELLO: `echoNonce u32 | linkID u32 | responder NetHello`.
struct NetHelloAck: Equatable, Sendable {
    var echoNonce: UInt32
    var linkID: UInt32
    var responder: NetHello

    /// The bytes the responder's authentication tag covers; binds it to the dialer's nonce.
    var authenticatedBytes: [UInt8] {
        var context: [UInt8] = [0x41] // "A"
        context.appendLittleEndian(echoNonce)
        context.appendLittleEndian(linkID)
        return responder.authenticatedBytes(context: context)
    }
}

extension NetHello {
    /// The bytes a dialer's HELLO tag covers.
    var helloAuthenticatedBytes: [UInt8] {
        authenticatedBytes(context: [0x48]) // "H"
    }
}

/// Liveness probe that also measures round-trip time without a separate ping/pong:
/// `sequence u32 | sentMs u32 | echoSequence u32 | echoDelayMs u16`.
///
/// `echoSequence` is the newest heartbeat received from the other side (0 for none) and
/// `echoDelayMs` how long ago it arrived, so the receiver computes RTT = now − sent − delay.
struct NetHeartbeat: Equatable, Sendable {
    static let size = 14

    var sequence: UInt32
    /// Sender's monotonic milliseconds, truncated. Informational (clocks differ per phone).
    var sentMs: UInt32
    var echoSequence: UInt32
    var echoDelayMs: UInt16
}

enum NetPayload: Equatable, Sendable {
    case hello(NetHello)
    case helloAck(NetHelloAck)
    case heartbeat(NetHeartbeat)
    /// Reliable control message: retransmitted until `controlAck` with the same sequence arrives.
    case control(sequence: UInt32, message: ControlMessage)
    case controlAck(sequence: UInt32)
    /// The existing `AudioPacket` encoding, unchanged.
    case audio(AudioPacket)
    case bye(ByeReason)

    var type: NetDatagramType {
        switch self {
        case .hello: return .hello
        case .helloAck: return .helloAck
        case .heartbeat: return .heartbeat
        case .control: return .control
        case .controlAck: return .controlAck
        case .audio: return .audio
        case .bye: return .bye
        }
    }

    func append(to bytes: inout [UInt8]) throws {
        switch self {
        case .hello(let hello):
            hello.append(to: &bytes)
        case .helloAck(let ack):
            bytes.appendLittleEndian(ack.echoNonce)
            bytes.appendLittleEndian(ack.linkID)
            ack.responder.append(to: &bytes)
        case .heartbeat(let beat):
            bytes.appendLittleEndian(beat.sequence)
            bytes.appendLittleEndian(beat.sentMs)
            bytes.appendLittleEndian(beat.echoSequence)
            bytes.appendLittleEndian(beat.echoDelayMs)
        case .control(let sequence, let message):
            bytes.appendLittleEndian(sequence)
            bytes.append(contentsOf: try message.encoded())
        case .controlAck(let sequence):
            bytes.appendLittleEndian(sequence)
        case .audio(let packet):
            packet.append(to: &bytes)
        case .bye(let reason):
            bytes.append(reason.rawValue)
        }
    }

    static func decode(type: NetDatagramType, bytes: [UInt8]) throws -> NetPayload {
        var reader = ByteReader(bytes)
        let malformed = NetDatagramError.malformedPayload(type)
        switch type {
        case .hello:
            guard let hello = NetHello.decode(from: &reader) else { throw malformed }
            return .hello(hello)
        case .helloAck:
            let echoNonce = reader.readUInt32()
            let linkID = reader.readUInt32()
            guard reader.isValid, let responder = NetHello.decode(from: &reader) else { throw malformed }
            return .helloAck(NetHelloAck(echoNonce: echoNonce, linkID: linkID, responder: responder))
        case .heartbeat:
            guard bytes.count == NetHeartbeat.size else { throw malformed }
            return .heartbeat(NetHeartbeat(
                sequence: reader.readUInt32(),
                sentMs: reader.readUInt32(),
                echoSequence: reader.readUInt32(),
                echoDelayMs: reader.readUInt16()
            ))
        case .control:
            let sequence = reader.readUInt32()
            let json = reader.readRemainingBytes()
            guard reader.isValid, !json.isEmpty, let message = ControlMessage.decode(Data(json)) else { throw malformed }
            return .control(sequence: sequence, message: message)
        case .controlAck:
            guard bytes.count == 4 else { throw malformed }
            return .controlAck(sequence: reader.readUInt32())
        case .audio:
            guard let packet = AudioPacket.decode(bytes: bytes) else { throw malformed }
            return .audio(packet)
        case .bye:
            guard bytes.count == 1 else { throw malformed }
            return .bye(ByeReason(wireValue: bytes[0]))
        }
    }
}

/// One datagram of the Network framework session protocol: header fields plus a typed payload.
///
/// Audio and control share one UDP flow per peer. The talking/muted/mode bits ride in every
/// header, so the peer's status is refreshed by each heartbeat without reliable delivery.
struct NetDatagram: Equatable, Sendable {
    var linkID: UInt32
    var senderEpoch: UInt32
    var status: RemoteStatus
    var isSenderInBackground: Bool
    var payload: NetPayload
    /// Set by `decode` from the header flag; ignored by `encoded`, which seals whenever it is given
    /// a sealer and the payload is not a handshake.
    var isSealed: Bool

    init(linkID: UInt32, senderEpoch: UInt32, status: RemoteStatus = RemoteStatus(),
         isSenderInBackground: Bool = false, payload: NetPayload, isSealed: Bool = false) {
        self.linkID = linkID
        self.senderEpoch = senderEpoch
        self.status = status
        self.isSenderInBackground = isSenderInBackground
        self.payload = payload
        self.isSealed = isSealed
    }

    var type: NetDatagramType { payload.type }

    /// Encodes the datagram. Non-handshake payloads are sealed with `sealer` (header as AAD) when
    /// one is given; handshake payloads are always sent in the clear.
    func encoded(sealer: PacketSealer?) throws -> Data {
        let seal = sealer != nil && !type.isHandshake
        let header = NetDatagramHeader(
            type: type,
            isSealed: seal,
            status: status,
            isSenderInBackground: isSenderInBackground,
            linkID: linkID,
            senderEpoch: senderEpoch
        )
        var bytes = [UInt8]()
        bytes.reserveCapacity(NetDatagramHeader.size + Self.estimatedPayloadSize(payload))
        header.append(to: &bytes)
        guard seal, let sealer else {
            try payload.append(to: &bytes)
            return Data(bytes)
        }
        var body = [UInt8]()
        body.reserveCapacity(Self.estimatedPayloadSize(payload))
        try payload.append(to: &body)
        guard let sealed = sealer.seal(body, header: bytes) else { throw NetDatagramError.missingKey }
        bytes.append(contentsOf: sealed)
        return Data(bytes)
    }

    /// Decodes a datagram, opening sealed payloads with `opener` (the flow's sealer, if bound).
    /// Never traps on malformed input; every failure is a `NetDatagramError`.
    static func decode(_ data: Data, opener: PacketSealer?) throws -> NetDatagram {
        let bytes = [UInt8](data)
        let header = try NetDatagramHeader.decode(bytes)
        var body = Array(bytes[NetDatagramHeader.size...])
        if header.isSealed {
            guard !header.type.isHandshake else { throw NetDatagramError.sealedHandshake }
            guard let opener else { throw NetDatagramError.missingKey }
            guard let opened = opener.open(body, header: Array(bytes[0..<NetDatagramHeader.size])) else {
                throw NetDatagramError.authenticationFailed
            }
            body = opened
        }
        let payload = try NetPayload.decode(type: header.type, bytes: body)
        return NetDatagram(
            linkID: header.linkID,
            senderEpoch: header.senderEpoch,
            status: header.status,
            isSenderInBackground: header.isSenderInBackground,
            payload: payload,
            isSealed: header.isSealed
        )
    }

    private static func estimatedPayloadSize(_ payload: NetPayload) -> Int {
        switch payload {
        case .audio(let packet): return packet.encodedSize
        case .hello, .helloAck: return 128
        case .control: return 128
        default: return 16
        }
    }
}
