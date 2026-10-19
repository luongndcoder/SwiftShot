import AppKit

/// In-place floating text input field embedded directly inside the capture overlay.
final class InPlaceTextView: NSView, NSTextViewDelegate {
    private let textView = NSTextView()
    private let onCommit: (String, CGPoint) -> Void
    private let onCancel: () -> Void

    /// Height of the floating edit box.
    private static let boxHeight: CGFloat = 38

    init(
        at origin: CGPoint,
        textColor: NSColor,
        fontSize: CGFloat,
        onCommit: @escaping (String, CGPoint) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCommit = onCommit
        self.onCancel = onCancel

        let font = NSFont.boldSystemFont(ofSize: fontSize)
        // The text is committed as a CoreText line whose baseline sits on the anchor
        // point, so the edit box is positioned such that its first baseline lands
        // exactly on that point — the text does not jump when the box is dismissed.
        let frameY = origin.y - Self.boxHeight + font.ascender
        super.init(frame: NSRect(x: origin.x, y: frameY, width: 220, height: Self.boxHeight))

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 1

        textView.frame = bounds.insetBy(dx: 6, dy: 4)
        textView.autoresizingMask = [.width, .height]
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.font = font
        textView.insertionPointColor = textColor
        textView.isRichText = false
        textView.drawsBackground = false
        textView.delegate = self

        // Keep the text on a single line: the exported annotation is rendered as one
        // CoreText line, so a wrapped edit view would not match the saved result.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 4_000, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 0)

        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// The baseline of the first text line expressed in the parent view's coordinate
    /// space — this is where the committed annotation has to be drawn.
    func firstBaselinePoint() -> CGPoint? {
        guard let superview,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }

        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        // `NSTextView` is flipped, so the baseline sits `ascender` below the line top.
        let baselineInTextView = NSPoint(x: used.minX, y: used.minY + (textView.font?.ascender ?? 0))
        let inSelf = textView.convert(baselineInTextView, to: self)
        return convert(inSelf, to: superview)
    }

    func commit() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let baseline = firstBaselinePoint() ?? frame.origin
            onCommit(text, baseline)
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
