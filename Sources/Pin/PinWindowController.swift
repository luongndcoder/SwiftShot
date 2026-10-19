import AppKit

/// Floating, always-on-top, draggable, zoomable window for pinning screenshots to desktop.
final class PinWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the pinned window is closed, so the owner can drop its reference.
    var onClosed: (() -> Void)?

    init(image: NSImage, at origin: CGPoint) {
        let initialSize = image.size
        let contentRect = NSRect(origin: origin, size: initialSize)

        let window = PinWindow(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        // The controller owns the window — closing it must not release it while the
        // window is still handling the event that triggered the close.
        window.isReleasedWhenClosed = false

        let view = PinImageView(image: image) { [weak window] in
            window?.close()
        }
        window.contentView = view

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Pin Window Custom Subclass

private final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc closes the pinned window
        if event.keyCode == 53 { // ESC
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Pin View with Hover Close Button & Zoom Support

private final class PinImageView: NSView {
    private let image: NSImage
    private let onClose: () -> Void
    private let closeButton: NSButton
    private var trackingAreaRef: NSTrackingArea?

    init(image: NSImage, onClose: @escaping () -> Void) {
        self.image = image
        self.onClose = onClose

        let closeBtn = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") ?? NSImage(), target: nil, action: nil)
        closeBtn.bezelStyle = .regularSquare
        closeBtn.isBordered = false
        closeBtn.contentTintColor = .white
        closeBtn.alphaValue = 0.0
        self.closeButton = closeBtn

        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor

        closeBtn.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
        closeBtn.autoresizingMask = [.minYMargin, .maxXMargin]
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        addSubview(closeBtn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.animator().alphaValue = 0.9
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.animator().alphaValue = 0.0
    }

    override func scrollWheel(with event: NSEvent) {
        // Zoom on Pinch / Scroll wheel
        guard let window = self.window else { return }
        let delta = event.deltaY
        guard abs(delta) > 0.05 else { return }

        let factor: CGFloat = delta > 0 ? 1.05 : 0.95
        let currentFrame = window.frame
        let newWidth = max(80, min(currentFrame.width * factor, 3000))
        let newHeight = max(60, min(currentFrame.height * factor, 2000))

        let mouseLocation = NSEvent.mouseLocation
        let newOriginX = mouseLocation.x - (mouseLocation.x - currentFrame.origin.x) * (newWidth / currentFrame.width)
        let newOriginY = mouseLocation.y - (mouseLocation.y - currentFrame.origin.y) * (newHeight / currentFrame.height)

        window.setFrame(NSRect(x: newOriginX, y: newOriginY, width: newWidth, height: newHeight), display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double click closes
            onClose()
        }
    }

    @objc private func closeTapped() {
        onClose()
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
    }
}
