import Foundation

/// Why activating the audio session or starting the engine failed, from the error's OSStatus code.
///
/// The codes come from `AVAudioSession.ErrorCode` (CoreAudioTypes `AudioSessionTypes.h`). Core
/// cannot import AVFoundation, so they are spelled out as integers here.
enum AudioFailureKind: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// '!int': a non-mixable session tried to go active in the background (not the Now Playing app).
    case cannotInterruptOthers
    /// '!rec': recording could not start, typically because the app is in the background.
    case cannotStartRecording
    /// '!pri': another app with higher priority (a phone call) owns the audio hardware.
    case insufficientPriority
    /// 'siri': Siri is recording.
    case siriIsRecording
    /// 'msrv': the media server is resetting.
    case mediaServicesFailed
    case other(Int)

    static let cannotInterruptOthersCode = 560_557_684
    static let cannotStartRecordingCode = 561_145_187
    static let insufficientPriorityCode = 561_017_449
    static let siriIsRecordingCode = 1_936_290_409
    static let mediaServicesFailedCode = 1_836_282_486

    init(code: Int) {
        switch code {
        case Self.cannotInterruptOthersCode: self = .cannotInterruptOthers
        case Self.cannotStartRecordingCode: self = .cannotStartRecording
        case Self.insufficientPriorityCode: self = .insufficientPriority
        case Self.siriIsRecordingCode: self = .siriIsRecording
        case Self.mediaServicesFailedCode: self = .mediaServicesFailed
        default: self = .other(code)
        }
    }

    var code: Int {
        switch self {
        case .cannotInterruptOthers: return Self.cannotInterruptOthersCode
        case .cannotStartRecording: return Self.cannotStartRecordingCode
        case .insufficientPriority: return Self.insufficientPriorityCode
        case .siriIsRecording: return Self.siriIsRecordingCode
        case .mediaServicesFailed: return Self.mediaServicesFailedCode
        case .other(let code): return code
        }
    }

    /// One of the audio-session codes above (as opposed to a graph or format problem).
    var isSessionFailure: Bool {
        if case .other = self { return false }
        return true
    }

    /// The system refuses this while the app is in the background: retrying is pointless until the
    /// user brings the app to the foreground.
    var needsForegroundWhenInBackground: Bool {
        self == .cannotInterruptOthers || self == .cannotStartRecording
    }

    /// e.g. "'!int' 560557684", or just the number when it is not a printable four-character code.
    var description: String {
        let value = code
        guard value > 0, value <= Int(UInt32.max) else { return "\(value)" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: UInt32(value) >> UInt32($0)) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(value)" }
        let fourCC = String(decoding: bytes, as: UTF8.self)
        return "'\(fourCC)' \(value)"
    }
}

/// Decides when the audio engine is (re)built, as a pure reducer the audio engine glue drives.
///
/// States:
/// * `running`: the engine is started. Configuration changes and capture stalls rebuild it in place.
/// * `interrupted`: an audio interruption (phone call, Siri, another app's audio) began. Nothing is
///   rebuilt until it ends or the app comes to the foreground.
/// * `recovering(attempt:)`: an attempt to bring audio back failed; retries back off 0.25 … 5 s.
/// * `needsForeground`: activation failed in the background with '!int' or '!rec'. The system only
///   lets a non-mixable voice session go active from the foreground, so retrying from the background
///   would fail forever; the next attempt happens when the app becomes active.
///
/// Background failures other than '!int' and '!rec' retry only while background time lasts: with
/// audio I/O down, nothing but a background task keeps the process (and the retry timer) alive, so
/// the glue reports `backgroundTimeExhausted` shortly before that task runs out, and the machine
/// gives up with `needsForeground` instead of retrying silently in a suspended process.
///
/// Every attempt is performed synchronously by the glue (`Effect.attempt`), which feeds back
/// `attemptSucceeded` or `attemptFailed(_:)` before handling anything else.
///
/// Invariant (see `AudioEngineController`): while the intercom runs, the machine never stops the
/// engine for anything but an interruption. Push-to-talk idle, mute and "no peer" keep audio I/O
/// running, because audio I/O is what keeps the app alive in the background and the engine cannot
/// be started again from the background.
struct AudioRecoveryMachine {
    enum State: Equatable, Sendable, CustomStringConvertible {
        case stopped
        case running
        case interrupted
        case recovering(attempt: Int)
        case needsForeground

