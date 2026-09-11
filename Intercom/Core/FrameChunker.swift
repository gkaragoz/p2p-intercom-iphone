import Foundation

/// Re-blocks arbitrarily sized sample buffers into fixed-size frames.
///
/// The audio engine delivers whatever buffer size the hardware feels like (often 1024 or
/// 4096 frames); the network wants exactly one 20 ms frame per packet.
struct FrameChunker {
    let frameSize: Int
    private var pending: [Int16] = []

    init(frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
        pending.reserveCapacity(frameSize * 8)
    }

    /// Samples waiting for enough companions to form a whole frame.
    var bufferedCount: Int { pending.count }

    /// Appends samples and returns every complete frame that became available.
    mutating func append(_ samples: UnsafeBufferPointer<Int16>) -> [[Int16]] {
        pending.append(contentsOf: samples)
        return drainCompleteFrames()
    }

    /// Appends samples and returns every complete frame that became available.
    mutating func append(_ samples: [Int16]) -> [[Int16]] {
        pending.append(contentsOf: samples)
        return drainCompleteFrames()
    }

    /// Returns the partial frame padded with silence, or `nil` when nothing is buffered.
    mutating func flush() -> [Int16]? {
        guard !pending.isEmpty else { return nil }
        var frame = pending
        if frame.count < frameSize {
            frame.append(contentsOf: repeatElement(0, count: frameSize - frame.count))
        }
        pending.removeAll(keepingCapacity: true)
        return frame
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func drainCompleteFrames() -> [[Int16]] {
        guard pending.count >= frameSize else { return [] }
        var frames: [[Int16]] = []
        var start = 0
        while pending.count - start >= frameSize {
            frames.append(Array(pending[start..<(start + frameSize)]))
            start += frameSize
        }
        pending.removeFirst(start)
        return frames
    }
}
