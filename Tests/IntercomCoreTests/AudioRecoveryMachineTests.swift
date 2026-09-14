import Foundation
import XCTest
@testable import IntercomCore

final class AudioRecoveryMachineTests: XCTestCase {
    private func makeRunningMachine(appActive: Bool = true) -> AudioRecoveryMachine {
        var machine = AudioRecoveryMachine(rng: SplitMix64(seed: 42))
        _ = machine.handle(.started(appActive: appActive))
        XCTAssertEqual(machine.state, .running)
        return machine
    }

    private func attempts(_ effects: [AudioRecoveryMachine.Effect]) -> [AudioRecoveryMachine.Effect] {
        effects.filter { if case .attempt = $0 { return true } else { return false } }
    }

    private func retryDelay(_ effects: [AudioRecoveryMachine.Effect]) -> TimeInterval? {
        for effect in effects {
            if case .scheduleRetry(let delay) = effect { return delay }
        }
        return nil
    }

    func testFailureClassificationAndFourCharacterCodes() {
        XCTAssertEqual(AudioFailureKind(code: 560_557_684), .cannotInterruptOthers)
        XCTAssertEqual(AudioFailureKind(code: 561_145_187), .cannotStartRecording)
        XCTAssertEqual(AudioFailureKind(code: 561_017_449), .insufficientPriority)
        XCTAssertEqual(AudioFailureKind(code: 1_936_290_409), .siriIsRecording)
        XCTAssertEqual(AudioFailureKind(code: 1_836_282_486), .mediaServicesFailed)
        XCTAssertEqual(AudioFailureKind(code: -50), .other(-50))
        XCTAssertEqual(AudioFailureKind.cannotInterruptOthers.description, "'!int' 560557684")
        XCTAssertEqual(AudioFailureKind.cannotStartRecording.description, "'!rec' 561145187")
        XCTAssertEqual(AudioFailureKind.insufficientPriority.description, "'!pri' 561017449")
        XCTAssertEqual(AudioFailureKind.siriIsRecording.description, "'siri' 1936290409")
        XCTAssertEqual(AudioFailureKind.mediaServicesFailed.description, "'msrv' 1836282486")
        XCTAssertEqual(AudioFailureKind.other(-50).description, "-50")
        XCTAssertEqual(AudioFailureKind.other(3).description, "3")
        XCTAssertTrue(AudioFailureKind.cannotInterruptOthers.needsForegroundWhenInBackground)
        XCTAssertTrue(AudioFailureKind.cannotStartRecording.needsForegroundWhenInBackground)
        XCTAssertFalse(AudioFailureKind.insufficientPriority.needsForegroundWhenInBackground)
        XCTAssertTrue(AudioFailureKind.siriIsRecording.isSessionFailure)
        XCTAssertFalse(AudioFailureKind.other(1).isSessionFailure)
    }

    func testInterruptionStopsEngineAndEndedResumesImmediately() {
        var machine = makeRunningMachine()
        let began = machine.handle(.interruptionBegan)
        XCTAssertTrue(began.contains(.stopEngine))
        XCTAssertTrue(began.contains(.stateChanged(.interrupted)))
        XCTAssertEqual(machine.state, .interrupted)
        XCTAssertTrue(machine.handle(.interruptionBegan).isEmpty, "a repeated began is idempotent")

        let ended = machine.handle(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(attempts(ended), [.attempt(.interruptionEnded, recreateEngine: false)])
        XCTAssertEqual(machine.state, .recovering(attempt: 1))
        XCTAssertEqual(machine.handle(.attemptSucceeded), [.stateChanged(.running)])
        XCTAssertEqual(machine.state, .running)
    }

    func testNothingRebuildsWhileInterrupted() {
        var machine = makeRunningMachine()
        _ = machine.handle(.interruptionBegan)
        XCTAssertTrue(attempts(machine.handle(.configurationChanged)).isEmpty)
        XCTAssertTrue(machine.handle(.captureStalled(recreateEngine: false)).isEmpty)
        XCTAssertTrue(machine.handle(.retryTimerFired).isEmpty)
        XCTAssertTrue(attempts(machine.handle(.reconfigure(recreateEngine: false))).isEmpty)
        XCTAssertEqual(machine.state, .interrupted)
    }

    func testForegroundFailuresRetryWithCappedBackoffForever() {
        var machine = makeRunningMachine()
        _ = machine.handle(.interruptionBegan)
        _ = machine.handle(.interruptionEnded(shouldResume: true))
        let nominal: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 5, 5, 5, 5, 5]
        for (index, expected) in nominal.enumerated() {
            let failed = machine.handle(.attemptFailed(.insufficientPriority))
            guard let delay = retryDelay(failed) else {
                return XCTFail("attempt \(index + 1) scheduled no retry")
            }
            XCTAssertEqual(delay, expected, accuracy: expected * 0.1 + 1e-9)
            XCTAssertEqual(machine.state, .recovering(attempt: index + 1))
            XCTAssertEqual(attempts(machine.handle(.retryTimerFired)), [.attempt(.retry, recreateEngine: false)])
        }
        XCTAssertEqual(machine.handle(.attemptSucceeded), [.stateChanged(.running)])
        // The backoff starts over after a success.
        _ = machine.handle(.configurationChanged)
        XCTAssertEqual(retryDelay(machine.handle(.attemptFailed(.other(-1)))) ?? 0, 0.25, accuracy: 0.026)
    }

