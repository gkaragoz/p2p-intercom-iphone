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
}
