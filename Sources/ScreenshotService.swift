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

    /// Resolves the screen under the mouse cursor and its matching `SCDisplay`
    /// without capturing anything — used to start a screen recording.
    func screenAndDisplayAtMouse() async -> (screen: NSScreen, display: SCDisplay)? {
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
            return (screen, display)
        } catch {
            NSLog("[SwiftShot] screenAndDisplayAtMouse failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Captures a screen (or a region of it) without any user interaction.
    ///
    /// Used by the MCP bridge so that AI agents can take screenshots through the
    /// running app — and therefore through its Screen Recording permission.
    ///
    /// - Parameters:
    ///   - region: optional region in **global screen points** (origin bottom-left,
    ///     same coordinate system as `NSScreen.frame`).
    ///   - displayID: optional `NSScreenNumber` of the display to capture.
    func capture(region: CGRect?, displayID: Int?) async throws -> (image: CGImage, sizeInPoints: CGSize, scale: CGFloat) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw BridgeError.noScreen }

        // Pick the display: by id, else the one containing the region, else the main one.
        let target: NSScreen
        if let displayID, let match = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == displayID
        }) {
            target = match
        } else if let region, let match = screens.first(where: { $0.frame.intersects(region) }) {
            target = match
        } else {
            target = NSScreen.main ?? screens[0]
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = Self.matchDisplay(for: target, in: content.displays) else {
            throw BridgeError.noDisplay
        }

        let scale = target.backingScaleFactor
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * scale)
        config.height = Int(target.frame.height * scale)
        config.scalesToFit = false
        config.showsCursor = false

        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        guard let region else {
            return (full, target.frame.size, scale)
        }

        // Convert the global region into the display's local pixel coordinates.
        let local = region.offsetBy(dx: -target.frame.origin.x, dy: -target.frame.origin.y)
            .intersection(CGRect(origin: .zero, size: target.frame.size))
        guard !local.isEmpty else { throw BridgeError.emptyRegion }

        let pixelRect = CGRect(
            x: (local.origin.x * scale).rounded(),
            // The bitmap is top-left based.
            y: ((target.frame.height - local.maxY) * scale).rounded(),
            width: (local.width * scale).rounded(),
            height: (local.height * scale).rounded()
        )
        guard let cropped = full.cropping(to: pixelRect) else { throw BridgeError.cropFailed }

        return (cropped, local.size, scale)
    }

    enum BridgeError: LocalizedError {
        case noScreen
        case noDisplay
        case emptyRegion
        case cropFailed

        var errorDescription: String? {
            switch self {
            case .noScreen: return "No screen available"
            case .noDisplay: return "The display could not be found"
            case .emptyRegion: return "The requested region is outside of the screen"
            case .cropFailed: return "The captured image could not be cropped"
            }
        }
    }

    /// Maps an `NSScreen` onto the matching `SCDisplay`.
    ///
    /// The screen number is the only reliable identifier; comparing the frame origin
    /// alone picks the wrong display for vertically stacked multi-monitor setups.
    static func matchDisplay(for screen: NSScreen, in displays: [SCDisplay]) -> SCDisplay? {
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
