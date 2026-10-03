import Foundation

/// The real-time glue between the audio engine and the network.
///
/// It is deliberately *not* main-actor isolated: `handleCapturedFrame` runs on the audio capture
/// queue for every 20 ms frame and `receive` runs on the transport's receive context.
/// Everything the UI needs is exposed through lock-protected snapshots that a timer polls.
///
/// Both directions have a wire rate. Outgoing frames arrive at `wireRate` (the engine's capture
/// source is built for it) and leave stamped with its codec. Incoming packets may carry any codec,
/// since the peer picks its own rate; `receive` brings them to the local rate with an
/// `InboundRateAdapter` before the jitter buffer sees them, so the buffer only ever holds frames of
/// its own size and clock.
///
/// Test recording ("hear yourself"): while a `TestRecorder` is installed, every captured frame is
/// appended to it as well, whatever the transmit gate decides, so the user need not hold the talk
/// button and transmission is not affected. The frames are the post-effect frames at the wire
/// rate: exactly what a peer receives. Playing the recording back pushes it as paced packets into
/// the *local* jitter buffer (`pushLoopback`), so it travels the real receive path; the peer's
/// packets are dropped for those few seconds so the two streams do not interleave.
final class AudioPipeline: @unchecked Sendable {
    let gate: TransmitGate
    let jitterBuffer: JitterBuffer

    /// Fired on the capture queue when transmission starts or stops.
    var onSendingChanged: (@Sendable (Bool) -> Void)?
    /// Fired once per test recording, on the capture queue, when the recorder reaches its capacity.
    var onTestRecordingFull: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var transport: PeerTransport?
    /// Guarded by `lock`. Collects captured frames while a test recording runs.
    private var recorder: TestRecorder?
    /// Guarded by `lock`. A test recording is playing through the local jitter buffer; packets from
    /// the peer are dropped meanwhile.
    private var isLoopbackPlaying = false
    /// Rate of the frames expected from capture and of the packets sent.
    var wireRate: WireRate {
        lock.withLock { wireRateValue }
    }

    /// Guarded by `lock`.
    private var wireRateValue: WireRate
    /// Numbers packets, keeps the capture sample clock and the voice-activation pre-roll.
    private var packetizer: AudioPacketizer
    private var inputSmoother = LevelSmoother()
    private var inputMeter: Float = 0
    private var inputLevelDB: Float = -100
    private var voiceDetected = false
    private var lastRemoteAudio: TimeInterval = 0
    private var framesSent = 0
    /// Frames of the wrong size, from the previous capture source during a rate change.
    private var droppedMismatchedFrames = 0

    /// Its own lock: the receive path must never wait on the capture path (or the UI snapshot).
    private let inboundLock = NSLock()
    /// Guarded by `inboundLock`.
    private var inbound: InboundRateAdapter

    init(gate: TransmitGate, jitterBuffer: JitterBuffer, wireRate: WireRate = .standard) {
        self.gate = gate
        self.jitterBuffer = jitterBuffer
        wireRateValue = wireRate
        packetizer = AudioPacketizer(preRollCapacity: gate.preRollFrames, codec: wireRate.codec)
        inbound = InboundRateAdapter(localRate: wireRate)
    }

    struct Snapshot: Equatable {
        var inputMeter: Float
        var inputLevelDB: Float
        var isVoiceDetected: Bool
        var secondsSinceRemoteAudio: TimeInterval
        var framesSent: Int
        /// Sample rate of the most recent packet from the peer; `nil` until one arrived.
        var incomingSampleRate: Int?
        var droppedMismatchedFrames: Int
        /// Samples captured by the running test recording; 0 without one.
        var testRecordedSamples: Int
    }

    func snapshot(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Snapshot {
        inboundLock.lock()
        let incomingSampleRate = inbound.lastIncomingCodec?.sampleRate
        inboundLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            inputMeter: inputMeter,
            inputLevelDB: inputLevelDB,
            isVoiceDetected: voiceDetected,
            secondsSinceRemoteAudio: lastRemoteAudio == 0 ? .infinity : max(0, now - lastRemoteAudio),
            framesSent: framesSent,
            incomingSampleRate: incomingSampleRate,
            droppedMismatchedFrames: droppedMismatchedFrames,
            testRecordedSamples: recorder?.count ?? 0
        )
    }

    func setTransport(_ transport: PeerTransport?) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    /// Switches both directions to `rate`. Outgoing: the packetizer is replaced by one for the new
    /// codec that continues the sequence numbers (a jump would make the receiver resync and drop
    /// what it holds) and the sample clock, then marked discontinuous so the clock jump starts a new
    /// talk spurt at the receiver, whose delay estimate does not carry over between rates. Frames of
    /// the old size that the capture worker still delivers while the engine rebuilds are dropped by
    /// `handleCapturedFrame`. Incoming: the adapter re-targets the new local rate; the caller
    /// reconfigures the jitter buffer for it separately.
    func setWireRate(_ rate: WireRate) {
        lock.lock()
        if rate != wireRateValue {
            packetizer = AudioPacketizer(preRollCapacity: gate.preRollFrames, codec: rate.codec,
                                         initialSequence: packetizer.nextSequence,
                                         initialSampleClock: packetizer.sampleClock)
            packetizer.markDiscontinuity()
            wireRateValue = rate
        }
        lock.unlock()
        inboundLock.lock()
        inbound.setLocalRate(rate)
        inboundLock.unlock()
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
        // A test that was still running is over with the intercom.
        recorder = nil
        isLoopbackPlaying = false
        lock.unlock()
        // The next stream may come from another peer, at another rate.
        inboundLock.lock()
        inbound.reset()
        inboundLock.unlock()
    }

