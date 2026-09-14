import XCTest
@testable import IntercomCore

final class TransmitGateTests: XCTestCase {
    func testPushToTalkFollowsButton() {
        let gate = TransmitGate(mode: .pushToTalk, detector: VoiceActivityDetector(thresholdDB: -38, hangoverFrames: 0))
        XCTAssertEqual(gate.evaluate(levelDB: -10), .init(shouldSend: false, didChange: false, isVoiceDetected: true))
        gate.setButtonHeld(true)
        XCTAssertEqual(gate.evaluate(levelDB: -80), .init(shouldSend: true, didChange: true, isVoiceDetected: false))
        XCTAssertEqual(gate.evaluate(levelDB: -80).didChange, false)
        XCTAssertTrue(gate.isSending)
        gate.setButtonHeld(false)
        XCTAssertEqual(gate.evaluate(levelDB: -80), .init(shouldSend: false, didChange: true, isVoiceDetected: false))
    }

    func testMuteOverridesEverything() {
        let gate = TransmitGate(mode: .alwaysOn)
        XCTAssertTrue(gate.evaluate(levelDB: -80).shouldSend)
        gate.setMuted(true)
        XCTAssertEqual(gate.evaluate(levelDB: -80), .init(shouldSend: false, didChange: true, isVoiceDetected: false))
        gate.setMuted(false)
        XCTAssertTrue(gate.evaluate(levelDB: -80).shouldSend)
    }

