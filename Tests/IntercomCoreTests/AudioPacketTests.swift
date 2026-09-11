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
