import Foundation

/// Envelope for everything that goes through `MCSession.send`.
///
/// The first byte tags the payload so audio (sent unreliably, very frequently) and control
/// messages (sent reliably, rarely) can share one delegate callback.
enum WireMessage: Equatable {
    case audio(AudioPacket)
    case control(ControlMessage)

    static let audioTag: UInt8 = 0xA1
    static let controlTag: UInt8 = 0xC1

    func encoded() throws -> Data {
        switch self {
        case .audio(let packet):
            var data = Data(capacity: packet.encodedSize + 1)
            data.append(Self.audioTag)
            data.append(packet.encoded())
            return data
        case .control(let message):
            var data = Data([Self.controlTag])
            data.append(try message.encoded())
            return data
        }
    }

    static func decode(_ data: Data) -> WireMessage? {
        guard let tag = data.first else { return nil }
        // `dropFirst` yields a slice whose indices do not start at zero; re-wrap it so every
        // downstream decoder can rely on zero-based indexing.
        let payload = Data(data.dropFirst())
        switch tag {
        case audioTag:
            return AudioPacket.decode(payload).map(WireMessage.audio)
        case controlTag:
            return ControlMessage.decode(payload).map(WireMessage.control)
        default:
            return nil
        }
    }
}
