import AppKit
import Combine
import ScreenCaptureKit

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
    /// The single application instance — used by the MCP bridge.
    static private(set) var shared: AppState?

    let settings = Settings()
    let hotkey = HotkeyManager()
    let menuBar = MenuBarController()
    let screenshotService = ScreenshotService()
    let recorder = ScreenRecorder()

    private var overlay: ScreenshotOverlayController?
    private var pinnedWindows: [PinWindowController] = []
    /// Guards against a second capture being started while one is in flight
    /// (the guard has to be checked *after* the async capture, not before).
    private var isCapturing = false
    /// The screen the current capture belongs to (needed to map the selection
    /// rectangle between view and screen coordinates).
    private var currentScreen: NSScreen?

    init() {
        AppState.shared = self
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

        recorder.onRecordingChanged = { [weak self] recording in
            self?.menuBar.setRecording(recording)
        }
        recorder.onFinished = { [weak self] url in
            guard let self else { return }
            if self.settings.copyPathAfterSave {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.path, forType: .string)
                self.menuBar.showTransient("Recording saved (path copied)")
            } else {
                self.menuBar.showTransient("Recording saved to \(url.lastPathComponent)")
            }
        }
        recorder.onError = { [weak self] message in
            self?.menuBar.showError(message)
        }
    }

    /// Whether a screen recording is currently running (drives the menu).
    var isRecordingNow: Bool { recorder.isRecording }
    /// When the current recording started (drives the menu's elapsed timer).
    var recordingStartedAt: Date? { recorder.startedAt }

    func start() {
        menuBar.installStatusItem()
        SwiftShotBridge.shared.start()
        screenshotService.startPermissionPolling { [weak self] granted in
            self?.menuBar.updatePermissionStatus(granted)
        }
    }

    // MARK: - Capture Workflow

    func startRegionCapture() {
        if recorder.isRecording {
            menuBar.showTransient("Stop the recording before capturing")
            return
        }
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

    // MARK: - Screen Recording

    /// Records the whole display under the mouse cursor.
    func startFullScreenRecording() {
        guard !recorder.isRecording, !isCapturing, overlay == nil else { return }

        Task { @MainActor in
            // Small pause ensures no previous menu items interfere
            try? await Task.sleep(nanoseconds: 80_000_000)

            guard let (screen, display) = await screenshotService.screenAndDisplayAtMouse() else {
                self.menuBar.showError("Screen Recording permission required! Check System Settings.")
                return
            }
            self.beginRecording(screen: screen, display: display, region: nil)
        }
    }

    /// Lets the user drag a region with the capture overlay, then records
    /// exactly that region of the display.
    func startRegionRecordingPicker() {
        guard !recorder.isRecording, !isCapturing, overlay == nil else { return }
        isCapturing = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)

            guard let (bgImage, screen) = await screenshotService.captureDisplay() else {
                self.isCapturing = false
                self.menuBar.showError("Screen Recording permission required! Check System Settings.")
                return
            }
            self.currentScreen = screen

            self.overlay = ScreenshotOverlayController(
                backgroundImage: bgImage,
                screen: screen,
                onComplete: { _, _, _ in },
                onPin: { _, _ in },
                onCancel: { [weak self] _ in
                    self?.isCapturing = false
                    self?.overlay = nil
                },
                onRegionPicked: { [weak self] rect in
                    guard let self else { return }
                    self.isCapturing = false
                    self.overlay = nil
                    // The picked rect is local to the picker's screen; the
                    // mouse is still on that screen, so resolving the display
                    // at the mouse targets the same display.
                    Task { @MainActor in
                        guard let (recordScreen, display) = await self.screenshotService.screenAndDisplayAtMouse() else {
                            self.menuBar.showError("Could not find the display to record")
                            return
                        }
                        self.beginRecording(screen: recordScreen, display: display, region: rect)
                    }
                }
            )
            self.overlay?.begin()
        }
    }

    func stopRecording() {
        Task { @MainActor in
            await recorder.stop()
        }
    }

    private func beginRecording(screen: NSScreen, display: SCDisplay, region: CGRect?) {
        let baseName = FileStore.timestampedName()
        var outputURL = settings.saveDirectory.appendingPathComponent("\(baseName).mp4")
        var counter = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = settings.saveDirectory.appendingPathComponent("\(baseName)_\(counter).mp4")
            counter += 1
        }

        Task { @MainActor in
            do {
                try await recorder.start(
                    display: display,
                    displayPointSize: screen.frame.size,
                    scale: screen.backingScaleFactor,
                    region: region,
                    includeAudio: settings.recordSystemAudio,
                    outputURL: outputURL
                )
            } catch {
                self.menuBar.showError("Could not start recording: \(error.localizedDescription)")
            }
        }
    }

    func openSettings() {
        menuBar.openSettings()
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