    func testBackgroundCannotInterruptOthersWaitsForForeground() {
        var machine = makeRunningMachine()
        XCTAssertTrue(machine.handle(.appActiveChanged(false)).isEmpty)
        _ = machine.handle(.interruptionBegan)
        _ = machine.handle(.interruptionEnded(shouldResume: true))
        let failed = machine.handle(.attemptFailed(.cannotInterruptOthers))
        XCTAssertNil(retryDelay(failed))
        XCTAssertTrue(failed.contains(.stateChanged(.needsForeground)))
        XCTAssertEqual(machine.state, .needsForeground)
        XCTAssertTrue(machine.handle(.retryTimerFired).isEmpty)

        let active = machine.handle(.appActiveChanged(true))
        XCTAssertEqual(attempts(active), [.attempt(.appBecameActive, recreateEngine: false)])
        XCTAssertEqual(machine.state, .recovering(attempt: 1))
        _ = machine.handle(.attemptSucceeded)
        XCTAssertEqual(machine.state, .running)
    }

    func testBackgroundCannotStartRecordingWaitsButOtherFailuresKeepRetrying() {
        var machine = makeRunningMachine(appActive: false)
        _ = machine.handle(.configurationChanged)
        let priority = machine.handle(.attemptFailed(.insufficientPriority))
        XCTAssertNotNil(retryDelay(priority), "a call holding the hardware can end while we wait")
        XCTAssertEqual(machine.state, .recovering(attempt: 1))
        _ = machine.handle(.retryTimerFired)
        _ = machine.handle(.attemptFailed(.cannotStartRecording))
        XCTAssertEqual(machine.state, .needsForeground)
    }

    func testForegroundCannotInterruptOthersStillRetries() {
        var machine = makeRunningMachine()
        _ = machine.handle(.captureStalled(recreateEngine: false))
        XCTAssertNotNil(retryDelay(machine.handle(.attemptFailed(.cannotInterruptOthers))))
        XCTAssertEqual(machine.state, .recovering(attempt: 1))
    }

    func testRebuildsWhileRunningKeepReportingRunning() {
        var machine = makeRunningMachine()
        XCTAssertEqual(machine.handle(.configurationChanged), [.attempt(.configurationChange, recreateEngine: false)])
        XCTAssertTrue(machine.handle(.attemptSucceeded).isEmpty)
        XCTAssertEqual(machine.handle(.captureStalled(recreateEngine: true)), [.attempt(.captureStall, recreateEngine: true)])
        XCTAssertTrue(machine.handle(.attemptSucceeded).isEmpty)
        XCTAssertEqual(machine.handle(.reconfigure(recreateEngine: false)), [.attempt(.reconfigure, recreateEngine: false)],
                       "the recreate request was consumed by the successful attempt")
    }

    func testMediaServicesResetRecreatesTheEngine() {
        var machine = makeRunningMachine()
        XCTAssertEqual(attempts(machine.handle(.mediaServicesReset)), [.attempt(.mediaServicesReset, recreateEngine: true)])
        _ = machine.handle(.attemptFailed(.mediaServicesFailed))
        XCTAssertEqual(attempts(machine.handle(.retryTimerFired)), [.attempt(.retry, recreateEngine: true)],
                       "every retry recreates until one succeeds")
        _ = machine.handle(.attemptSucceeded)
        XCTAssertEqual(machine.handle(.configurationChanged), [.attempt(.configurationChange, recreateEngine: false)])
    }

    func testMediaServicesResetDuringInterruptionRecreatesWhenItEnds() {
        var machine = makeRunningMachine()
        _ = machine.handle(.interruptionBegan)
        XCTAssertTrue(attempts(machine.handle(.mediaServicesReset)).isEmpty)
        XCTAssertEqual(attempts(machine.handle(.interruptionEnded(shouldResume: true))),
                       [.attempt(.interruptionEnded, recreateEngine: true)])
    }

