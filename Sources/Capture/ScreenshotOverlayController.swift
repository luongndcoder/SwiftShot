import AppKit

/// Borderless fullscreen window that guarantees key window status for keyboard events.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Presents fullscreen transparent borderless overlay for in-place Flameshot capture.
final class ScreenshotOverlayController {
    private var window: NSWindow?
    private var eventMonitor: Any?
    private var onComplete: (NSImage, CGRect, CaptureAction) -> Void
    private var onPin: (NSImage, CGRect) -> Void
    private var onCancel: (CGRect?) -> Void
    private var onRegionPicked: ((CGRect) -> Void)?

    init(
        backgroundImage: CGImage,
        screen: NSScreen,
        initialColor: NSColor = .systemRed,
        initialStrokeWidth: CGFloat = 3,
        initialSelection: CGRect? = nil,
        colorPresets: [NSColor] = [],
        dimOpacity: Double = 0.35,
        showMagnifier: Bool = true,
        copyOnDoubleClick: Bool = true,
        settings: Settings = Settings(),
        onComplete: @escaping (NSImage, CGRect, CaptureAction) -> Void,
        onPin: @escaping (NSImage, CGRect) -> Void,
        onCancel: @escaping (CGRect?) -> Void,
        onAddColorPreset: ((NSColor) -> Void)? = nil,
        onRegionPicked: ((CGRect) -> Void)? = nil
    ) {
        self.onComplete = onComplete
        self.onPin = onPin
        self.onCancel = onCancel
        self.onRegionPicked = onRegionPicked

        let overlayView = UnifiedOverlayView(
            backgroundImage: backgroundImage,
            screenFrame: screen.frame,
            initialColor: initialColor,
            initialStrokeWidth: initialStrokeWidth,
            initialSelection: initialSelection,
            colorPresets: colorPresets,
            dimOpacity: dimOpacity,
            showMagnifier: showMagnifier,
            copyOnDoubleClick: copyOnDoubleClick,
            onFinishCapture: { [weak self] image, rect, action in
                self?.finish(image: image, rect: rect, action: action)
            },
            onPinCapture: { [weak self] image, rect in
                self?.pin(image: image, rect: rect)
            },
            onCancel: { [weak self] rect in
                self?.cancel(rect: rect)
            }
        )
        overlayView.onAddColorPreset = onAddColorPreset
        overlayView.settings = settings
        if onRegionPicked != nil {
            overlayView.onRegionPicked = { [weak self] rect in
                self?.regionPicked(rect)
            }
        }

        let overlayWindow = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayWindow.level = .screenSaver
        overlayWindow.backgroundColor = .clear
        overlayWindow.isOpaque = false
        overlayWindow.ignoresMouseEvents = false
        overlayWindow.acceptsMouseMovedEvents = true
        overlayWindow.hasShadow = false
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // The controller owns the window strongly, so closing it must not send
        // an extra release under ARC.
        overlayWindow.isReleasedWhenClosed = false
        // Keep AppKit from keeping the closed window (and its full-screen
        // drawable) in the window-restoration registry.
        overlayWindow.isRestorable = false
        overlayWindow.identifier = nil
        // The XDR display makes AppKit back windows with half-float (8 bytes
        // per pixel) surfaces — 59 MB for this screen size. The overlay only
        // previews a screenshot, so an sRGB backing store is enough and halves
        // the drawable the window keeps around.
        overlayWindow.colorSpace = .sRGB
        overlayWindow.contentView = overlayView

        self.window = overlayWindow

        // Install local key monitor to ensure Esc always cancels regardless of focus
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak overlayView] event in
            // Only intercept while the overlay is the key window — otherwise other
            // windows (e.g. the colour panel) would not receive their key events.
            guard let view = overlayView, view.window?.isKeyWindow == true else { return event }

            // If active text input is focused, let it receive typing, Enter, and Esc
            if view.window?.firstResponder is NSTextView {
                return event
            }

            if event.keyCode == 53 { // kVK_Escape
                self?.cancel(rect: view.currentSelection)
                return nil
            }

            view.keyDown(with: event)
            return nil
        }
    }

    func begin() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        guard let closingWindow = window else { return }
        window = nil

        // `close()` is called from the overlay's own event handling (mouse and
        // key callbacks), so the window — and with it the content view whose
        // method is still on the stack — must outlive this call. Only the colour
        // panel link is cut right away; the rest is torn down on the next turn.
        (closingWindow.contentView as? UnifiedOverlayView)?.detachSharedColorPanel()
        // The shared colour panel is raised above the overlay — restore its level.
        NSColorPanel.shared.level = .normal
        closingWindow.orderOut(nil)

        DispatchQueue.main.async {
            // Dropping the view releases the full-screen snapshot and the
            // Retina backing store the overlay was drawn on.
            closingWindow.contentView = nil
            closingWindow.close()
        }
    }

    private func finish(image: NSImage, rect: CGRect, action: CaptureAction) {
        close()
        onComplete(image, rect, action)
    }

    private func pin(image: NSImage, rect: CGRect) {
        close()
        onPin(image, rect)
    }

    private func cancel(rect: CGRect?) {
        close()
        onCancel(rect)
    }

    private func regionPicked(_ rect: CGRect) {
        close()
        onRegionPicked?(rect)
    }
}
