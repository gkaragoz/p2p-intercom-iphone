import Foundation

extension Array where Element == UInt8 {
    /// Appends `value` in little-endian byte order.
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// A tiny bounds-checked little-endian reader over a byte array.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0
    /// Becomes `false` as soon as any read runs past the end of the buffer.
    private(set) var isValid = true

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func readUInt8() -> UInt8 {
        guard offset < bytes.count else {
            isValid = false
            return 0
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func readUInt16() -> UInt16 {
        let low = UInt16(readUInt8())
        let high = UInt16(readUInt8())
        return low | (high << 8)
    }

    mutating func readUInt32() -> UInt32 {
        let low = UInt32(readUInt16())
        let high = UInt32(readUInt16())
        return low | (high << 16)
    }

    mutating func readInt16() -> Int16 {
        Int16(bitPattern: readUInt16())
    }
}
