import SwiftUI

@main
struct IntercomApp: App {
    @StateObject private var controller = IntercomController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
        }
    }
}
