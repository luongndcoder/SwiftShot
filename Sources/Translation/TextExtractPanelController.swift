import AppKit
import SwiftUI

/// Floating borderless glass panel supporting Esc dismissal and key status.
private final class FloatingGlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Floating panel controller for inspecting and copying extracted OCR text.
final class TextExtractPanelController: NSWindowController, NSWindowDelegate {
    var onClosed: (() -> Void)?
    var onToggleHighlight: ((Bool) -> Void)?

    private var currentOCR: OCRResult?
    private var isLoading: Bool = false
    private var errorMessage: String?

    init(ocr: OCRResult?, at origin: CGPoint) {
        self.currentOCR = ocr

        let panel = FloatingGlassPanel(
            contentRect: NSRect(origin: origin, size: CGSize(width: 440, height: 380)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        super.init(window: panel)
        panel.delegate = self
        updateHostingView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }

    func update(ocr: OCRResult) {
        self.currentOCR = ocr
        self.isLoading = false
        self.errorMessage = nil
        updateHostingView()
    }

    func setError(_ message: String) {
        self.isLoading = false
        self.errorMessage = message
        updateHostingView()
    }

    func setLoading(_ loading: Bool) {
        self.isLoading = loading
        updateHostingView()
    }

    private func updateHostingView() {
        let full = currentOCR?.fullText ?? ""
        let blocks = currentOCR?.blocks ?? []

        let contentView = TextExtractPanelView(
            fullText: full,
            blocks: blocks,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onCopyAll: {
                if !full.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(full, forType: .string)
                }
            },
            onCopySelected: { selectedTexts in
                let joined = selectedTexts.joined(separator: "\n")
                if !joined.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(joined, forType: .string)
                }
            },
            onToggleCanvasHighlight: { [weak self] enabled in
                self?.onToggleHighlight?(enabled)
            },
            onClose: { [weak self] in
                self?.closePanel()
            }
        )

        let hosting = NSHostingView(rootView: contentView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        window?.contentView = hosting
    }
}
