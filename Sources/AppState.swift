import AppKit
import Combine

/// What the user explicitly asked to do with a finished capture.
enum CaptureAction {
    case copy
    case save
    case saveAs
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
    /// The screen the current capture belongs to (needed to map the selection
    /// rectangle between view and screen coordinates).
    private var currentScreen: NSScreen?

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
            self.currentScreen = screen

            // The last selection is stored in screen coordinates; the overlay works
            // in the coordinates of the screen it covers.
            var initialSelection: CGRect?
            if self.settings.useLastRegion, let last = self.settings.lastRegion {
                let inView = last.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)
                if !inView.isEmpty {
                    initialSelection = inView
                }
            }

            self.overlay = ScreenshotOverlayController(
                backgroundImage: bgImage,
                screen: screen,
                initialColor: self.settings.defaultColor,
                initialStrokeWidth: self.settings.strokeWidth,
                initialSelection: initialSelection,
                colorPresets: self.settings.customColors,
                dimOpacity: self.settings.selectionOpacity,
                showMagnifier: self.settings.showMagnifier,
                copyOnDoubleClick: self.settings.copyOnDoubleClick,
                onComplete: { [weak self] image, rect, action in
                    guard let self else { return }
                    self.isCapturing = false
                    self.overlay = nil
                    self.rememberSelection(rect)
                    self.export(image, action: action)
                },
                onPin: { [weak self] image, rect in
                    guard let self else { return }
                    self.isCapturing = false
                    self.overlay = nil
                    self.rememberSelection(rect)
                    self.pinToDesktop(image, origin: rect.origin)
                },
                onCancel: { [weak self] rect in
                    self?.isCapturing = false
                    self?.overlay = nil
                    if let rect { self?.rememberSelection(rect) }
                },
                onAddColorPreset: { [weak self] color in
                    self?.addColorPreset(color)
                }
            )
            self.overlay?.begin()
        }
    }

    /// Stores the selection so the next capture can reuse it.
    private func rememberSelection(_ rect: CGRect) {
        guard settings.useLastRegion, let screen = currentScreen else { return }
        let inScreen = rect.offsetBy(dx: screen.frame.origin.x, dy: screen.frame.origin.y)
        settings.lastRegion = inScreen
    }

    private func addColorPreset(_ color: NSColor) {
        // Avoid storing the same colour twice.
        let isDuplicate = settings.customColors.contains { existing in
            let sameRed = abs(existing.redComponent - color.redComponent) < 0.01
            let sameGreen = abs(existing.greenComponent - color.greenComponent) < 0.01
            let sameBlue = abs(existing.blueComponent - color.blueComponent) < 0.01
            return sameRed && sameGreen && sameBlue
        }
        guard !isDuplicate else {
            menuBar.showTransient("Color already in palette")
            return
        }
        settings.customColors.append(color)
        menuBar.showTransient("Color added to palette")
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
            if settings.askWhereToSave {
                if let url = self.saveAs(image) {
                    messages.append("Saved to \(url.lastPathComponent)")
                } else {
                    messages.append("Save cancelled")
                }
            } else {
                let url = FileStore.save(
                    image,
                    directory: settings.saveDirectory,
                    format: settings.saveFormat,
                    quality: settings.jpegQuality
                )
                messages.append(self.describeSave(url))
            }
        case .saveAs:
            saved = true
            let url = self.saveAs(image)
            if let url {
                messages.append("Saved to \(url.lastPathComponent)")
            } else {
                messages.append("Save cancelled")
            }
        }

        if !copied, settings.copyToClipboard {
            messages.append(Clipboard.copy(image) ? "Copied" : "Clipboard failed")
        }
        if !saved, settings.autoSave {
            let url = FileStore.save(
                image,
                directory: settings.saveDirectory,
                format: settings.saveFormat,
                quality: settings.jpegQuality
            )
            messages.append(self.describeSave(url))
        }

        if !messages.isEmpty {
            self.menuBar.showTransient(messages.joined(separator: " & "))
        }
    }

    private func describeSave(_ url: URL?) -> String {
        guard let url else { return "Save failed" }
        if settings.copyPathAfterSave {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
            return "Saved to \(url.lastPathComponent) (path copied)"
        }
        return "Saved to \(url.lastPathComponent)"
    }

    /// Shows the save panel so the user can pick the name, folder and format.
    private func saveAs(_ image: NSImage) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.nameFieldStringValue = "\(FileStore.timestampedName()).\(settings.saveFormat.fileExtension)"
        panel.allowedContentTypes = [settings.saveFormat.utType]
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let format = SaveFormat.allCases.first {
            url.pathExtension.lowercased().hasPrefix($0.fileExtension)
        } ?? settings.saveFormat

        guard FileStore.write(image, to: url, format: format, quality: settings.jpegQuality) else {
            menuBar.showError("Could not write \(url.lastPathComponent)")
            return nil
        }
        if settings.copyPathAfterSave {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        }
        return url
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
