import SwiftUI

@main
struct SwiftShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu-bar resident app (LSUIElement = true in Info.plist).
        // Settings window is opened imperatively via MenuBarController.
        SwiftUI.Settings {
            EmptyView()
        }
    }
}
