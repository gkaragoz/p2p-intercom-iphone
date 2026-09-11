import Foundation

/// Decides, frame by frame, whether captured audio should be sent.
///
/// The UI updates the inputs from the main thread; the audio capture queue calls
/// `evaluate(levelDB:)` for every frame. A lock keeps the two sides consistent.
final class TransmitGate {
    struct Decision: Equatable {
        /// Send this frame.
        let shouldSend: Bool
        /// `shouldSend` differs from the previous frame's decision.
        let didChange: Bool
        /// Current voice-activity state, regardless of mode.
        let isVoiceDetected: Bool
    }

    private let lock = NSLock()
    private var mode: TransmitMode
    private var isButtonHeld = false
    private var isMuted = false
    private var detector: VoiceActivityDetector
    private var wasSending = false
    /// While closed, every frame is dropped regardless of mode. Closed by `close()` when the
    /// engine stops or an interruption begins; reopened by `open()` once audio is running again.
    private var isOpen = true

    init(mode: TransmitMode, detector: VoiceActivityDetector = VoiceActivityDetector()) {
        self.mode = mode
        self.detector = detector
    }

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
        return Decision(shouldSend: send, didChange: changed, isVoiceDetected: voice)
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
        return wasTransmitting
    }

    /// Reopens the gate after `close()`; the transmit decision resumes from the next frame.
    func open() {
        lock.lock()
        defer { lock.unlock() }
        isOpen = true
    }
}
