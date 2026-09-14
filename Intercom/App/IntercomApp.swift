import SwiftUI

@main
struct IntercomApp: App {
    @StateObject private var controller: IntercomController
    /// At the App level this is the aggregate of all scenes: active if any scene is active, background
    /// only when every scene is.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Created eagerly (not lazily by `@StateObject`) so intents and lifecycle notifications find it
        // even when iOS launches the app in the background without building any view.
        let controller = IntercomRuntime.sharedController()
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                controller.sceneDidBecomeActive()
            case .inactive:
                controller.sceneDidBecomeInactive()
            case .background:
                controller.sceneDidEnterBackground()
            @unknown default:
                controller.sceneDidBecomeInactive()
            }
        }
    }
}