        var description: String {
            switch self {
            case .stopped: return "stopped"
            case .running: return "running"
            case .interrupted: return "interrupted"
            case .recovering(let attempt): return "recovering(attempt \(attempt))"
            case .needsForeground: return "needsForeground"
            }
        }
    }

    /// What prompted an attempt; for the logs.
    enum Trigger: String, Equatable, Sendable {
        case interruptionEnded
        case appBecameActive
        case retry
        case configurationChange
        case captureStall
        case mediaServicesReset
        case reconfigure
        case userRequested

        /// Whether an attempt for this trigger tries the low-latency sink capture again after it
        /// failed earlier in the run. The fallback to the tap is meant for the conditions that
        /// caused it: a new route (configuration change), a session that was taken away and given
        /// back (interruption, media services reset, foreground or user resume) deserves a fresh
        /// try. The rebuild that follows a sink verdict (`captureStall`) and its retries keep the
        /// tap, or the sink would be probed and abandoned in a loop. A capture-mode change resets
        /// the fallback by itself, so `reconfigure` keeps it too.
        var reprobesSinkCapture: Bool {
            switch self {
            case .configurationChange, .interruptionEnded, .mediaServicesReset, .appBecameActive, .userRequested:
                return true
            case .captureStall, .retry, .reconfigure:
                return false
            }
        }
    }

    enum Input: Equatable, Sendable {
        /// The initial start succeeded.
        case started(appActive: Bool)
        case stopped
        case appActiveChanged(Bool)
        /// The user asked to bring audio back ("Resume audio" in the app). An interruption that ended
        /// without `.ended` (another app kept the session, or iOS never told us) would otherwise leave
        /// audio paused while the user is looking at the app.
        case resumeRequested
        /// The scene became active again after something only covered it (Control Center, Siri, an
        /// alert), without the app going to the background. `appActiveChanged` sees no change then,
        /// but an interruption that began meanwhile may never deliver `.ended`: try like
        /// `resumeRequested`.
        case sceneReactivated
        /// The background time that keeps the process alive while audio I/O is down is nearly used
        /// up. A suspended process cannot retry, so a background recovery waits for the foreground.
        case backgroundTimeExhausted
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        /// `mediaServicesWereReset`: every audio object must be recreated.
        case mediaServicesReset
        /// `AVAudioEngineConfigurationChange` for the current engine (route or format change).
        case configurationChanged
        /// The watchdog saw no capture or render callbacks although the engine should be running.
        case captureStalled(recreateEngine: Bool)
        /// A setting that needs a rebuild changed (capture mode, voice processing).
        case reconfigure(recreateEngine: Bool)
        case attemptSucceeded
        case attemptFailed(AudioFailureKind)
        case retryTimerFired
    }

    enum Effect: Equatable, Sendable {
        /// Stop the engine (the interruption already stopped its I/O).
        case stopEngine
        /// Activate the session and rebuild and start the graph; report the result as an input.
        case attempt(Trigger, recreateEngine: Bool)
        case scheduleRetry(after: TimeInterval)
        case cancelRetry
        /// Run the capture watchdog now (the app came to the foreground while running).
        case checkHealth
        case stateChanged(State)
        case log(String)
    }

    /// Foreground retry delays: 0.25, 0.5, 1, 2, 4, then 5 s forever.
    static let retrySchedule = ReconnectBackoff.Schedule(delays: [0.25, 0.5, 1, 2, 4, 5], jitter: 0.1,
                                                         stableLinkDuration: .infinity)

    private(set) var state: State = .stopped
    private(set) var isAppActive = true
    private var backoff = ReconnectBackoff(schedule: AudioRecoveryMachine.retrySchedule)
    private var rng: SplitMix64
    /// A media services reset or a voice-processing change happened while no attempt could run.
    private var needsEngineRecreate = false

    init(rng: SplitMix64 = SplitMix64()) {
        self.rng = rng
    }

