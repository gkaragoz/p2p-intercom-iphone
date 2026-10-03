import Foundation

/// One frame of audio as it travels over the network.
///
/// Layout (all integers little-endian):
///
///     0   "I" (0x49)
///     1   "C" (0x43)
///     2   version
///     3   codec
///     4   sequence (UInt16)
///     6   timestamp (UInt32, sample clock of the first sample in this packet)
///     10  sample count (UInt16)
///     12  samples (Int16 × count)
struct AudioPacket: Equatable {
    /// Uncompressed mono 16-bit PCM at one of the `WireRate`s; the byte says which. Every codec
    /// carries 20 ms per packet, so the sample count follows from the rate.
    enum Codec: UInt8, CaseIterable, Sendable {
        /// 16 kHz: the original wire format, understood by every version.
        case pcm16Mono16k = 1
        /// 8 kHz. This and the following codecs need `IntercomProtocol.Network.Capability.multiRateAudio`.
        case pcm16Mono8k = 2
        /// 24 kHz.
        case pcm16Mono24k = 3
        /// 32 kHz.
        case pcm16Mono32k = 4

        var sampleRate: Int {
            switch self {
            case .pcm16Mono8k: return 8_000
            case .pcm16Mono16k: return 16_000
            case .pcm16Mono24k: return 24_000
            case .pcm16Mono32k: return 32_000
            }
        }

        /// Samples in one 20 ms frame at this codec's rate.
        var frameSamples: Int { sampleRate / IntercomProtocol.framesPerSecond }
    }

    static let magic0: UInt8 = 0x49
    static let magic1: UInt8 = 0x43
    static let version: UInt8 = 1
    static let headerSize = 12
    /// Upper bound that keeps a corrupt header from allocating huge buffers.
    static let maxSamples = 4096

    var sequence: UInt16
    var timestamp: UInt32
    var codec: Codec
    var samples: [Int16]

    init(sequence: UInt16, timestamp: UInt32, codec: Codec = .pcm16Mono16k, samples: [Int16]) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.codec = codec
        self.samples = samples
    }

    var encodedSize: Int { Self.headerSize + samples.count * MemoryLayout<Int16>.size }

    func encoded() -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(encodedSize)
        append(to: &bytes)
        return Data(bytes)
    }

    /// Appends the encoding to `bytes`, so a container format (the network datagram) can build
    /// its whole payload in one buffer instead of concatenating copies.
    func append(to bytes: inout [UInt8]) {
        bytes.append(Self.magic0)
        bytes.append(Self.magic1)
        bytes.append(Self.version)
        bytes.append(codec.rawValue)
        bytes.appendLittleEndian(sequence)
        bytes.appendLittleEndian(timestamp)
        bytes.appendLittleEndian(UInt16(truncatingIfNeeded: samples.count))
        for sample in samples {
            bytes.appendLittleEndian(UInt16(bitPattern: sample))
        }
    }

    static func decode(_ data: Data) -> AudioPacket? {
        guard data.count >= headerSize else { return nil }
        return decode(bytes: [UInt8](data))
    }

    static func decode(bytes: [UInt8]) -> AudioPacket? {
        guard bytes.count >= headerSize else { return nil }
        var reader = ByteReader(bytes)
        guard reader.readUInt8() == magic0, reader.readUInt8() == magic1 else { return nil }
        guard reader.readUInt8() == version else { return nil }
        guard let codec = Codec(rawValue: reader.readUInt8()) else { return nil }
        let sequence = reader.readUInt16()
        let timestamp = reader.readUInt32()
        let count = Int(reader.readUInt16())
        guard count <= maxSamples, bytes.count == headerSize + count * MemoryLayout<Int16>.size else {
            return nil
        }
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = reader.readInt16()
        }
        guard reader.isValid else { return nil }
        return AudioPacket(sequence: sequence, timestamp: timestamp, codec: codec, samples: samples)
    }
}
