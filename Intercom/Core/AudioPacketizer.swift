import Foundation

/// Turns gated capture frames into numbered `AudioPacket`s, including voice-activation pre-roll.
///
/// Feed it every captured frame together with the `TransmitGate` decision for that frame, in
/// capture order. It returns the packets to send, oldest first:
///
/// * Sequence numbers count sent packets only and are always contiguous, so a gap at the receiver
///   means loss.
/// * The timestamp is the capture sample clock, which advances for *every* frame, sent or not. A
///   pause therefore shows up as a timestamp jump, which is how the receiver's
///   `PlayoutDelayEstimator` recognises a new talk spurt, and pre-roll frames carry their true
///   capture time.
/// * The last `preRollCapacity` unsent frames are remembered. When a decision asks for pre-roll
///   (voice activation just opened) they are sent first, then the current frame.
/// * When capture itself stops (engine stopped, interrupted or rebuilt) no frames arrive, so the
///   sample clock would not reflect the pause. `markDiscontinuity()` jumps it forward instead, so
///   the receiver still sees a new talk spurt rather than a burst of very late packets.
///
/// Not thread-safe; the caller serializes access (the capture worker, under the pipeline lock).
struct AudioPacketizer {
    let preRollCapacity: Int
    private(set) var nextSequence: UInt16
    private(set) var sampleClock: UInt32
    /// Most recent unsent frames, oldest first, at most `preRollCapacity`.
    private var recent: [(timestamp: UInt32, samples: [Int16])] = []

    init(preRollCapacity: Int = TransmitGate.defaultPreRollFrames, initialSequence: UInt16 = 0, initialSampleClock: UInt32 = 0) {
        self.preRollCapacity = max(0, preRollCapacity)
        nextSequence = initialSequence
        sampleClock = initialSampleClock
        recent.reserveCapacity(self.preRollCapacity + 1)
    }

    /// Unsent frames currently available as pre-roll.
    var bufferedPreRollFrames: Int { recent.count }

    mutating func process(_ samples: [Int16], decision: TransmitGate.Decision) -> [AudioPacket] {
        let timestamp = sampleClock
        sampleClock &+= UInt32(truncatingIfNeeded: samples.count)

        guard decision.shouldSend else {
            if preRollCapacity > 0 {
                recent.append((timestamp, samples))
                if recent.count > preRollCapacity {
                    recent.removeFirst()
                }
            }
            return []
        }

        var packets: [AudioPacket] = []
        let preRoll = min(max(0, decision.preRollFrames), recent.count)
        packets.reserveCapacity(preRoll + 1)
        for frame in recent.suffix(preRoll) {
            packets.append(makePacket(timestamp: frame.timestamp, samples: frame.samples))
        }
        // Sent (or superseded) frames are never pre-roll for a later spurt.
        recent.removeAll(keepingCapacity: true)
        packets.append(makePacket(timestamp: timestamp, samples: samples))
        return packets
    }

    /// How far `markDiscontinuity()` advances the sample clock: one second at the wire rate. Any
    /// jump of more than half a frame is recognised by the receiver; a whole second is unambiguous.
    static let discontinuitySamples = Int(IntercomProtocol.sampleRate)

    /// Forgets remembered frames; numbering and the sample clock continue.
    mutating func discardPreRoll() {
        recent.removeAll(keepingCapacity: true)
    }

    /// Capture stopped or restarted: frames from before must never become pre-roll, and the next
    /// packet must start a new talk spurt at the receiver. Sequence numbers stay contiguous.
    mutating func markDiscontinuity() {
        recent.removeAll(keepingCapacity: true)
        sampleClock &+= UInt32(Self.discontinuitySamples)
    }

    private mutating func makePacket(timestamp: UInt32, samples: [Int16]) -> AudioPacket {
        let packet = AudioPacket(sequence: nextSequence, timestamp: timestamp, samples: samples)
        nextSequence &+= 1
        return packet
    }
}
