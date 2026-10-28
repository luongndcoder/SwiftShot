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

/// Floating panel controller displaying OCR and translation results.
final class TranslationPanelController: NSWindowController, NSWindowDelegate {
    var onClosed: (() -> Void)?
    var onToggleOverlay: ((TranslationResult?) -> Void)?

    private var currentResult: TranslationResult?
    private var currentOCR: OCRResult?
    private var targetLang: String
    private var isOverlayActive: Bool = false
    private var isLoading: Bool = false
    private var errorMessage: String?

    private let settings: Settings

    init(ocr: OCRResult, initialResult: TranslationResult?, settings: Settings, at origin: CGPoint) {
        self.currentOCR = ocr
        self.currentResult = initialResult
        self.settings = settings
        self.targetLang = settings.translationTargetLanguage

        let panel = FloatingGlassPanel(
            contentRect: NSRect(origin: origin, size: CGSize(width: 420, height: 360)),
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

    func update(result: TranslationResult) {
        self.currentResult = result
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

    // MARK: - View update

    private func updateHostingView() {
        let bindingTarget = Binding<String>(
            get: { self.targetLang },
            set: { self.targetLang = $0 }
        )

        let orig = currentResult?.originalFullText ?? currentOCR?.fullText ?? ""
        let trans = currentResult?.translatedFullText ?? ""
        let detected = currentResult?.sourceLanguage ?? "auto"
        let provName = currentResult?.provider.displayName ?? settings.translationProvider.displayName

        let contentView = TranslationPanelView(
            originalText: orig,
            translatedText: trans,
            detectedSourceLang: detected,
            targetLang: bindingTarget,
            providerName: provName,
            isLoading: isLoading,
            errorMessage: errorMessage,
            isOverlayApplied: isOverlayActive,
            onRetranslate: { [weak self] newLang in
                self?.retranslate(to: newLang)
            },
            onToggleOverlay: { [weak self] in
                guard let self else { return }
                self.isOverlayActive.toggle()
                self.onToggleOverlay?(self.isOverlayActive ? self.currentResult : nil)
                self.updateHostingView()
            },
            onCopyTranslation: { [weak self] in
                guard let self else { return }
                let textToCopy = self.currentResult?.translatedFullText ?? ""
                if !textToCopy.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textToCopy, forType: .string)
                }
                self.closePanel()
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

    private func retranslate(to newLang: String) {
        guard let ocr = currentOCR else { return }
        setLoading(true)

        Task {
            do {
                let res = try await TranslationService.shared.translate(
                    ocr: ocr,
                    provider: settings.translationProvider,
                    targetLanguage: newLang,
                    openaiApiKey: settings.openaiApiKey,
                    openaiBaseURL: settings.openaiBaseURL,
                    openaiModel: settings.openaiModel
                )
                await MainActor.run {
                    self.update(result: res)
                    if self.isOverlayActive {
                        self.onToggleOverlay?(res)
                    }
                }
            } catch {
                await MainActor.run {
                    self.setError(error.localizedDescription)
                }
            }
        }
    }
}
