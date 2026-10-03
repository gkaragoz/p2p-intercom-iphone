import XCTest
@testable import IntercomCore

final class WireRateTests: XCTestCase {
    func testStandardIsTheOriginalWireFormat() {
        XCTAssertEqual(WireRate.standard.sampleRate, Int(IntercomProtocol.sampleRate))
        XCTAssertEqual(WireRate.standard.frameSamples, IntercomProtocol.frameSamples)
        XCTAssertEqual(WireRate.standard.frameBytes, IntercomProtocol.frameBytes)
        XCTAssertEqual(WireRate.standard.codec, .pcm16Mono16k)
        XCTAssertEqual(WireRate.default, .standard, "the default must stay the format every peer understands")
    }

    func testEveryRateKeepsTheTwentyMillisecondFrame() {
        for rate in WireRate.allCases {
            XCTAssertEqual(rate.sampleRate % IntercomProtocol.framesPerSecond, 0,
                           "\(rate): a frame must be a whole number of samples")
            XCTAssertEqual(rate.frameSamples * IntercomProtocol.framesPerSecond, rate.sampleRate,
                           "\(rate): 50 frames make exactly one second")
            XCTAssertEqual(rate.frameBytes, rate.frameSamples * 2, "\(rate): 16-bit samples")
        }
        XCTAssertEqual(WireRate.allCases.map(\.frameSamples), [160, 320, 480, 640])
    }

    func testCodecRoundTrips() {
        for codec in AudioPacket.Codec.allCases {
            let rate = WireRate(codec: codec)
            XCTAssertEqual(rate.codec, codec, "\(codec) must map back to the codec it came from")
            XCTAssertEqual(rate.sampleRate, codec.sampleRate)
            XCTAssertEqual(rate.frameSamples, codec.frameSamples)
        }
        XCTAssertEqual(WireRate.allCases.map(\.codec), [.pcm16Mono8k, .pcm16Mono16k, .pcm16Mono24k, .pcm16Mono32k])
    }

    func testMatchingSampleRate() {
        for rate in WireRate.allCases {
            XCTAssertEqual(WireRate.matching(sampleRate: rate.sampleRate), rate)
        }
        XCTAssertNil(WireRate.matching(sampleRate: 44_100), "only the four wire rates exist")
        XCTAssertNil(WireRate.matching(sampleRate: 0))
    }

    func testLargestFrameFitsOneDatagram() {
        // A datagram stays under 1_400 bytes so it clears a 1_500-byte Ethernet MTU with IP and
        // UDP headers to spare. The audio packet shares that budget with the 14-byte NetDatagram
        // header and the 23 bytes ChaChaPoly sealing adds (7-byte counter + 16-byte tag).
        let datagramBudget = 1_400
        let datagramHeaderBytes = 14
        let aeadOverheadBytes = 23
        let samples = [Int16](repeating: Int16.max, count: WireRate.highest.frameSamples)
        let packet = AudioPacket(sequence: .max, timestamp: .max, codec: WireRate.highest.codec, samples: samples)
        XCTAssertEqual(packet.encodedSize, packet.encoded().count)
        XCTAssertLessThanOrEqual(packet.encodedSize, datagramBudget - datagramHeaderBytes - aeadOverheadBytes,
                                 "a 32 kHz frame must fit one datagram without IP fragmentation")
    }

    func testBitrates() {
        XCTAssertEqual(WireRate.allCases.map(\.kilobitsPerSecond), [128, 256, 384, 512])
    }

    func testIndexFollowsAllCasesOrder() {
        for (index, rate) in WireRate.allCases.enumerated() {
            XCTAssertEqual(rate.index, index, "\(rate) must index per-rate tables in declaration order")
        }
        XCTAssertEqual(WireRate.allCases, [.narrow, .standard, .high, .highest])
    }
}