    mutating func handle(_ input: Input) -> [Effect] {
        switch input {
        case .started(let appActive):
            isAppActive = appActive
            backoff.reset()
            needsEngineRecreate = false
            return [.cancelRetry] + transition(to: .running)

        case .stopped:
            backoff.reset()
            needsEngineRecreate = false
            guard state != .stopped else { return [] }
            return [.cancelRetry] + transition(to: .stopped)

        case .appActiveChanged(let active):
            guard active != isAppActive else { return [] }
            isAppActive = active
            guard active else { return [] }
            switch state {
            case .stopped:
                return []
            case .running:
                return [.checkHealth]
            case .interrupted, .recovering, .needsForeground:
                // The user is here now: try at once, with a fresh backoff.
                backoff.reset()
                return [.cancelRetry] + beginAttempt(.appBecameActive)
            }

        case .resumeRequested, .sceneReactivated:
            switch state {
            case .stopped, .running:
                return []
            case .interrupted, .recovering, .needsForeground:
                backoff.reset()
                let isUser = input == .resumeRequested
                return [.cancelRetry, .log("audio \(isUser ? "resume requested" : "scene active again") while \(state)")]
                    + beginAttempt(isUser ? .userRequested : .appBecameActive)
            }

        case .backgroundTimeExhausted:
            guard !isAppActive, case .recovering = state else { return [] }
            return [.cancelRetry, .log("background time nearly used up while \(state); waiting for the foreground")]
                + transition(to: .needsForeground)

        case .interruptionBegan:
            guard state != .stopped else { return [] }
            guard state != .interrupted else { return [] }
            return [.cancelRetry, .stopEngine] + transition(to: .interrupted)

        case .interruptionEnded(let shouldResume):
            switch state {
            case .interrupted, .recovering, .needsForeground:
                // An intercom comes back on its own even when iOS does not suggest resuming.
                backoff.reset()
                return [.cancelRetry, .log("interruption ended (shouldResume \(shouldResume))")]
                    + beginAttempt(.interruptionEnded)
            case .running, .stopped:
                return [.log("interruption ended while \(state); nothing to do")]
            }

        case .mediaServicesReset:
            guard state != .stopped else { return [] }
            needsEngineRecreate = true
            switch state {
            case .interrupted:
                return [.log("media services reset while interrupted; engine recreated when it ends")]
            default:
                return [.cancelRetry] + beginAttempt(.mediaServicesReset)
            }

        case .configurationChanged:
            guard state == .running else {
                return [.log("configuration change ignored while \(state)")]
            }
            return beginAttempt(.configurationChange)

        case .captureStalled(let recreate):
            guard state == .running else { return [] }
            if recreate { needsEngineRecreate = true }
            return beginAttempt(.captureStall)

        case .reconfigure(let recreate):
            if recreate { needsEngineRecreate = true }
            guard state == .running else { return [] }
            return beginAttempt(.reconfigure)

        case .attemptSucceeded:
            guard state != .stopped else { return [] }
            backoff.reset()
            needsEngineRecreate = false
            return transition(to: .running)

        case .attemptFailed(let failure):
            guard state != .stopped else { return [] }
            if !isAppActive, failure.needsForegroundWhenInBackground {
                return [.cancelRetry, .log("audio cannot restart in the background (\(failure)); waiting for the foreground")]
                    + transition(to: .needsForeground)
            }
            let delay = backoff.nextDelay(using: &rng)
            let attempt = backoff.failures
            return [.scheduleRetry(after: delay),
                    .log("audio attempt failed (\(failure)); retry \(attempt) in \(String(format: "%.2f", delay)) s")]
                + transition(to: .recovering(attempt: attempt))

        case .retryTimerFired:
            guard case .recovering = state else { return [] }
            return beginAttempt(.retry)
        }
    }

    private mutating func beginAttempt(_ trigger: Trigger) -> [Effect] {
        var effects: [Effect] = []
        switch state {
        case .running, .recovering:
            // A rebuild while running keeps reporting `running`; a retry keeps its attempt number.
            break
        case .stopped, .interrupted, .needsForeground:
            effects += transition(to: .recovering(attempt: backoff.failures + 1))
        }
        effects.append(.attempt(trigger, recreateEngine: needsEngineRecreate))
        return effects
    }

    private mutating func transition(to newState: State) -> [Effect] {
        guard newState != state else { return [] }
        state = newState
        return [.stateChanged(newState)]
    }
}
