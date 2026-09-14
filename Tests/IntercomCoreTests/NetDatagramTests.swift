import XCTest
@testable import IntercomCore

/// Test sealer: XORs the payload and appends a checksum over header and plaintext, so tampering
/// with either (the header is AAD) or opening without the right sealer fails.
private final class ChecksumSealer: PacketSealer {
    let key: UInt8
    init(key: UInt8) { self.key = key }

    func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8]? {
        payload.map { $0 ^ key } + [checksum(header + payload)]
    }

    func open(_ sealed: [UInt8], header: [UInt8]) -> [UInt8]? {
        guard let tag = sealed.last else { return nil }
        let payload = sealed.dropLast().map { $0 ^ key }
        return checksum(header + payload) == tag ? payload : nil
    }

    private func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(key) { ($0 &* 33) &+ $1 }
    }
}

private final class RefusingSealer: PacketSealer {
    func seal(_ payload: [UInt8], header: [UInt8]) -> [UInt8]? { nil }
    func open(_ sealed: [UInt8], header: [UInt8]) -> [UInt8]? { nil }
}

final class NetDatagramTests: XCTestCase {
    private let peer = PeerID(installID: UUID(uuidString: "12345678-9ABC-DEF0-1122-334455667788")!)

    private func hello(tag: [UInt8] = [1, 2, 3]) -> NetHello {
        NetHello(peerID: peer, epoch: 0xDEAD_BEEF, nonce: 42, protocolVersion: 2, capabilities: 0x0102_0304,
                 dialSequence: 7, displayName: "Gökhan's iPhone", appVersion: "1.0 (3)", authenticationTag: tag)
    }

    private var allPayloads: [NetPayload] {
        [
            .hello(hello()),
            .helloAck(NetHelloAck(echoNonce: 42, linkID: 0x0A0B_0C0D, responder: hello(tag: []))),
            .heartbeat(NetHeartbeat(sequence: 1, sentMs: 0xFFFF_FFFF, echoSequence: 9, echoDelayMs: 65_535)),
            .control(sequence: 5, message: .talkState(.init(isTalking: true, isMuted: true))),
            .controlAck(sequence: 0xFFFF_FFFF),
            .audio(AudioPacket(sequence: 3, timestamp: 960, samples: (0..<320).map { Int16(truncatingIfNeeded: $0 * 101) })),
            .bye(.authenticationFailed),
        ]
    }

    func testEveryPayloadRoundTripsPlainAndSealed() throws {
        let status = RemoteStatus(isTalking: true, isMuted: false, mode: .voiceActivated, isAudioPaused: true)
        for payload in allPayloads {
            let datagram = NetDatagram(linkID: 77, senderEpoch: 88, status: status, isSenderInBackground: true, payload: payload)
            let plain = try NetDatagram.decode(try datagram.encoded(sealer: nil), opener: nil)
            XCTAssertEqual(plain, datagram, "\(payload.type)")

            let sealer = ChecksumSealer(key: 0x5C)
            let data = try datagram.encoded(sealer: sealer)
            let opened = try NetDatagram.decode(data, opener: sealer)
            var expected = datagram
            expected.isSealed = !payload.type.isHandshake
            XCTAssertEqual(opened, expected, "\(payload.type)")
        }
    }

