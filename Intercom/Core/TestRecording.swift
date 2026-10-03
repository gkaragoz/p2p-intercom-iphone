import Foundation

/// In-memory recording of the user's own voice *as it is sent*: the capture frames after the
/// microphone effect and at the wire rate, so playing it back through the normal receive path
/// (jitter buffer, renderer, listening EQ) lets the user hear exactly what a peer would hear.
///
/// Capture hands the pipeline 20 ms frames; while a test recording runs the pipeline appends every
/// frame here (under its lock) until the recorder is full, then hands the samples to a
/// `LoopbackPacketizer`. Nothing is written to disk.
///
/// `capacity` is fixed in samples (the caller passes seconds × rate) so the recording can never
/// grow past what was reserved: the storage is allocated once in `init` and `append` never
/// reallocates, which keeps the capture path free of allocation while recording.
///
/// Not thread-safe; the owner serializes access.
struct TestRecorder: Sendable {
    /// Maximum number of samples the recording holds; a negative request is treated as 0.
    let capacity: Int
    private(set) var samples: [Int16]

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        samples = []
        samples.reserveCapacity(self.capacity)
    }

    var count: Int { samples.count }

    /// A recorder with capacity 0 is full from the start and never accepts a frame.
    var isFull: Bool { samples.count >= capacity }

    /// Samples still accepted before the recorder is full.
    var remaining: Int { max(0, capacity - samples.count) }

    /// Appends as much of `frame` as still fits; the frame that reaches the capacity is truncated.
    ///
    /// Returns `true` exactly once: on the call that fills the recorder, which is the caller's cue
    /// to stop recording. Every other call, including any append to an already full recorder
    /// (a no-op), returns `false`.
    @discardableResult
    mutating func append(_ frame: [Int16]) -> Bool {
        let room = remaining
        guard room > 0 else { return false }
        if frame.count >= room {
            samples.append(contentsOf: frame[..<room])
            return true
        }
        samples.append(contentsOf: frame)
        return false
    }

    /// Hands out the recording and leaves the recorder empty with the same capacity.
    ///
    /// The recorder gets fresh storage rather than clearing the old one, so the next `append` does
    /// not copy the returned array behind the caller's back (copy-on-write).
    mutating func take() -> [Int16] {
        let taken = samples
        samples = []
        samples.reserveCapacity(capacity)
        return taken
    }

    /// Discards the recording; the capacity and the reserved storage stay.
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}

/// Turns a test recording into the `AudioPacket`s a peer would have received, one 20 ms frame per
/// call, so the controller can feed them into the local jitter buffer at the real packet cadence.
///
/// The samples are split into frames of `codec.frameSamples`; a trailing partial frame is
/// zero-padded to a whole one, because every packet on the wire carries exactly 20 ms and the
/// receive path relies on that. Sequence numbers are contiguous and timestamps advance by one
/// frame per packet, both wrapping like the real sender's, so the jitter buffer sees an ordinary
/// uninterrupted talk spurt.
///
/// Each call to `next()` builds one packet from a slice of the recording; nothing is precomputed,
/// so a 5 s recording costs one small array per 20 ms, not 250 arrays up front.
///
/// Not thread-safe; the owner serializes access.
struct LoopbackPacketizer: Sendable {
    let codec: AudioPacket.Codec
    /// Total number of packets the recording yields, including the padded last one.
    let packetCount: Int
    private let samples: [Int16]
    /// Index of the packet `next()` returns next.
    private var index = 0
    private var sequence: UInt16
    private var timestamp: UInt32

    init(samples: [Int16], codec: AudioPacket.Codec, initialSequence: UInt16 = 0, initialTimestamp: UInt32 = 0) {
        self.samples = samples
        self.codec = codec
        let frame = codec.frameSamples
        packetCount = (samples.count + frame - 1) / frame
        sequence = initialSequence
        timestamp = initialTimestamp
    }

    var remainingPackets: Int { packetCount - index }

    var isFinished: Bool { index >= packetCount }

    /// Playback length: one frame per packet.
    var durationMs: Int { packetCount * (1_000 / IntercomProtocol.framesPerSecond) }

    /// The next packet in order, or `nil` once the recording is exhausted.
    mutating func next() -> AudioPacket? {
        guard index < packetCount else { return nil }
        let frame = codec.frameSamples
        let start = index * frame
        let end = min(start + frame, samples.count)
        let frameSamples: [Int16]
        if end - start == frame {
            frameSamples = Array(samples[start..<end])
        } else {
            var padded = [Int16]()
            padded.reserveCapacity(frame)
            padded.append(contentsOf: samples[start..<end])
            padded.append(contentsOf: repeatElement(0, count: frame - (end - start)))
            frameSamples = padded
        }
        let packet = AudioPacket(sequence: sequence, timestamp: timestamp, codec: codec, samples: frameSamples)
        sequence &+= 1
        timestamp &+= UInt32(truncatingIfNeeded: frame)
        index += 1
        return packet
    }
}
