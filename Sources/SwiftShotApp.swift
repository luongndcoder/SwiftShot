import AppKit

/// SwiftShot is a menu-bar resident (`LSUIElement`) application, so it has no
/// window-based SwiftUI scene to declare — the settings panel is presented
/// imperatively by `MenuBarController` through an `NSHostingView`.
///
/// SwiftUI is therefore only used for that single panel, not for the app lifecycle.
@main
enum SwiftShotMain {
    /// `NSApplication.delegate` is a weak reference, so the delegate is kept alive here.
    private static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}
