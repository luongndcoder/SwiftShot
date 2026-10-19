import AppKit

/// In-place floating text input field embedded directly inside the capture overlay.
final class InPlaceTextView: NSView, NSTextViewDelegate {
    private let textView = NSTextView()
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void

    init(
        at origin: CGPoint,
        textColor: NSColor,
        fontSize: CGFloat,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: NSRect(x: origin.x, y: origin.y - 10, width: 220, height: 38))

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 1

        textView.frame = bounds.insetBy(dx: 6, dy: 4)
        textView.autoresizingMask = [.width, .height]
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.font = NSFont.boldSystemFont(ofSize: fontSize)
        textView.insertionPointColor = textColor
        textView.isRichText = false
        textView.drawsBackground = false
        textView.delegate = self

        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func commit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            onCommit(text)
        } else {
            onCancel()
        }
        removeFromSuperview()
    }

    func cancel() {
        onCancel()
        removeFromSuperview()
    }

    // Capture Enter to commit, Esc to cancel
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }
}