    func testVoiceActivatedUsesDetectorAndThreshold() {
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 1))
        XCTAssertFalse(gate.evaluate(levelDB: -50).shouldSend)
        XCTAssertTrue(gate.evaluate(levelDB: -35).shouldSend)
        XCTAssertTrue(gate.evaluate(levelDB: -50).shouldSend, "hangover")
        XCTAssertFalse(gate.evaluate(levelDB: -50).shouldSend)
        gate.setVoiceThreshold(dB: -60)
        XCTAssertTrue(gate.evaluate(levelDB: -50).shouldSend)
    }

    func testModeChangeResetsDetector() {
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 10))
        XCTAssertTrue(gate.evaluate(levelDB: 0).shouldSend)
        gate.setMode(.pushToTalk)
        XCTAssertEqual(gate.currentMode, .pushToTalk)
        let decision = gate.evaluate(levelDB: -80)
        XCTAssertFalse(decision.shouldSend)
        XCTAssertFalse(decision.isVoiceDetected)
        XCTAssertTrue(decision.didChange)
    }

    func testCloseReportsWhetherItWasOpen() {
        let gate = TransmitGate(mode: .pushToTalk)
        gate.setButtonHeld(true)
        _ = gate.evaluate(levelDB: -80)
        XCTAssertTrue(gate.close())
        XCTAssertFalse(gate.isSending)
        XCTAssertFalse(gate.close())
        XCTAssertFalse(gate.evaluate(levelDB: -80).shouldSend, "button state was released by close()")
    }

    func testClosedGateIgnoresFramesUntilOpened() {
        let gate = TransmitGate(mode: .alwaysOn)
        XCTAssertTrue(gate.evaluate(levelDB: -20).shouldSend)
        XCTAssertTrue(gate.close())
        XCTAssertTrue(gate.isClosed)
        // A stale frame arriving after close() must not re-open the gate or report a change.
        XCTAssertEqual(gate.evaluate(levelDB: -20), .init(shouldSend: false, didChange: false, isVoiceDetected: false))
        XCTAssertFalse(gate.isSending)
        gate.setButtonHeld(true)
        XCTAssertFalse(gate.evaluate(levelDB: -20).shouldSend)
        gate.open()
        XCTAssertFalse(gate.isClosed)
        XCTAssertEqual(gate.evaluate(levelDB: -20), .init(shouldSend: true, didChange: true, isVoiceDetected: true))
    }

    // MARK: Voice-activation pre-roll

    /// Evaluates `count` frames at `level` and returns the pre-roll requested by each.
    private func preRolls(_ gate: TransmitGate, level: Float, count: Int) -> [Int] {
        (0..<count).map { _ in gate.evaluate(levelDB: level).preRollFrames }
    }

    func testVoiceActivationOpeningAsksForPreRollOnce() {
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 0))
        XCTAssertEqual(gate.preRollFrames, 2)
        XCTAssertEqual(TransmitGate.defaultPreRollFrames, 2, "40 ms")
        XCTAssertEqual(preRolls(gate, level: -60, count: 5), [0, 0, 0, 0, 0])
        let opening = gate.evaluate(levelDB: -20)
        XCTAssertEqual(opening, .init(shouldSend: true, didChange: true, isVoiceDetected: true, preRollFrames: 2))
        XCTAssertEqual(preRolls(gate, level: -20, count: 3), [0, 0, 0], "only the opening frame")
    }

    func testPreRollNeedsMoreUnsentFramesThanItSends() {
        // With exactly `preRollFrames` unsent frames the pre-roll would join the previous spurt
        // seamlessly and hide the talk-spurt boundary from the receiver.
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 0))
        _ = gate.evaluate(levelDB: -20)
        XCTAssertEqual(preRolls(gate, level: -60, count: 2), [0, 0])
        XCTAssertEqual(gate.evaluate(levelDB: -20).preRollFrames, 0)
        XCTAssertEqual(preRolls(gate, level: -60, count: 3), [0, 0, 0])
        XCTAssertEqual(gate.evaluate(levelDB: -20).preRollFrames, 2)
    }

    func testNoPreRollForFramesCapturedWhileMutedClosedOrInAnotherMode() {
        let detector = VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 0)

        let muted = TransmitGate(mode: .voiceActivated, detector: detector)
        muted.setMuted(true)
        _ = preRolls(muted, level: -60, count: 10)
        muted.setMuted(false)
        XCTAssertEqual(muted.evaluate(levelDB: -20).preRollFrames, 0, "frames captured while muted are private")
        _ = preRolls(muted, level: -60, count: 2)
        muted.setMuted(true)
        muted.setMuted(false)
        _ = preRolls(muted, level: -60, count: 2)
        XCTAssertEqual(muted.evaluate(levelDB: -20).preRollFrames, 0, "a mute in between restarts the count")

        let closed = TransmitGate(mode: .voiceActivated, detector: detector)
        _ = preRolls(closed, level: -60, count: 5)
        closed.close()
        _ = preRolls(closed, level: -60, count: 5)
        closed.open()
        XCTAssertEqual(closed.evaluate(levelDB: -20).preRollFrames, 0)

        let modeChange = TransmitGate(mode: .pushToTalk, detector: detector)
        _ = preRolls(modeChange, level: -60, count: 5)
        modeChange.setMode(.voiceActivated)
        _ = preRolls(modeChange, level: -60, count: 2)
        XCTAssertEqual(modeChange.evaluate(levelDB: -20).preRollFrames, 0)

        let pushToTalk = TransmitGate(mode: .pushToTalk, detector: detector)
        _ = preRolls(pushToTalk, level: -60, count: 5)
        pushToTalk.setButtonHeld(true)
        XCTAssertEqual(pushToTalk.evaluate(levelDB: -20), .init(shouldSend: true, didChange: true, isVoiceDetected: true),
                       "push-to-talk never sends audio from before the press")

        let alwaysOn = TransmitGate(mode: .alwaysOn, detector: detector)
        alwaysOn.setMuted(true)
        _ = preRolls(alwaysOn, level: -60, count: 5)
        alwaysOn.setMuted(false)
        XCTAssertEqual(alwaysOn.evaluate(levelDB: -60).preRollFrames, 0)
    }

    func testPreRollCanBeDisabled() {
        let gate = TransmitGate(mode: .voiceActivated, detector: VoiceActivityDetector(thresholdDB: -40, hangoverFrames: 0),
                                preRollFrames: 0)
        XCTAssertEqual(gate.preRollFrames, 0)
        _ = preRolls(gate, level: -60, count: 5)
        XCTAssertEqual(gate.evaluate(levelDB: -20).preRollFrames, 0)
        XCTAssertEqual(TransmitGate(mode: .voiceActivated, preRollFrames: -3).preRollFrames, 0)
    }
}
