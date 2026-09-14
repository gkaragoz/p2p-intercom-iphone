import Foundation

/// Decides, frame by frame, whether captured audio should be sent.
///
/// The UI updates the inputs from the main thread; the audio capture queue calls
/// `evaluate(levelDB:)` for every frame. A lock keeps the two sides consistent. Neither side is a
/// real-time thread (capture frames are evaluated on the capture worker), so a blocking lock is fine.
///
/// Voice-activation pre-roll: the detector only fires once a frame is already loud, so the first
/// consonant of a word would be clipped. When voice activation opens, the decision asks the caller
/// (`AudioPacketizer`) to send the last `preRollFrames` unsent frames first. Pre-roll is offered only
/// when more than `preRollFrames` consecutive frames went unsent while the gate was open, unmuted
/// and voice-activated: frames captured while muted, closed or in another mode are never sent
/// later, and the sample-clock gap before the pre-roll lets the receiver recognise a new talk spurt.
final class TransmitGate {
    struct Decision: Equatable {
        /// Send this frame.
        let shouldSend: Bool
        /// `shouldSend` differs from the previous frame's decision.
        let didChange: Bool
        /// Current voice-activity state, regardless of mode.
        let isVoiceDetected: Bool
        /// How many of the most recent unsent frames to send immediately before this one.
        /// Non-zero only on the frame where voice activation opens; see `preRollFrames`.
        let preRollFrames: Int

        init(shouldSend: Bool, didChange: Bool, isVoiceDetected: Bool, preRollFrames: Int = 0) {
            self.shouldSend = shouldSend
            self.didChange = didChange
            self.isVoiceDetected = isVoiceDetected
            self.preRollFrames = preRollFrames
        }
    }

    /// Default voice-activation pre-roll: 2 frames (40 ms).
    static let defaultPreRollFrames = 2

    private let lock = NSLock()
    private var mode: TransmitMode
    private var isButtonHeld = false
    private var isMuted = false
    private var detector: VoiceActivityDetector
    private var wasSending = false
    private let preRollLimit: Int
    /// Consecutive unsent frames that would be acceptable as pre-roll (capped at `preRollLimit + 1`).
    private var unsentEligibleFrames = 0
    /// While closed, every frame is dropped regardless of mode. Closed by `close()` when the
    /// engine stops or an interruption begins; reopened by `open()` once audio is running again.
    private var isOpen = true

    init(mode: TransmitMode,
         detector: VoiceActivityDetector = VoiceActivityDetector(),
         preRollFrames: Int = TransmitGate.defaultPreRollFrames) {
        self.mode = mode
        self.detector = detector
        preRollLimit = max(0, preRollFrames)
    }

    /// Frames of voice-activation pre-roll this gate asks for.
    var preRollFrames: Int { preRollLimit }

    var currentMode: TransmitMode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }

    var isSending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasSending
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isOpen
    }

    func setMode(_ newMode: TransmitMode) {
        lock.lock()
        defer { lock.unlock() }
        mode = newMode
        detector.reset()
        unsentEligibleFrames = 0
    }

    func setButtonHeld(_ held: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isButtonHeld = held
    }

    func setMuted(_ muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isMuted = muted
        if muted { unsentEligibleFrames = 0 }
    }

    func setVoiceThreshold(dB: Float) {
        lock.lock()
        defer { lock.unlock() }
        detector.thresholdDB = dB
    }

    /// Evaluates one captured frame.
    func evaluate(levelDB: Float) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else {
            // A frame that was already queued when the gate was closed must not reopen it.
            return Decision(shouldSend: false, didChange: false, isVoiceDetected: false)
        }
        let voice = detector.process(levelDB: levelDB)
        var send: Bool
        switch mode {
        case .pushToTalk:
            send = isButtonHeld
        case .voiceActivated:
            send = voice
        case .alwaysOn:
            send = true
        }
        send = send && !isMuted
        let changed = send != wasSending
        wasSending = send

        var preRoll = 0
        let preRollMode = mode == .voiceActivated && !isMuted
        if send {
            if changed, preRollMode, unsentEligibleFrames > preRollLimit {
                preRoll = preRollLimit
            }
            unsentEligibleFrames = 0
        } else if preRollMode {
            unsentEligibleFrames = min(unsentEligibleFrames + 1, preRollLimit + 1)
        } else {
            unsentEligibleFrames = 0
        }
        return Decision(shouldSend: send, didChange: changed, isVoiceDetected: voice, preRollFrames: preRoll)
    }

    /// Closes the gate (engine stopped, interruption began) and reports whether it was transmitting.
    /// Frames are ignored until `open()` is called.
    @discardableResult
    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasTransmitting = wasSending
        wasSending = false
        isButtonHeld = false
        isOpen = false
        detector.reset()
        unsentEligibleFrames = 0
        return wasTransmitting
    }

    /// Reopens the gate after `close()`; the transmit decision resumes from the next frame.
    func open() {
        lock.lock()
        defer { lock.unlock() }
        isOpen = true
    }
}
