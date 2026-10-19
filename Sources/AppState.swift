import AppKit
import Combine

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

    init() {
        menuBar.configure(with: self)
        hotkey.configure { [weak self] in
            self?.startRegionCapture()
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
        guard overlay == nil else { return }

        Task { @MainActor in
            // Small pause ensures no previous menu items interfere
            try? await Task.sleep(nanoseconds: 80_000_000)

            guard let (bgImage, screen) = await screenshotService.captureDisplay() else {
                self.menuBar.showError("Screen Recording permission required! Check System Settings.")
                return
            }

            self.overlay = ScreenshotOverlayController(
                backgroundImage: bgImage,
                screen: screen,
                onComplete: { [weak self] image, _ in
                    guard let self else { return }
                    self.overlay = nil
                    self.export(image)
                },
                onPin: { [weak self] image, rect in
                    guard let self else { return }
                    self.overlay = nil
                    self.pinToDesktop(image, origin: rect.origin)
                },
                onCancel: { [weak self] in
                    self?.overlay = nil
                }
            )
            self.overlay?.begin()
        }
    }

    private func export(_ image: NSImage) {
        var actions: [String] = []
        if settings.copyToClipboard {
            let ok = Clipboard.copy(image)
            actions.append(ok ? "Copied" : "Clipboard failed")
        }
        if settings.autoSave {
            let ok = FileStore.save(image, directory: settings.saveDirectory)
            actions.append(ok ? "Saved to \(settings.saveDirectory.lastPathComponent)" : "Save failed")
        }
        if !actions.isEmpty {
            self.menuBar.showTransient(actions.joined(separator: " & "))
        }
    }

    private func pinToDesktop(_ image: NSImage, origin: CGPoint) {
        let pinController = PinWindowController(image: image, at: origin)
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
