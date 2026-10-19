import AppKit
import ScreenCaptureKit

/// Screen capture via ScreenCaptureKit (macOS 14+).
@MainActor
final class ScreenshotService {
    private var permissionTimer: Timer?
    private var lastPermissionState: Bool?

    /// Captures full desktop image across the screen where the mouse currently is (pre-capture).
    func captureDisplay() async -> (CGImage, NSScreen)? {
        // 1. Detect screen containing the mouse cursor
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = Self.matchDisplay(for: screen, in: content.displays) else {
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

    /// Maps an `NSScreen` onto the matching `SCDisplay`.
    ///
    /// The screen number is the only reliable identifier; comparing the frame origin
    /// alone picks the wrong display for vertically stacked multi-monitor setups.
    private static func matchDisplay(for screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let match = displays.first(where: { $0.displayID == screenNumber.uint32Value }) {
            return match
        }

        let origin = screen.frame.origin
        let size = screen.frame.size
        return displays.first(where: { display in
            abs(display.frame.origin.x - origin.x) < 5
                && abs(display.frame.origin.y - origin.y) < 5
                && abs(display.frame.width - size.width) < 5
                && abs(display.frame.height - size.height) < 5
        }) ?? displays.first
    }

    /// Periodically checks Screen Recording permission so the menu reflects TCC state.
    func startPermissionPolling(callback: @escaping (Bool) -> Void) {
        lastPermissionState = nil
        checkPermission(callback)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermission(callback)
            }
        }
    }

    /// Only notifies the UI when the permission state actually changed.
    private func checkPermission(_ callback: @escaping (Bool) -> Void) {
        let granted = CGPreflightScreenCaptureAccess()
        guard granted != lastPermissionState else { return }
        lastPermissionState = granted
        callback(granted)
    }
}
