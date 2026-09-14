import Foundation
import os

/// Process-wide access to the one `IntercomController`, for code that runs without a SwiftUI view
/// hierarchy: Live Activity intents (their `perform()` runs in the app process, possibly after iOS
/// launched it in the background with no scene), and app lifecycle hooks.
///
/// `IntercomApp.init` creates the controller eagerly through `sharedController()`. A `@StateObject`
/// alone is created lazily when the first view needs it, which may never happen for a background launch.
@MainActor
enum IntercomRuntime {
    private(set) static var controller: IntercomController?
    /// Mirrors the controller into the Live Activity and performs the activity's intents.
    private(set) static var liveActivities: LiveActivityCoordinator?

    /// Returns the process's controller, creating and registering it on first use. Idempotent, so a
    /// second `App.init` (SwiftUI does not promise exactly one) never builds a second audio stack.
    static func sharedController() -> IntercomController {
        if let controller {
            Logger(subsystem: "intercom", category: "controller").notice("IntercomController already created; reusing it")
            return controller
        }
        let controller = IntercomController()
        self.controller = controller
        // Set before any intent can run: an intent that launches the app in the background reaches
        // `perform()` only after `App.init`. The coordinator calls the controller's idempotent controls
        // and then pushes the result to the activity while the intent is still running.
        let liveActivities = LiveActivityCoordinator(controller: controller)
        self.liveActivities = liveActivities
        IntercomIntentBridge.handler = liveActivities
        return controller
    }
}
