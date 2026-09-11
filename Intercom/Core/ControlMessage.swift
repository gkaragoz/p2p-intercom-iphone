import Foundation

/// Low-rate signalling exchanged over the reliable channel.
///
/// Encoded as JSON: `{"type":"ping","payload":{"id":1,"sentAtMs":123}}`.
enum ControlMessage: Equatable {
    /// Sent once right after a connection is established.
    case hello(Hello)
    /// Sent whenever the local transmit state changes.
    case talkState(TalkState)
    /// Round-trip probe; the receiver answers with `pong` carrying the same payload.
    case ping(Ping)
    case pong(Ping)
    /// Sent right before an intentional disconnect.
    case bye

    struct Hello: Codable, Equatable {
        var displayName: String
        var appVersion: String
        var protocolVersion: Int
    }

    struct TalkState: Codable, Equatable {
        var isTalking: Bool
        var isMuted: Bool
    }

    struct Ping: Codable, Equatable {
        var id: UInt32
        var sentAtMs: UInt64
    }
}

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum Kind: String, Codable {
        case hello
        case talkState
        case ping
        case pong
        case bye
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello(try container.decode(Hello.self, forKey: .payload))
        case .talkState:
            self = .talkState(try container.decode(TalkState.self, forKey: .payload))
        case .ping:
            self = .ping(try container.decode(Ping.self, forKey: .payload))
        case .pong:
            self = .pong(try container.decode(Ping.self, forKey: .payload))
        case .bye:
            self = .bye
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let payload):
            try container.encode(Kind.hello, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .talkState(let payload):
            try container.encode(Kind.talkState, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .ping(let payload):
            try container.encode(Kind.ping, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .pong(let payload):
            try container.encode(Kind.pong, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .bye:
            try container.encode(Kind.bye, forKey: .type)
        }
    }
}

extension ControlMessage {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(_ data: Data) -> ControlMessage? {
        try? decoder.decode(ControlMessage.self, from: data)
    }
}
