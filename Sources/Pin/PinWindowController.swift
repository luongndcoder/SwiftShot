import AppKit

/// Floating, always-on-top, draggable, zoomable window for pinning screenshots to desktop.
final class PinWindowController: NSWindowController {
    private let pinnedImage: NSImage
    private var currentScale: CGFloat = 1.0

    init(image: NSImage, at origin: CGPoint) {
        self.pinnedImage = image

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

        let view = PinImageView(image: image) { [weak window] in
            window?.orderOut(nil)
        }
        window.contentView = view

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
            orderOut(nil)
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
