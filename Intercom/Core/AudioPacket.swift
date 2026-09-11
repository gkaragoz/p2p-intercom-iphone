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
    enum Codec: UInt8 {
        /// Uncompressed 16 kHz mono 16-bit PCM.
        case pcm16Mono16k = 1
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
        return Data(bytes)
    }

    static func decode(_ data: Data) -> AudioPacket? {
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
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