    func testHeaderLayoutIsLittleEndian() throws {
        let datagram = NetDatagram(linkID: 0x0102_0304, senderEpoch: 0x0A0B_0C0D,
                                   status: RemoteStatus(isTalking: true, isMuted: true, mode: .alwaysOn),
                                   payload: .bye(.stopped))
        let bytes = [UInt8](try datagram.encoded(sealer: nil))
        XCTAssertEqual(bytes.count, NetDatagramHeader.size + 1)
        XCTAssertEqual(Array(bytes[0..<4]), [0x49, 0x4E, 2, NetDatagramType.bye.rawValue])
        XCTAssertEqual(bytes[4], 0b0001_1110) // talking, muted, mode 3
        XCTAssertEqual(bytes[5], 0)
        XCTAssertEqual(Array(bytes[6..<10]), [0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(Array(bytes[10..<14]), [0x0D, 0x0C, 0x0B, 0x0A])
        XCTAssertEqual(bytes[14], 0)
    }

    func testFlagBitsForEveryModeAndFlag() throws {
        let modes: [TransmitMode?] = [nil, .pushToTalk, .voiceActivated, .alwaysOn]
        for mode in modes {
            for bits in 0..<16 {
                let status = RemoteStatus(isTalking: bits & 1 != 0, isMuted: bits & 2 != 0, mode: mode, isAudioPaused: bits & 4 != 0)
                let datagram = NetDatagram(linkID: 1, senderEpoch: 1, status: status, isSenderInBackground: bits & 8 != 0,
                                           payload: .controlAck(sequence: 1))
                let header = try NetDatagramHeader.decode([UInt8](try datagram.encoded(sealer: nil)))
                XCTAssertEqual(header.status, status)
                XCTAssertEqual(header.isSenderInBackground, bits & 8 != 0)
                XCTAssertFalse(header.isSealed)
            }
        }
    }

    func testHeartbeatHasFixedSize() throws {
        let datagram = NetDatagram(linkID: 1, senderEpoch: 2, payload: .heartbeat(.init(sequence: 1, sentMs: 2, echoSequence: 3, echoDelayMs: 4)))
        XCTAssertEqual(try datagram.encoded(sealer: nil).count, NetDatagramHeader.size + NetHeartbeat.size)
    }

    func testAudioPayloadIsTheExistingPacketEncoding() throws {
        let packet = AudioPacket(sequence: 0xBEEF, timestamp: 1234, samples: [1, -1, 300])
        let data = try NetDatagram(linkID: 1, senderEpoch: 2, payload: .audio(packet)).encoded(sealer: nil)
        XCTAssertEqual(Data(data.dropFirst(NetDatagramHeader.size)), packet.encoded())
    }

    func testHandshakesAreNeverSealed() throws {
        let sealer = ChecksumSealer(key: 1)
        for payload in [NetPayload.hello(hello()), .helloAck(.init(echoNonce: 1, linkID: 2, responder: hello()))] {
            let data = try NetDatagram(linkID: 0, senderEpoch: 1, payload: payload).encoded(sealer: sealer)
            let header = try NetDatagramHeader.decode([UInt8](data))
            XCTAssertFalse(header.isSealed)
            XCTAssertEqual(try NetDatagram.decode(data, opener: nil).payload, payload)
        }
    }

    func testSealedHeaderTamperingIsDetected() throws {
        let sealer = ChecksumSealer(key: 9)
        let datagram = NetDatagram(linkID: 5, senderEpoch: 6, payload: .controlAck(sequence: 1))
        var bytes = [UInt8](try datagram.encoded(sealer: sealer))
        bytes[4] ^= 0b10 // flip "talking"
        XCTAssertThrowsError(try NetDatagram.decode(Data(bytes), opener: sealer)) {
            XCTAssertEqual($0 as? NetDatagramError, .authenticationFailed)
        }
        bytes = [UInt8](try datagram.encoded(sealer: sealer))
        bytes[6] ^= 1 // link ID
        XCTAssertThrowsError(try NetDatagram.decode(Data(bytes), opener: sealer))
        let good = try datagram.encoded(sealer: sealer)
        XCTAssertThrowsError(try NetDatagram.decode(good, opener: ChecksumSealer(key: 10)))
        XCTAssertThrowsError(try NetDatagram.decode(good, opener: nil)) {
            XCTAssertEqual($0 as? NetDatagramError, .missingKey)
        }
    }

    func testSealerThatCannotSealThrows() {
        let datagram = NetDatagram(linkID: 5, senderEpoch: 6, payload: .controlAck(sequence: 1))
        XCTAssertThrowsError(try datagram.encoded(sealer: RefusingSealer())) {
            XCTAssertEqual($0 as? NetDatagramError, .missingKey)
        }
    }

    func testPlaintextSealerPassesThrough() throws {
        let sealer = PlaintextSealer()
        let datagram = NetDatagram(linkID: 5, senderEpoch: 6, payload: .bye(.duplicate))
        let decoded = try NetDatagram.decode(try datagram.encoded(sealer: sealer), opener: sealer)
        XCTAssertTrue(decoded.isSealed)
        XCTAssertEqual(decoded.payload, .bye(.duplicate))
    }

    // MARK: - Malformed input

    private func assertThrows(_ bytes: [UInt8], _ expected: NetDatagramError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try NetDatagram.decode(Data(bytes), opener: nil), file: file, line: line) {
            XCTAssertEqual($0 as? NetDatagramError, expected, file: file, line: line)
        }
    }

    func testRejectsBadHeaders() throws {
        let valid = [UInt8](try NetDatagram(linkID: 1, senderEpoch: 2, payload: .bye(.stopped)).encoded(sealer: nil))
        assertThrows([], .truncated)
        assertThrows(Array(valid.prefix(13)), .truncated)
        var bytes = valid
        bytes[1] = 0x43 // "IC": a bare AudioPacket
        assertThrows(bytes, .badMagic)
        bytes = valid
        bytes[2] = 3
        assertThrows(bytes, .unsupportedVersion(3))
        bytes = valid
        bytes[3] = 0
        assertThrows(bytes, .unknownType(0))
        bytes[3] = 8
        assertThrows(bytes, .unknownType(8))
        bytes = [UInt8](try NetDatagram(linkID: 0, senderEpoch: 2, payload: .hello(hello())).encoded(sealer: nil))
        bytes[4] |= 1
        assertThrows(bytes, .sealedHandshake)
    }

    func testRejectsWrongPayloadSizes() throws {
        for payload in allPayloads {
            let bytes = [UInt8](try NetDatagram(linkID: 1, senderEpoch: 2, payload: payload).encoded(sealer: nil))
            let type = payload.type
            // Every truncation must be rejected (no payload has an optional tail except handshake extensions).
            for length in NetDatagramHeader.size..<bytes.count {
                assertThrows(Array(bytes.prefix(length)), .malformedPayload(type))
            }
            if !type.isHandshake {
                assertThrows(bytes + [0], .malformedPayload(type))
            }
        }
    }

    func testHandshakesTolerateExtensionBytes() throws {
        let datagram = NetDatagram(linkID: 0, senderEpoch: 1, payload: .hello(hello()))
        let bytes = [UInt8](try datagram.encoded(sealer: nil)) + [9, 9, 9]
        XCTAssertEqual(try NetDatagram.decode(Data(bytes), opener: nil).payload, datagram.payload)
    }

    func testRejectsInvalidStringsAndOversizedTags() throws {
        var bytes = [UInt8](try NetDatagram(linkID: 0, senderEpoch: 1, payload: .hello(hello(tag: []))).encoded(sealer: nil))
        let nameOffset = NetDatagramHeader.size + 16 + 4 + 4 + 2 + 4 + 4
        bytes[nameOffset + 1] = 0xFF // invalid UTF-8
        assertThrows(bytes, .malformedPayload(.hello))

        var tagged = hello(tag: [])
        tagged.authenticationTag = []
        var raw = [UInt8](try NetDatagram(linkID: 0, senderEpoch: 1, payload: .hello(tagged)).encoded(sealer: nil))
        raw[raw.count - 1] = UInt8(NetHello.maxAuthenticationTagBytes + 1)
        raw += [UInt8](repeating: 0, count: NetHello.maxAuthenticationTagBytes + 1)
        assertThrows(raw, .malformedPayload(.hello))
    }

    func testRejectsEmptyOrInvalidControlJSON() throws {
        var header = [UInt8](try NetDatagram(linkID: 1, senderEpoch: 2, payload: .controlAck(sequence: 1)).encoded(sealer: nil).prefix(14))
        header[3] = NetDatagramType.control.rawValue
        assertThrows(header + [1, 0, 0, 0], .malformedPayload(.control))
        assertThrows(header + [1, 0, 0, 0] + Array("{\"type\":\"nope\"}".utf8), .malformedPayload(.control))
    }

    func testUnknownByeReasonDecodesAsOther() throws {
        var bytes = [UInt8](try NetDatagram(linkID: 1, senderEpoch: 2, payload: .bye(.stopped)).encoded(sealer: nil))
        bytes[14] = 200
        XCTAssertEqual(try NetDatagram.decode(Data(bytes), opener: nil).payload, .bye(.other))
    }

    func testLongNamesAreTruncatedAtCharacterBoundary() throws {
        var long = hello()
        long.displayName = String(repeating: "ğ", count: 200) // 2 bytes each
        long.appVersion = String(repeating: "9", count: 100)
        let decoded = try NetDatagram.decode(try NetDatagram(linkID: 0, senderEpoch: 1, payload: .hello(long)).encoded(sealer: nil), opener: nil)
        guard case .hello(let result) = decoded.payload else { return XCTFail() }
        XCTAssertEqual(result.displayName, String(repeating: "ğ", count: 127))
        XCTAssertEqual(result.appVersion.count, NetHello.maxAppVersionBytes)
    }

    func testRandomAndMutatedInputNeverCrashes() throws {
        var rng = SplitMix64(seed: 2024)
        let sealer = ChecksumSealer(key: 3)
        let valid = try allPayloads.map { [UInt8](try NetDatagram(linkID: 1, senderEpoch: 2, payload: $0).encoded(sealer: sealer)) }
        for iteration in 0..<20_000 {
            var bytes: [UInt8]
            if iteration % 2 == 0 {
                bytes = (0..<Int(rng.next() % 80)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
                if bytes.count >= 4, iteration % 4 == 0 {
                    bytes[0] = 0x49; bytes[1] = 0x4E; bytes[2] = 2; bytes[3] = UInt8(1 + rng.next() % 7)
                }
            } else {
                bytes = valid[Int(rng.next() % UInt64(valid.count))]
                for _ in 0..<(1 + rng.next() % 4) where !bytes.isEmpty {
                    bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
                }
                if rng.next() % 3 == 0 { bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count + 1)))) }
            }
            _ = try? NetDatagram.decode(Data(bytes), opener: iteration % 3 == 0 ? nil : sealer)
        }
    }

    func testHelloAuthenticationCoversFieldsButNotTag() {
        let base = hello(tag: [1])
        var other = base
        other.authenticationTag = [2]
        XCTAssertEqual(base.helloAuthenticatedBytes, other.helloAuthenticatedBytes)
        other.nonce += 1
        XCTAssertNotEqual(base.helloAuthenticatedBytes, other.helloAuthenticatedBytes)
        let ack = NetHelloAck(echoNonce: 1, linkID: 2, responder: base)
        var ack2 = ack
        ack2.echoNonce = 3
        XCTAssertNotEqual(ack.authenticatedBytes, ack2.authenticatedBytes)
        XCTAssertNotEqual(ack.authenticatedBytes, base.helloAuthenticatedBytes, "HELLO and HELLO_ACK tags are domain-separated")
    }
}
