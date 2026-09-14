import AppIntents
import Foundation
import os

// Buttons on the Live Activity. The types are compiled into both targets: the extension needs them
// to build `Button(intent:)`, the app needs them to run. Conforming to `LiveActivityIntent` makes iOS
// run `perform()` in the *app's* process (launching it in the background if needed), so the intents
// reach the live `IntercomController` directly, without App Groups (which free teams cannot use).
//
// Every intent carries an explicit target value, never "toggle": a Lock Screen that shows stale state,
// or a double tap, must not invert what the person asked for. They are not discoverable in Shortcuts
// or Siri; they only make sense as buttons on a running session.

/// What a Live Activity button asks the app to do.
enum IntercomIntentCommand: Sendable, Equatable, CustomStringConvertible {
    case setMuted(Bool)
    case setTransmitMode(ActivityTransmitMode)
    case setTalkLatched(Bool)

    var description: String {
        switch self {
        case .setMuted(let muted): return "setMuted(\(muted))"
        case .setTransmitMode(let mode): return "setTransmitMode(\(mode.rawValue))"
        case .setTalkLatched(let latched): return "setTalkLatched(\(latched))"
        }
    }
}

/// Implemented by the app; performs a command and refreshes the Live Activity.
@MainActor
protocol IntercomIntentHandler: AnyObject {
    func handle(_ command: IntercomIntentCommand) async
}

/// Where intents find the app. The app sets `handler` while it creates its controller (before any
/// intent can run); in the extension it stays `nil`, and `perform()` never runs there anyway.
@MainActor
enum IntercomIntentBridge {
    static var handler: IntercomIntentHandler?

    private static let log = Logger(subsystem: "intercom", category: "liveactivity.intent")

    static func perform(_ command: IntercomIntentCommand) async {
        guard let handler else {
            log.error("intent \(command.description, privacy: .public) dropped: no handler in this process (\(Bundle.main.bundleIdentifier ?? "?", privacy: .public))")
            return
        }
        log.notice("intent \(command.description, privacy: .public)")
        await handler.handle(command)
    }
}

struct SetMutedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute Microphone"
    static let description = IntentDescription("Mutes or unmutes your microphone in Intercom.")
    static let isDiscoverable = false

    @Parameter(title: "Muted")
    var muted: Bool

    init() {}

    init(muted: Bool) {
        self.muted = muted
    }

    func perform() async throws -> some IntentResult {
        await IntercomIntentBridge.perform(.setMuted(muted))
        return .result()
    }
}

struct SetTransmitModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Transmit Mode"
    static let description = IntentDescription("Chooses how Intercom sends your voice.")
    static let isDiscoverable = false

    @Parameter(title: "Mode")
    var mode: ActivityTransmitMode

    init() {}

    init(mode: ActivityTransmitMode) {
        self.mode = mode
    }

    func perform() async throws -> some IntentResult {
        await IntercomIntentBridge.perform(.setTransmitMode(mode))
        return .result()
    }
}

struct SetTalkLatchIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Latch Push to Talk"
    static let description = IntentDescription("Keeps push to talk on without holding the button, for up to a minute.")
    static let isDiscoverable = false

    @Parameter(title: "On")
    var on: Bool

    init() {}

    init(on: Bool) {
        self.on = on
    }

    func perform() async throws -> some IntentResult {
        await IntercomIntentBridge.perform(.setTalkLatched(on))
        return .result()
    }
}

extension ActivityTransmitMode: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transmit Mode"
    static let caseDisplayRepresentations: [ActivityTransmitMode: DisplayRepresentation] = [
        .pushToTalk: "Push to talk",
        .voiceActivated: "Voice activated",
        .alwaysOn: "Open mic",
    ]
}