    func testMediaServicesResetInBackgroundEndsInNeedsForeground() {
        var machine = makeRunningMachine(appActive: false)
        _ = machine.handle(.mediaServicesReset)
        _ = machine.handle(.attemptFailed(.cannotInterruptOthers))
        XCTAssertEqual(machine.state, .needsForeground)
        XCTAssertEqual(attempts(machine.handle(.appActiveChanged(true))), [.attempt(.appBecameActive, recreateEngine: true)])
    }

    func testAppBecomingActiveWhileRunningChecksHealth() {
        var machine = makeRunningMachine(appActive: false)
        XCTAssertEqual(machine.handle(.appActiveChanged(true)), [.checkHealth])
        XCTAssertTrue(machine.handle(.appActiveChanged(true)).isEmpty, "no change, no effect")
    }

    func testAppBecomingActiveDuringInterruptionTriesImmediately() {
        var machine = makeRunningMachine(appActive: false)
        _ = machine.handle(.interruptionBegan)
        let effects = machine.handle(.appActiveChanged(true))
        XCTAssertEqual(attempts(effects), [.attempt(.appBecameActive, recreateEngine: false)])
        XCTAssertTrue(effects.contains(.cancelRetry))
    }

    func testResumeRequestTriesImmediatelyOnlyWhileAudioIsDown() {
        var machine = makeRunningMachine()
        XCTAssertTrue(machine.handle(.resumeRequested).isEmpty, "nothing to resume while running")

        _ = machine.handle(.interruptionBegan)
        let effects = machine.handle(.resumeRequested)
        XCTAssertEqual(attempts(effects), [.attempt(.userRequested, recreateEngine: false)])
        XCTAssertTrue(effects.contains(.cancelRetry))
        XCTAssertEqual(machine.state, .recovering(attempt: 1))

        // A failed attempt backs off; asking again starts over from the shortest delay.
        for _ in 0..<4 {
            _ = machine.handle(.attemptFailed(.insufficientPriority))
        }
        XCTAssertEqual(machine.state, .recovering(attempt: 4))
        let again = machine.handle(.resumeRequested)
        XCTAssertEqual(attempts(again), [.attempt(.userRequested, recreateEngine: false)])
        let delay = retryDelay(machine.handle(.attemptFailed(.insufficientPriority)))
        XCTAssertEqual(delay ?? 0, 0.25, accuracy: 0.03)
        XCTAssertEqual(machine.state, .recovering(attempt: 1))

        XCTAssertEqual(machine.handle(.attemptSucceeded), [.stateChanged(.running)])
        _ = machine.handle(.stopped)
        XCTAssertTrue(machine.handle(.resumeRequested).isEmpty, "nothing to resume while stopped")
    }

    func testSceneReactivatedWithoutBackgroundTriesLikeAResume() {
        var machine = makeRunningMachine()
        XCTAssertTrue(machine.handle(.sceneReactivated).isEmpty, "nothing to do while running")

        // Siri or an alert covered the app; the interruption never delivers `.ended`.
        _ = machine.handle(.interruptionBegan)
        XCTAssertTrue(machine.handle(.appActiveChanged(true)).isEmpty, "the machine never saw the app leave")
        let effects = machine.handle(.sceneReactivated)
        XCTAssertEqual(attempts(effects), [.attempt(.appBecameActive, recreateEngine: false)])
        XCTAssertTrue(effects.contains(.cancelRetry))
        XCTAssertEqual(machine.state, .recovering(attempt: 1))

        for _ in 0..<3 {
            _ = machine.handle(.attemptFailed(.insufficientPriority))
        }
        _ = machine.handle(.sceneReactivated)
        XCTAssertEqual(retryDelay(machine.handle(.attemptFailed(.insufficientPriority))) ?? 0, 0.25, accuracy: 0.03,
                       "a fresh backoff")
    }

