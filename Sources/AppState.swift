import AppKit
import Combine

/// What the user explicitly asked to do with a finished capture.
enum CaptureAction {
    case copy
    case save
}

/// Orchestrates the entire Flameshot-style capture workflow:
/// Hotkey / Menu -> Pre-capture background snapshot -> In-place Unified Overlay (HUD + drawing + handles)
/// -> Direct Copy / Save / Pin (zero separate editor window needed!).
@MainActor
final class AppState: ObservableObject {
    let settings = Settings()
    let hotkey = HotkeyManager()
    let menuBar = MenuBarController()
    private let screenshotService = ScreenshotService()

    private var overlay: ScreenshotOverlayController?
    private var pinnedWindows: [PinWindowController] = []
    /// Guards against a second capture being started while one is in flight
    /// (the guard has to be checked *after* the async capture, not before).
    private var isCapturing = false

    init() {
        menuBar.configure(with: self)
        hotkey.configure { [weak self] in
            self?.startRegionCapture()
        }
        hotkey.onRegistrationError = { [weak self] message in
            Task { @MainActor in
                self?.menuBar.showError(message)
            }
        }
        hotkey.bind(settings: settings)
    }

    func start() {
        menuBar.installStatusItem()
        screenshotService.startPermissionPolling { [weak self] granted in
            self?.menuBar.updatePermissionStatus(granted)
        }
    }

    // MARK: - Capture Workflow

    func startRegionCapture() {
        guard !isCapturing, overlay == nil else { return }
        isCapturing = true

        Task { @MainActor in
            // Small pause ensures no previous menu items interfere
            try? await Task.sleep(nanoseconds: 80_000_000)

            guard let (bgImage, screen) = await screenshotService.captureDisplay() else {
                self.isCapturing = false
                self.menuBar.showError("Screen Recording permission required! Check System Settings.")
                return
            }

            self.overlay = ScreenshotOverlayController(
                backgroundImage: bgImage,
                screen: screen,
                initialColor: self.settings.defaultColor,
                initialStrokeWidth: self.settings.strokeWidth,
                onComplete: { [weak self] image, _, action in
                    guard let self else { return }
                    self.isCapturing = false
                    self.overlay = nil
                    self.export(image, action: action)
                },
                onPin: { [weak self] image, rect in
                    guard let self else { return }
                    self.isCapturing = false
                    self.overlay = nil
                    self.pinToDesktop(image, origin: rect.origin)
                },
                onCancel: { [weak self] in
                    self?.isCapturing = false
                    self?.overlay = nil
                }
            )
            self.overlay?.begin()
        }
    }

    /// Performs the requested action and applies the automatic preferences,
    /// without running the same action twice.
    private func export(_ image: NSImage, action: CaptureAction) {
        var messages: [String] = []
        var copied = false
        var saved = false

        switch action {
        case .copy:
            copied = true
            messages.append(Clipboard.copy(image) ? "Copied" : "Clipboard failed")
        case .save:
            saved = true
            let ok = FileStore.save(image, directory: settings.saveDirectory)
            messages.append(ok ? "Saved to \(settings.saveDirectory.lastPathComponent)" : "Save failed")
        }

        if !copied, settings.copyToClipboard {
            messages.append(Clipboard.copy(image) ? "Copied" : "Clipboard failed")
        }
        if !saved, settings.autoSave {
            let ok = FileStore.save(image, directory: settings.saveDirectory)
            messages.append(ok ? "Saved to \(settings.saveDirectory.lastPathComponent)" : "Save failed")
        }

        if !messages.isEmpty {
            self.menuBar.showTransient(messages.joined(separator: " & "))
        }
    }

    private func pinToDesktop(_ image: NSImage, origin: CGPoint) {
        let pinController = PinWindowController(image: image, at: origin)
        pinController.onClosed = { [weak self, weak pinController] in
            guard let self, let pinController else { return }
            // Deferred: the close happens while the pinned window is still
            // executing its own event handler.
            DispatchQueue.main.async {
                self.pinnedWindows.removeAll { $0 === pinController }
            }
        }
        pinController.show()
        pinnedWindows.append(pinController)
        menuBar.showTransient("Pinned to Screen")
    }

    func openSettings() {
        menuBar.openSettings()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
