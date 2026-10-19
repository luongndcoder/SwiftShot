import AppKit

/// Floating text input window for the Text annotation tool.
final class TextInputWindow: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var onComplete: (String) -> Void
    private var onCancel: () -> Void

    init(at point: CGPoint, onComplete: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        super.init()
        let panel = NSWindow(
            contentRect: NSRect(x: point.x, y: point.y, width: 280, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = NSColor.clear
        panel.isOpaque = false
        panel.hasShadow = true

        let container = NSView(frame: panel.contentView!.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 6
        container.autoresizingMask = [.width, .height]

        let textField = NSTextField(frame: container.bounds.insetBy(dx: 8, dy: 4))
        textField.autoresizingMask = [.width, .height]
        textField.isEditable = true
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.font = NSFont.systemFont(ofSize: 14)
        textField.delegate = self
        container.addSubview(textField)

        panel.contentView = container
        window = panel
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView?.subviews.first)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        window?.orderOut(nil)
    }
}

extension TextInputWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        if let textField = obj.object as? NSTextField, let action = obj.userInfo?["NSTextMovement"] as? Int {
            let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            window?.orderOut(nil)
            if action == NSReturnTextMovement {
                onComplete(text)
            } else {
                onCancel()
            }
        }
    }
}