    func testBackgroundTimeExhaustedGivesUpOnlyOnABackgroundRecovery() {
        var machine = makeRunningMachine(appActive: false)
        XCTAssertTrue(machine.handle(.backgroundTimeExhausted).isEmpty, "running: nothing to give up")

        _ = machine.handle(.interruptionBegan)
        XCTAssertTrue(machine.handle(.backgroundTimeExhausted).isEmpty, "an interruption waits for .ended anyway")
        XCTAssertEqual(machine.state, .interrupted)

        _ = machine.handle(.interruptionEnded(shouldResume: true))
        XCTAssertNotNil(retryDelay(machine.handle(.attemptFailed(.other(-10_875)))))
        XCTAssertEqual(machine.state, .recovering(attempt: 1))
        let exhausted = machine.handle(.backgroundTimeExhausted)
        XCTAssertTrue(exhausted.contains(.cancelRetry))
        XCTAssertTrue(exhausted.contains(.stateChanged(.needsForeground)))
        XCTAssertEqual(machine.state, .needsForeground)
        XCTAssertTrue(machine.handle(.retryTimerFired).isEmpty, "a retry that was already due does nothing")
        XCTAssertTrue(machine.handle(.backgroundTimeExhausted).isEmpty)

        XCTAssertEqual(attempts(machine.handle(.appActiveChanged(true))), [.attempt(.appBecameActive, recreateEngine: false)])
        _ = machine.handle(.attemptFailed(.other(-10_875)))
        XCTAssertTrue(machine.handle(.backgroundTimeExhausted).isEmpty, "the foreground keeps retrying")
        XCTAssertEqual(machine.state, .recovering(attempt: 1))
    }

    func testVoiceProcessingChangeWhileRecoveringRecreatesOnNextAttempt() {
        var machine = makeRunningMachine()
        _ = machine.handle(.configurationChanged)
        _ = machine.handle(.attemptFailed(.other(-10_868)))
        XCTAssertTrue(machine.handle(.reconfigure(recreateEngine: true)).isEmpty)
        XCTAssertEqual(attempts(machine.handle(.retryTimerFired)), [.attempt(.retry, recreateEngine: true)])
    }

    func testStoppedIgnoresEverythingButStart() {
        var machine = AudioRecoveryMachine(rng: SplitMix64(seed: 1))
        let inputs: [AudioRecoveryMachine.Input] = [
            .interruptionBegan, .interruptionEnded(shouldResume: true), .mediaServicesReset, .configurationChanged,
            .captureStalled(recreateEngine: true), .reconfigure(recreateEngine: true), .attemptSucceeded,
            .attemptFailed(.cannotInterruptOthers), .retryTimerFired, .appActiveChanged(false), .appActiveChanged(true),
            .resumeRequested, .sceneReactivated, .backgroundTimeExhausted,
        ]
        for input in inputs {
            XCTAssertTrue(attempts(machine.handle(input)).isEmpty, "\(input)")
            XCTAssertEqual(machine.state, .stopped, "\(input)")
        }
        _ = machine.handle(.started(appActive: true))
        _ = machine.handle(.interruptionBegan)
        XCTAssertEqual(machine.handle(.stopped), [.cancelRetry, .stateChanged(.stopped)])
        XCTAssertTrue(machine.handle(.stopped).isEmpty)
        XCTAssertEqual(machine.handle(.started(appActive: true)), [.cancelRetry, .stateChanged(.running)],
                       "a reset or reconfigure seen while stopped does not leak into the next run")
        XCTAssertEqual(machine.handle(.configurationChanged), [.attempt(.configurationChange, recreateEngine: false)])
    }

    func testSinkCaptureIsProbedAgainOnlyForNewRoutesAndSessions() {
        var machine = makeRunningMachine()
        var triggers: [AudioRecoveryMachine.Trigger] = []
        func record(_ effects: [AudioRecoveryMachine.Effect]) {
            for case .attempt(let trigger, _) in effects { triggers.append(trigger) }
        }
        // The sink check blamed the sink: the rebuild and its retries stay on the tap.
        record(machine.handle(.captureStalled(recreateEngine: false)))
        record(machine.handle(.attemptFailed(.other(-10_868))))
        record(machine.handle(.retryTimerFired))
        _ = machine.handle(.attemptSucceeded)
        record(machine.handle(.reconfigure(recreateEngine: false)))
        XCTAssertEqual(triggers, [.captureStall, .retry, .reconfigure])
        XCTAssertFalse(triggers.contains { $0.reprobesSinkCapture })

        // A new route or a session given back tries the sink again.
        triggers = []
        _ = machine.handle(.attemptSucceeded)
        record(machine.handle(.configurationChanged))
        _ = machine.handle(.attemptSucceeded)
        _ = machine.handle(.interruptionBegan)
        record(machine.handle(.interruptionEnded(shouldResume: false)))
        record(machine.handle(.mediaServicesReset))
        _ = machine.handle(.attemptFailed(.insufficientPriority))
        record(machine.handle(.resumeRequested))
        _ = machine.handle(.appActiveChanged(false))
        _ = machine.handle(.attemptFailed(.cannotInterruptOthers))
        record(machine.handle(.appActiveChanged(true)))
        XCTAssertEqual(triggers, [.configurationChange, .interruptionEnded, .mediaServicesReset, .userRequested, .appBecameActive])
        XCTAssertTrue(triggers.allSatisfy { $0.reprobesSinkCapture })
    }
}
