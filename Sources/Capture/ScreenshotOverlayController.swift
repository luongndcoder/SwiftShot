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
    private var onComplete: (NSImage, CGRect) -> Void
    private var onPin: (NSImage, CGRect) -> Void
    private var onCancel: () -> Void

    init(
        backgroundImage: CGImage,
        screen: NSScreen,
        onComplete: @escaping (NSImage, CGRect) -> Void,
        onPin: @escaping (NSImage, CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onPin = onPin
        self.onCancel = onCancel

        let overlayView = UnifiedOverlayView(
            backgroundImage: backgroundImage,
            screenFrame: screen.frame,
            onFinishCapture: { [weak self] image, rect in
                self?.finish(image: image, rect: rect)
            },
            onPinCapture: { [weak self] image, rect in
                self?.pin(image: image, rect: rect)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

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
        overlayWindow.contentView = overlayView

        self.window = overlayWindow

        // Install local key monitor to ensure Esc always cancels regardless of focus
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak overlayView] event in
            // If active text input is focused, let it receive typing, Enter, and Esc
            if overlayView?.window?.firstResponder is NSTextView {
                return event
            }

            if event.keyCode == 53 { // kVK_Escape
                self?.cancel()
                return nil
            }
            // Pass other keys to overlay view
            if let view = overlayView, view.window?.isKeyWindow == true {
                view.keyDown(with: event)
                return nil
            }
            return event
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
        window?.orderOut(nil)
        window = nil
    }

    private func finish(image: NSImage, rect: CGRect) {
        close()
        onComplete(image, rect)
    }

    private func pin(image: NSImage, rect: CGRect) {
        close()
        onPin(image, rect)
    }

    private func cancel() {
        close()
        onCancel()
    }
}
