import XCTest
@testable import IntercomCore

final class WireMessageTests: XCTestCase {
    func testAudioRoundTrip() throws {
        let packet = AudioPacket(sequence: 3, timestamp: 960, samples: [1, -1, 32_767, -32_768])
        let data = try WireMessage.audio(packet).encoded()
        XCTAssertEqual(data.first, WireMessage.audioTag)
        XCTAssertEqual(WireMessage.decode(data), .audio(packet))
    }

    func testControlRoundTrips() throws {
        let messages: [ControlMessage] = [
            .hello(.init(displayName: "Gökhan's iPhone", appVersion: "1.0", protocolVersion: 1)),
            .talkState(.init(isTalking: true, isMuted: false)),
            .ping(.init(id: 42, sentAtMs: 1_700_000_000_123)),
            .pong(.init(id: 42, sentAtMs: 1_700_000_000_123)),
            .bye,
        ]
        for message in messages {
            let data = try WireMessage.control(message).encoded()
            XCTAssertEqual(data.first, WireMessage.controlTag)
            XCTAssertEqual(WireMessage.decode(data), .control(message), "\(message)")
        }
    }

    func testRejectsGarbage() {
        XCTAssertNil(WireMessage.decode(Data()))
        XCTAssertNil(WireMessage.decode(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(WireMessage.decode(Data([WireMessage.audioTag])))
        XCTAssertNil(WireMessage.decode(Data([WireMessage.controlTag]) + Data("not json".utf8)))
    }

    func testControlJSONIsStable() throws {
        let data = try ControlMessage.talkState(.init(isTalking: true, isMuted: false)).encoded()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"payload":{"isMuted":false,"isTalking":true},"type":"talkState"}"#)
    }
}
