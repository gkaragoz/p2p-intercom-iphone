import Foundation

/// The real-time glue between the audio engine and the network.
///
/// It is deliberately *not* main-actor isolated: `handleCapturedFrame` runs on the audio capture
/// queue for every 20 ms frame and `receive` runs on the transport's receive context.
/// Everything the UI needs is exposed through lock-protected snapshots that a timer polls.
final class AudioPipeline: @unchecked Sendable {
    let gate: TransmitGate
    let jitterBuffer: JitterBuffer

    /// Fired on the capture queue when transmission starts or stops.
    var onSendingChanged: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var transport: PeerTransport?
    /// Numbers packets, keeps the capture sample clock and the voice-activation pre-roll.
    private var packetizer: AudioPacketizer
    private var inputSmoother = LevelSmoother()
    private var inputMeter: Float = 0
    private var inputLevelDB: Float = -100
    private var voiceDetected = false
    private var lastRemoteAudio: TimeInterval = 0
    private var framesSent = 0

    init(gate: TransmitGate, jitterBuffer: JitterBuffer) {
        self.gate = gate
        self.jitterBuffer = jitterBuffer
        packetizer = AudioPacketizer(preRollCapacity: gate.preRollFrames)
    }

    struct Snapshot: Equatable {
        var inputMeter: Float
        var inputLevelDB: Float
        var isVoiceDetected: Bool
        var secondsSinceRemoteAudio: TimeInterval
        var framesSent: Int
    }

    func snapshot(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            inputMeter: inputMeter,
            inputLevelDB: inputLevelDB,
            isVoiceDetected: voiceDetected,
            secondsSinceRemoteAudio: lastRemoteAudio == 0 ? .infinity : max(0, now - lastRemoteAudio),
            framesSent: framesSent
        )
    }

    func setTransport(_ transport: PeerTransport?) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    func resetMeters() {
        lock.lock()
        inputSmoother.reset()
        inputMeter = 0
        inputLevelDB = -100
        voiceDetected = false
        lastRemoteAudio = 0
        // Frames captured before a stop must never be sent as pre-roll later, and the next packet
        // starts a new talk spurt at the receiver.
        packetizer.markDiscontinuity()
        lock.unlock()
    }

    /// Call whenever capture stops delivering frames for a while without the pipeline being reset
    /// (interruption, engine rebuild): drops pre-roll and makes the receiver re-anchor its delay
    /// estimate instead of reading the pause as network delay.
    func markCaptureDiscontinuity() {
        lock.lock()
        packetizer.markDiscontinuity()
        lock.unlock()
    }

    // MARK: Capture queue

    func handleCapturedFrame(_ samples: [Int16], levelDB: Float) {
        let decision = gate.evaluate(levelDB: levelDB)

        lock.lock()
        inputLevelDB = levelDB
        inputMeter = inputSmoother.process(AudioLevel.meterValue(dB: levelDB))
        voiceDetected = decision.isVoiceDetected
        let transport = self.transport
        // Pre-roll frames (voice activation just opened) come first, with contiguous sequence numbers.
        let packets = packetizer.process(samples, decision: decision)
        framesSent += packets.count
        lock.unlock()

        if decision.didChange {
            onSendingChanged?(decision.shouldSend)
        }
        if let transport {
            for packet in packets {
                transport.sendAudio(packet)
            }
        }
    }

    // MARK: Transport receive context

    func receive(_ packet: AudioPacket) {
        // Stamp arrival first: the playout delay estimator measures per-packet delay from it.
        jitterBuffer.push(packet, arrival: .now())
        lock.lock()
        lastRemoteAudio = Date().timeIntervalSinceReferenceDate
        lock.unlock()
    }
}
