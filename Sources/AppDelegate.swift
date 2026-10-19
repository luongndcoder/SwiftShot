import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appState: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        appState.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar resident app: closing the editor window must not quit the app.
        return false
    }
}
