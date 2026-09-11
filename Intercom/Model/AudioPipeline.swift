import Foundation
import MultipeerConnectivity

/// The real-time glue between the audio engine and the network.
///
/// It is deliberately *not* main-actor isolated: `handleCapturedFrame` runs on the audio capture
/// queue for every 20 ms frame and `receive` runs on the MultipeerConnectivity receive thread.
/// Everything the UI needs is exposed through lock-protected snapshots that a timer polls.
final class AudioPipeline {
    let gate: TransmitGate
    let jitterBuffer: JitterBuffer

    /// Fired on the capture queue when transmission starts or stops.
    var onSendingChanged: (@Sendable (Bool) -> Void)?

    private let lock = NSLock()
    private var transport: MultipeerTransport?
    private var sequence: UInt16 = 0
    private var sampleClock: UInt32 = 0
    private var inputSmoother = LevelSmoother()
    private var inputMeter: Float = 0
    private var inputLevelDB: Float = -100
    private var voiceDetected = false
    private var lastRemoteAudio: TimeInterval = 0
    private var framesSent = 0

    init(gate: TransmitGate, jitterBuffer: JitterBuffer) {
        self.gate = gate
        self.jitterBuffer = jitterBuffer
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

    func setTransport(_ transport: MultipeerTransport?) {
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
        var packet: AudioPacket?
        if decision.shouldSend {
            packet = AudioPacket(sequence: sequence, timestamp: sampleClock, samples: samples)
            sequence &+= 1
            sampleClock &+= UInt32(samples.count)
            framesSent += 1
        }
        lock.unlock()

        if decision.didChange {
            onSendingChanged?(decision.shouldSend)
        }
        if let packet {
            transport?.sendAudio(packet)
        }
    }

    // MARK: Network receive thread

    func receive(_ packet: AudioPacket) {
        jitterBuffer.push(packet)
        lock.lock()
        lastRemoteAudio = Date().timeIntervalSinceReferenceDate
        lock.unlock()
    }
}
