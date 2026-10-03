import XCTest
@testable import IntercomCore

final class AudioPacketTests: XCTestCase {
    func testRoundTrip() {
        let samples: [Int16] = (0..<IntercomProtocol.frameSamples).map { Int16(truncatingIfNeeded: $0 * 97 - 16_000) }
        let packet = AudioPacket(sequence: 0xBEEF, timestamp: 0xDEAD_BEEF, samples: samples)
        let data = packet.encoded()
        XCTAssertEqual(data.count, AudioPacket.headerSize + samples.count * 2)
        XCTAssertEqual(AudioPacket.decode(data), packet)
    }

    func testHeaderLayoutIsLittleEndian() {
        let packet = AudioPacket(sequence: 0x0102, timestamp: 0x0A0B_0C0D, samples: [Int16.min, -1, 0, 1, Int16.max])
        let bytes = [UInt8](packet.encoded())
        XCTAssertEqual(Array(bytes[0..<4]), [0x49, 0x43, 1, 1])
        XCTAssertEqual(Array(bytes[4..<6]), [0x02, 0x01])
        XCTAssertEqual(Array(bytes[6..<10]), [0x0D, 0x0C, 0x0B, 0x0A])
        XCTAssertEqual(Array(bytes[10..<12]), [5, 0])
        XCTAssertEqual(Array(bytes[12..<22]), [0x00, 0x80, 0xFF, 0xFF, 0x00, 0x00, 0x01, 0x00, 0xFF, 0x7F])

        let wide = AudioPacket(sequence: 1, timestamp: 2, codec: .pcm16Mono32k,
                               samples: [Int16](repeating: 0, count: WireRate.highest.frameSamples))
        let wideBytes = [UInt8](wide.encoded())
        XCTAssertEqual(wideBytes[3], 4, "the codec byte says 32 kHz")
        XCTAssertEqual(Array(wideBytes[10..<12]), [0x80, 0x02], "640 samples, little-endian")
        XCTAssertEqual(wideBytes.count, AudioPacket.headerSize + 640 * 2)
    }

    func testEveryCodecRoundTripsAFullFrame() {
        for codec in AudioPacket.Codec.allCases {
            let samples: [Int16] = (0..<codec.frameSamples).map { Int16(truncatingIfNeeded: $0 * 53 - 12_000) }
            let packet = AudioPacket(sequence: 42, timestamp: 4_242, codec: codec, samples: samples)
            let decoded = AudioPacket.decode(packet.encoded())
            XCTAssertEqual(decoded, packet, "\(codec) must survive encode/decode")
            XCTAssertEqual(decoded?.codec, codec)
            XCTAssertEqual(decoded?.samples.count, codec.frameSamples, "\(codec): 20 ms of samples")
        }
    }

    func testEmptyPayloadRoundTrips() {
        let packet = AudioPacket(sequence: 1, timestamp: 2, samples: [])
        XCTAssertEqual(AudioPacket.decode(packet.encoded()), packet)
    }

    func testRejectsTruncatedData() {
        let packet = AudioPacket(sequence: 1, timestamp: 2, samples: [1, 2, 3])
        let data = packet.encoded()
        XCTAssertNil(AudioPacket.decode(data.prefix(AudioPacket.headerSize - 1)))
        XCTAssertNil(AudioPacket.decode(data.prefix(data.count - 1)))
        XCTAssertNil(AudioPacket.decode(data + Data([0])))
        XCTAssertNil(AudioPacket.decode(Data()))
    }

    func testRejectsBadMagicVersionAndCodec() {
        let packet = AudioPacket(sequence: 1, timestamp: 2, samples: [1])
        var bytes = [UInt8](packet.encoded())
        bytes[0] = 0x00
        XCTAssertNil(AudioPacket.decode(Data(bytes)))
        bytes = [UInt8](packet.encoded())
        bytes[2] = 99
        XCTAssertNil(AudioPacket.decode(Data(bytes)))
        bytes = [UInt8](packet.encoded())
        bytes[3] = 0
        XCTAssertNil(AudioPacket.decode(Data(bytes)))
    }

    func testRejectsUnknownCodecBytes() {
        let packet = AudioPacket(sequence: 1, timestamp: 2, samples: [1])
        for byte: UInt8 in [0, 5, 0xFF] {
            var bytes = [UInt8](packet.encoded())
            bytes[3] = byte
            XCTAssertNil(AudioPacket.decode(Data(bytes)), "codec byte \(byte) is not a known codec")
        }
        for codec in AudioPacket.Codec.allCases {
            var bytes = [UInt8](packet.encoded())
            bytes[3] = codec.rawValue
            XCTAssertEqual(AudioPacket.decode(Data(bytes))?.codec, codec, "codec bytes 1-4 are all accepted")
        }
    }

    func testRejectsAbsurdSampleCounts() {
        var bytes: [UInt8] = [0x49, 0x43, 1, 1, 0, 0, 0, 0, 0, 0]
        bytes.appendLittleEndian(UInt16(AudioPacket.maxSamples + 1))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: (AudioPacket.maxSamples + 1) * 2))
        XCTAssertNil(AudioPacket.decode(Data(bytes)))
    }

    func testDecodeWorksOnDataSlices() {
        let packet = AudioPacket(sequence: 7, timestamp: 8, samples: [9, 10])
        var data = Data([0xFF, 0xFE])
        data.append(packet.encoded())
        let slice = data.dropFirst(2)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(AudioPacket.decode(slice), packet)
    }
}
