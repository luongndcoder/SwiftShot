import AppKit
import ScreenCaptureKit

/// Screen capture via ScreenCaptureKit (macOS 14+).
@MainActor
final class ScreenshotService {
    private var permissionTimer: Timer?

    /// Captures full desktop image across the screen where the mouse currently is (pre-capture).
    func captureDisplay() async -> (CGImage, NSScreen)? {
        // 1. Detect screen containing the mouse cursor
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: {
                // Find matching display by origin or intersection
                abs($0.frame.origin.x - screen.frame.origin.x) < 5
            }) ?? content.displays.first else {
                return nil
            }

            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            // Request native pixel resolution (points * backingScaleFactor) for 100% crispness
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.scalesToFit = false
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, screen)
        } catch {
            NSLog("[SwiftShot] captureDisplay failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Periodically checks Screen Recording permission so the menu reflects TCC state.
    func startPermissionPolling(callback: @escaping (Bool) -> Void) {
        checkPermission(callback)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermission(callback)
            }
        }
    }

    private func checkPermission(_ callback: @escaping (Bool) -> Void) {
        let granted = CGPreflightScreenCaptureAccess()
        callback(granted)
    }
}
