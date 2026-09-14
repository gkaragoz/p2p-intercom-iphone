import SwiftUI
import WidgetKit

/// Entry point of the widget extension. It only hosts the intercom Live Activity; the app has no
/// Home Screen widgets.
@main
struct IntercomLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        IntercomLiveActivityWidget()
    }
}
