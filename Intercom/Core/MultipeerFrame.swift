import Foundation

/// Everything the Multipeer Connectivity transport sends through `MCSession.send`, one frame per call.
///
/// The first byte tags the frame. Audio (`0xA1`) and controller-level control messages (`0xC1`) keep
/// the `WireMessage` encoding unchanged; the transport adds a few tiny binary frames of its own for
/// the link management that Multipeer Connectivity does badly by itself:
///
///     0xB1 bye     | reason u8
///     0xB2 ping    | status u8 | sequence u32
///     0xB3 pong    | status u8 | sequence u32
///     0xB4 status  | status u8
///
/// `status` uses the same meaning as the Network framework header flags: bit0 talking, bit1 muted,
/// bits2-3 transmit mode (0 unknown, 1 push-to-talk, 2 voice, 3 always on), bit4 audio paused.
/// Pings and pongs carry it too, so a lost `status` frame heals within one ping interval.
enum MultipeerFrame: Equatable {
    case audio(AudioPacket)
    case control(ControlMessage)
    /// Why the sender is leaving; `userDisconnect` asks the receiver not to invite again on its own.
    case bye(ByeReason)
    /// App-level liveness probe (Multipeer Connectivity notices a dead peer only after many seconds).
    case ping(sequence: UInt32, status: RemoteStatus)
    case pong(sequence: UInt32, status: RemoteStatus)
    case status(RemoteStatus)

    static let byeTag: UInt8 = 0xB1
    static let pingTag: UInt8 = 0xB2
    static let pongTag: UInt8 = 0xB3
    static let statusTag: UInt8 = 0xB4

    func encoded() throws -> Data {
        switch self {
        case .audio(let packet):
            return try WireMessage.audio(packet).encoded()
        case .control(let message):
            return try WireMessage.control(message).encoded()
        case .bye(let reason):
            return Data([Self.byeTag, reason.rawValue])
        case .ping(let sequence, let status):
            return Self.probe(tag: Self.pingTag, sequence: sequence, status: status)
        case .pong(let sequence, let status):
            return Self.probe(tag: Self.pongTag, sequence: sequence, status: status)
        case .status(let status):
            return Data([Self.statusTag, Self.statusBits(status)])
        }
    }

    /// Never traps on malformed input; anything unexpected is `nil`.
    static func decode(_ data: Data) -> MultipeerFrame? {
        guard let tag = data.first else { return nil }
        switch tag {
        case WireMessage.audioTag, WireMessage.controlTag:
            switch WireMessage.decode(data) {
            case .audio(let packet)?: return .audio(packet)
            case .control(let message)?: return .control(message)
            case nil: return nil
            }
        case byeTag:
            guard data.count == 2 else { return nil }
            return .bye(ByeReason(wireValue: data[data.startIndex + 1]))
        case pingTag, pongTag:
            guard data.count == 6 else { return nil }
            var reader = ByteReader([UInt8](data.dropFirst()))
            let status = Self.status(fromBits: reader.readUInt8())
            let sequence = reader.readUInt32()
            guard reader.isValid else { return nil }
            return tag == pingTag ? .ping(sequence: sequence, status: status) : .pong(sequence: sequence, status: status)
        case statusTag:
            guard data.count == 2 else { return nil }
            return .status(Self.status(fromBits: data[data.startIndex + 1]))
        default:
            return nil
        }
    }

    private static func probe(tag: UInt8, sequence: UInt32, status: RemoteStatus) -> Data {
        var bytes: [UInt8] = [tag, statusBits(status)]
        bytes.appendLittleEndian(sequence)
        return Data(bytes)
    }

    static func statusBits(_ status: RemoteStatus) -> UInt8 {
        var bits: UInt8 = 0
        if status.isTalking { bits |= 1 << 0 }
        if status.isMuted { bits |= 1 << 1 }
        switch status.mode {
        case nil: break
        case .pushToTalk?: bits |= 1 << 2
        case .voiceActivated?: bits |= 2 << 2
        case .alwaysOn?: bits |= 3 << 2
        }
        if status.isAudioPaused { bits |= 1 << 4 }
        return bits
    }

    static func status(fromBits bits: UInt8) -> RemoteStatus {
        let mode: TransmitMode?
        switch (bits >> 2) & 0b11 {
        case 1: mode = .pushToTalk
        case 2: mode = .voiceActivated
        case 3: mode = .alwaysOn
        default: mode = nil
        }
        return RemoteStatus(isTalking: bits & 1 != 0, isMuted: bits & 2 != 0, mode: mode, isAudioPaused: bits & (1 << 4) != 0)
    }
}

/// The context of a Multipeer Connectivity invitation: the only way to reach a peer without a session.
///
///     0xD1 connect | epoch u32 | token (UTF-8)
///     0xD2 bye     | epoch u32 | token (UTF-8)
///
/// `token` is the sender's install ID (its election token) and `epoch` the random value it drew when
/// its transport started, so the receiver can tell a restarted peer from the instance it knew.
///
/// `connect` asks for a link. `bye` is always declined: a phone whose user pressed Disconnect sends it
/// when it declines an invitation (and once after the Disconnect), so the other phone stops redialling
/// even if the `bye(userDisconnect)` frame on the old session never arrived. A plain decline carries
/// no reason and looks like any failed handshake.
enum MultipeerInvitation: Equatable {
    case connect(token: String, epoch: UInt32)
    case bye(token: String, epoch: UInt32)

    static let connectTag: UInt8 = 0xD1
    static let byeTag: UInt8 = 0xD2

    var token: String {
        switch self {
        case .connect(let token, _), .bye(let token, _): return token
        }
    }

    var epoch: UInt32 {
        switch self {
        case .connect(_, let epoch), .bye(_, let epoch): return epoch
        }
    }

    func encoded() -> Data {
        var bytes: [UInt8]
        switch self {
        case .connect: bytes = [Self.connectTag]
        case .bye: bytes = [Self.byeTag]
        }
        bytes.appendLittleEndian(epoch)
        bytes.append(contentsOf: Array(token.utf8))
        return Data(bytes)
    }

    /// Never traps on malformed input; anything unexpected is `nil`.
    static func decode(_ data: Data) -> MultipeerInvitation? {
        guard let tag = data.first, tag == connectTag || tag == byeTag, data.count >= 5 else { return nil }
        var reader = ByteReader([UInt8](data.dropFirst()))
        let epoch = reader.readUInt32()
        let tokenBytes = reader.readRemainingBytes()
        guard reader.isValid, let token = String(bytes: tokenBytes, encoding: .utf8) else { return nil }
        return tag == connectTag ? .connect(token: token, epoch: epoch) : .bye(token: token, epoch: epoch)
    }
}
