import Foundation

/// Brings every received `AudioPacket` to the receiver's own `WireRate` before it enters the
/// jitter buffer, which only ever sees packets whose sample count is its frame size and whose
/// timestamps run at its sample rate.
///
/// The sender picks its wire rate independently, so a packet may arrive at any of the four rates.
/// A packet whose codec already matches `localRate` passes through untouched (no copy). Any other
/// packet is resampled by a `Resampler` built for that codec pair, and its timestamp is converted
/// to the local sample clock:
///
/// * The sender's 32-bit sample clock is unwrapped onto a 64-bit counter relative to the first
///   packet seen for the current codec (the same `Int32(bitPattern:)` trick the playout delay
///   estimator uses), scaled by `outputRate / inputRate` in integer arithmetic, and re-wrapped.
///   For whole 20 ms frames the scaling is exact, because a frame at any of these rates is a
///   multiple of the decimation factor, so consecutive frames stay exactly one local frame apart
///   and the estimator's talk-spurt detection sees the same clock pattern the sender produced.
/// * A sequence gap or reorder resets the resampler history before the packet is processed: the
///   filter then starts from silence (a bounded ~1 ms transient) instead of continuing from the
///   tail of a frame that was not this packet's predecessor.
/// * A codec change mid-stream rebuilds the resampler and re-anchors the timestamp conversion.
///
/// Odd packets (a sample count that is not a whole frame at the codec's rate, including zero)
/// go through the general streaming path and yield whatever the resampler produces; they never
/// crash the receive thread.
///
/// Runs on the network thread. Steady state (one codec, whole frames) allocates only the output
/// sample array of each adapted packet; a codec change or the first larger packet allocates once.
/// Value type; not thread-safe, the owner serialises calls.
struct InboundRateAdapter: Sendable {
    private(set) var localRate: WireRate
    /// Codec of the most recent packet passed to `adapt`, whether or not it was resampled.
    private(set) var lastIncomingCodec: AudioPacket.Codec?

    private var resampler: Resampler?
    /// Sequence the next packet should carry if nothing was lost or reordered.
    private var expectedSequence: UInt16?
    /// Timestamp conversion state, valid while `resampler` is set.
    private var referenceScaled: Int64 = 0
    private var previousRaw: UInt32 = 0
    private var extended: Int64 = 0

    init(localRate: WireRate) {
        self.localRate = localRate
    }

    /// Changes the playback rate. Every packet is adapted to the new rate from now on; the
    /// resampler and the timestamp anchor are rebuilt by the next packet.
    mutating func setLocalRate(_ rate: WireRate) {
        localRate = rate
        reset()
    }

    /// Forgets the incoming codec, the sequence expectation and the resampler, as at start.
    mutating func reset() {
        lastIncomingCodec = nil
        resampler = nil
        expectedSequence = nil
        referenceScaled = 0
        previousRaw = 0
        extended = 0
    }

    /// Returns `packet` at `localRate`: unchanged when its codec already matches, otherwise
    /// resampled with its timestamp rescaled and its codec set to `localRate.codec`.
    mutating func adapt(_ packet: AudioPacket) -> AudioPacket {
        let codecChanged = packet.codec != lastIncomingCodec
        let continuous = expectedSequence == packet.sequence
        lastIncomingCodec = packet.codec
        expectedSequence = packet.sequence &+ 1

        guard packet.codec != localRate.codec else {
            if codecChanged { resampler = nil }
            return packet
        }

        let inputRate = Int64(packet.codec.sampleRate)
        let outputRate = Int64(localRate.sampleRate)
        if codecChanged || resampler == nil {
            resampler = Resampler(inputRate: packet.codec.sampleRate, outputRate: localRate.sampleRate)
            referenceScaled = Self.floorDivide(Int64(packet.timestamp) * outputRate, by: inputRate)
            extended = 0
        } else {
            if !continuous {
                resampler?.reset()
            }
            extended += Int64(Int32(bitPattern: packet.timestamp &- previousRaw))
        }
        previousRaw = packet.timestamp

        let scaled = referenceScaled + Self.floorDivide(extended * outputRate, by: inputRate)
        let samples = resampler!.process(packet.samples)
        return AudioPacket(sequence: packet.sequence,
                           timestamp: UInt32(truncatingIfNeeded: scaled),
                           codec: localRate.codec,
                           samples: samples)
    }

    /// Integer division rounding towards −∞, so a reordered packet that lands before the anchor
    /// is placed consistently with the packets after it. Exact for whole frames.
    private static func floorDivide(_ numerator: Int64, by divisor: Int64) -> Int64 {
        let quotient = numerator / divisor
        return numerator % divisor != 0 && (numerator < 0) != (divisor < 0) ? quotient - 1 : quotient
    }
}
