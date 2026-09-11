import Foundation

/// Fixed-capacity FIFO of 16-bit samples.
///
/// Storage is allocated once, so reading in an audio render callback does not allocate.
struct SampleRingBuffer {
    private var storage: [Int16]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage = [Int16](repeating: 0, count: capacity)
    }

    var isEmpty: Bool { count == 0 }
    var availableSpace: Int { capacity - count }

    /// Writes as many samples as fit and returns how many were written.
    @discardableResult
    mutating func write(_ samples: [Int16]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// Writes as many samples as fit and returns how many were written.
    @discardableResult
    mutating func write(_ samples: UnsafeBufferPointer<Int16>) -> Int {
        let toWrite = min(samples.count, availableSpace)
        guard toWrite > 0 else { return 0 }
        var tail = (head + count) % capacity
        for index in 0..<toWrite {
            storage[tail] = samples[index]
            tail += 1
            if tail == capacity { tail = 0 }
        }
        count += toWrite
        return toWrite
    }

    /// Writes `n` zero samples (as many as fit) and returns how many were written.
    @discardableResult
    mutating func writeSilence(_ n: Int) -> Int {
        let toWrite = min(n, availableSpace)
        guard toWrite > 0 else { return 0 }
        var tail = (head + count) % capacity
        for _ in 0..<toWrite {
            storage[tail] = 0
            tail += 1
            if tail == capacity { tail = 0 }
        }
        count += toWrite
        return toWrite
    }

    /// Copies up to `output.count` samples into `output` and returns how many were copied.
    @discardableResult
    mutating func read(into output: UnsafeMutableBufferPointer<Int16>) -> Int {
        let toRead = min(output.count, count)
        guard toRead > 0 else { return 0 }
        var index = head
        for position in 0..<toRead {
            output[position] = storage[index]
            index += 1
            if index == capacity { index = 0 }
        }
        head = index
        count -= toRead
        return toRead
    }

    /// Convenience for tests: reads up to `n` samples into a new array.
    mutating func read(count n: Int) -> [Int16] {
        var result = [Int16](repeating: 0, count: n)
        let readCount = result.withUnsafeMutableBufferPointer { self.read(into: $0) }
        if readCount < n { result.removeLast(n - readCount) }
        return result
    }

    /// Discards up to `n` of the oldest samples.
    mutating func drop(_ n: Int) {
        let toDrop = min(n, count)
        head = (head + toDrop) % capacity
        count -= toDrop
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }
}