    /// Call whenever capture stops delivering frames for a while without the pipeline being reset
    /// (interruption, engine rebuild): drops pre-roll and makes the receiver re-anchor its delay
    /// estimate instead of reading the pause as network delay.
    func markCaptureDiscontinuity() {
        lock.lock()
        packetizer.markDiscontinuity()
        lock.unlock()
    }

    // MARK: Test recording (any thread)

    /// Starts collecting captured frames, up to `capacity` samples at the current wire rate;
    /// `onTestRecordingFull` fires when they are all there. Replaces a recording in progress.
    /// The storage is reserved here, off the capture thread, so appending never allocates.
    func startTestRecording(capacity: Int) {
        let fresh = TestRecorder(capacity: capacity)
        lock.lock()
        recorder = fresh
        lock.unlock()
    }

    /// Ends the recording and returns what was captured so far (possibly nothing); a no-op that
    /// returns an empty array when none is running.
    func stopTestRecording() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        guard let recorder else { return [] }
        self.recorder = nil
        return recorder.samples
    }

    /// From now on the jitter buffer plays the test recording (`pushLoopback`) and the peer's
    /// packets are dropped. The buffer is emptied so the recording starts on a clean playout
    /// clock rather than behind whatever the peer had queued.
    func beginLoopback() {
        lock.lock()
        isLoopbackPlaying = true
        lock.unlock()
        jitterBuffer.reset()
    }

    /// Queues one packet of the recording as if it had just arrived from the peer. Dropped unless
    /// the loopback is active and the packet carries the local codec, since the buffer holds frames
    /// of the local size only. Not routed through the inbound adapter: that tracks the remote
    /// stream and must not see the local one.
    func pushLoopback(_ packet: AudioPacket) {
        lock.lock()
        let accepted = isLoopbackPlaying && packet.codec == wireRateValue.codec
        lock.unlock()
        guard accepted else { return }
        jitterBuffer.push(packet, arrival: .now())
    }

    /// The recording has played out; the peer's packets flow into the buffer again, from a clean
    /// state (the loopback's clock and delay history mean nothing for the remote stream).
    func endLoopback() {
        lock.lock()
        isLoopbackPlaying = false
        lock.unlock()
        jitterBuffer.reset()
    }

    var isLoopbackActive: Bool {
        lock.withLock { isLoopbackPlaying }
    }

    // MARK: Capture queue

    func handleCapturedFrame(_ samples: [Int16], levelDB: Float) {
        let decision = gate.evaluate(levelDB: levelDB)

        lock.lock()
        // During a rate change the engine rebuilds its graph asynchronously, so the worker can still
        // deliver a frame or two at the old size after `setWireRate`; a wrong-size frame would be
        // stamped with the new codec and played at the wrong speed, so it is dropped instead. The
        // gate decision above still ran, so a transition it reported is passed on all the same.
        guard samples.count == wireRateValue.frameSamples else {
            droppedMismatchedFrames += 1
            lock.unlock()
            if decision.didChange {
                onSendingChanged?(decision.shouldSend)
            }
            return
        }
        inputLevelDB = levelDB
        inputMeter = inputSmoother.process(AudioLevel.meterValue(dB: levelDB))
        voiceDetected = decision.isVoiceDetected
        let transport = self.transport
        // Pre-roll frames (voice activation just opened) come first, with contiguous sequence numbers.
        let packets = packetizer.process(samples, decision: decision)
        framesSent += packets.count
        // Whatever the gate decided: the test records what the peer *would* hear.
        let recordingFull = recorder?.append(samples) == true
        lock.unlock()

        if decision.didChange {
            onSendingChanged?(decision.shouldSend)
        }
        if let transport {
            for packet in packets {
                transport.sendAudio(packet)
            }
        }
        if recordingFull {
            onTestRecordingFull?()
        }
    }

    // MARK: Transport receive context

    func receive(_ packet: AudioPacket) {
        // Stamp arrival first: the playout delay estimator measures per-packet delay from it, and
        // resampling must not count as network delay.
        let arrival = MonotonicTime.now()
        lock.lock()
        let loopback = isLoopbackPlaying
        lock.unlock()
        // The local recording owns the buffer for a few seconds; the peer's audio is not queued
        // behind it (and `lastRemoteAudio` is left alone: nothing of theirs is being played).
        guard !loopback else { return }
        inboundLock.lock()
        let adapted = inbound.adapt(packet)
        inboundLock.unlock()
        jitterBuffer.push(adapted, arrival: arrival)
        lock.lock()
        lastRemoteAudio = Date().timeIntervalSinceReferenceDate
        lock.unlock()
    }
}
