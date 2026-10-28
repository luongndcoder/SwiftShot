import AppKit
import CoreGraphics
import CoreImage
import Carbon.HIToolbox

/// Unified Flameshot-style overlay:
/// - Screen snapshot background
/// - Dimmed overlay with bright punch-through selection
/// - 8 resize handles + drag-to-move
/// - Direct in-place drawing (annotations drawn right on screen)
/// - Step counter (① ② ③...), Marker, Shapes, Blur, Text
/// - Floating HUD toolbar pinned outside selection
/// - Esc / Enter / Hotkey controls
final class UnifiedOverlayView: NSView {
    enum Handle: Int {
        case topLeft = 0, topMiddle, topRight
        case middleLeft, middleRight
        case bottomLeft, bottomMiddle, bottomRight
        case none
    }

    // Capture state
    private let backgroundImage: CGImage
    private let screenFrame: NSRect
    private var selectionRect: CGRect?
    private var isSelecting = false
    private var dragStartPoint: CGPoint = .zero
    private var initialSelectionRect: CGRect = .zero
    private var activeHandle: Handle = .none
    private var isMovingSelection = false

    // Tools & Annotations
    var selectedTool: Annotation.Kind = .arrow
    var currentColor: NSColor
    var strokeWidth: CGFloat
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var undoStack: [Annotation] = []
    private var currentCounter = 1
    /// Index of the annotation the user selected (Delete removes it).
    private var selectedAnnotationIndex: Int?
    /// Set while the user drags a selected annotation to a new position with
    /// the Select tool: the index, the drag start point and the annotation as
    /// it was when the drag began (moves are computed from this snapshot).
    private var movingAnnotationIndex: Int?
    private var annotationDragStartPoint: CGPoint = .zero
    private var annotationDragOriginal: Annotation?
    /// While active the next click picks a colour from the captured screen.
    private var isEyedropperActive = false
    /// Opacity of the dimmed area outside of the selection.
    private let dimOpacity: Double
    /// Whether the pixel magnifier is shown while selecting a region.
    private let showsMagnifier: Bool
    /// Whether a double click inside the selection copies it.
    private let copyOnDoubleClick: Bool

    // Subviews
    private var hudView: InPlaceHUDView?
    private var activeTextView: InPlaceTextView?
    private var magnifierView: MagnifierView?
    private var translationPanel: TranslationPanelController?
    private var translatedBlocks: [TranslatedBlock]?
    private var textExtractPanel: TextExtractPanelController?
    var settings: Settings = Settings()

    // Live Text on-canvas selection
    private var isLiveTextMode = false
    private var liveTextBlocks: [RecognizedTextBlock] = []
    private var selectedLiveBlockIds: Set<UUID> = []
    private var hoveredLiveBlockId: UUID?
    private var isDraggingLiveText = false
    private var liveTextDragStartPoint: CGPoint = .zero
    private var liveTextToolbar: NSView?
    private var liveTextCopyButton: NSButton?
    private var liveTextCountLabel: NSTextField?
    private var liveTextSelectAllButton: NSButton?
    private var toastView: NSView?

    private lazy var translationLoadingPill: NSView = {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 18
        pill.layer?.masksToBounds = false
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.5
        pill.layer?.shadowOffset = CGSize(width: 0, height: -2)
        pill.layer?.shadowRadius = 8

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 18
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        pill.addSubview(glass)
        glass.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)

        let label = NSTextField(labelWithString: "Đang nhận diện & dịch…")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        stack.addArrangedSubview(label)

        pill.addSubview(stack)
        stack.autoresizingMask = [.width, .height]

        pill.isHidden = true
        addSubview(pill)
        return pill
    }()

    // Callbacks
    private let onFinishCapture: (NSImage, CGRect, CaptureAction) -> Void
    private let onPinCapture: (NSImage, CGRect) -> Void
    private let onCancel: (CGRect?) -> Void

    /// Called when the user wants to store the current colour in the palette.
    var onAddColorPreset: ((NSColor) -> Void)?

    /// When set, the view is in region-picking mode (used to choose the area
    /// for a screen recording): the first completed selection is reported
    /// through this callback instead of opening the annotation HUD, and no
    /// drawing or finishing shortcuts are active.
    var onRegionPicked: ((CGRect) -> Void)?

    /// The current selection rectangle — used when the capture is cancelled so the
    /// region can be remembered for the next capture.
    var currentSelection: CGRect? { selectionRect }

    init(
        backgroundImage: CGImage,
        screenFrame: NSRect,
        initialColor: NSColor = .systemRed,
        initialStrokeWidth: CGFloat = 3,
        initialSelection: CGRect? = nil,
        colorPresets: [NSColor] = [],
        dimOpacity: Double = 0.35,
        showMagnifier: Bool = true,
        copyOnDoubleClick: Bool = true,
        onFinishCapture: @escaping (NSImage, CGRect, CaptureAction) -> Void,
        onPinCapture: @escaping (NSImage, CGRect) -> Void,
        onCancel: @escaping (CGRect?) -> Void
    ) {
        self.backgroundImage = backgroundImage
        self.screenFrame = screenFrame
        self.currentColor = initialColor
        self.strokeWidth = initialStrokeWidth
        self.dimOpacity = dimOpacity
        self.showsMagnifier = showMagnifier
        self.copyOnDoubleClick = copyOnDoubleClick
        self.onFinishCapture = onFinishCapture
        self.onPinCapture = onPinCapture
        self.onCancel = onCancel
        super.init(frame: screenFrame)

        if let initialSelection {
            selectionRect = initialSelection.intersection(bounds)
        }
        setupHUD()
        hudView?.setPresets(colorPresets)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupHUD() {
        let hud = InPlaceHUDView(initialColor: currentColor, initialStrokeWidth: strokeWidth) { [weak self] action in
            self?.handleHUDAction(action)
        }
        hud.isHidden = true
        addSubview(hud)
        self.hudView = hud

        let mag = MagnifierView()
        mag.isHidden = true
        addSubview(mag)
        self.magnifierView = mag

        // Track mouse movement for magnifier
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Live Text Mode: hover over recognized text lines on the image with I-beam cursor
        if isLiveTextMode, let sel = selectionRect, sel.contains(point) {
            magnifierView?.isHidden = true
            if let hit = liveTextBlocks.first(where: { liveBlockRect($0, in: sel).contains(point) }) {
                if hoveredLiveBlockId != hit.id {
                    hoveredLiveBlockId = hit.id
                    needsDisplay = true
                }
                NSCursor.iBeam.set()
                return
            } else {
                if hoveredLiveBlockId != nil {
                    hoveredLiveBlockId = nil
                    needsDisplay = true
                }
                NSCursor.arrow.set()
                return
            }
        }

        guard showsMagnifier else {
            magnifierView?.isHidden = true
            return
        }
        // Show magnifier when no selection is made yet, or while selecting / eyedropping
        if selectionRect == nil || isSelecting || isEyedropperActive {
            magnifierView?.isHidden = false
            magnifierView?.update(at: point, in: bounds, backgroundImage: backgroundImage)
        } else {
            magnifierView?.isHidden = true
        }
    }

    // MARK: - HUD Actions

    private func handleHUDAction(_ action: InPlaceHUDView.Action) {
        switch action {
        case .selectTool(let tool):
            selectedTool = tool
            isEyedropperActive = false
        case .changeColor(let color):
            currentColor = color
        case .changeStrokeWidth(let width):
            strokeWidth = width
        case .addColorPreset:
            onAddColorPreset?(currentColor)
        case .openColorPicker:
            break // handled inside the HUD
        case .eyedropper:
            isEyedropperActive = true
            selectedTool = .arrow
        case .undo:
            undo()
        case .redo:
            redo()
        case .pin:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            translationPanel?.closePanel()
            translationPanel = nil
            textExtractPanel?.closePanel()
            textExtractPanel = nil
            onPinCapture(img, sel)
        case .translate:
            startTranslation()
        case .copyText:
            startTextExtraction()
        case .copy:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            translationPanel?.closePanel()
            translationPanel = nil
            textExtractPanel?.closePanel()
            textExtractPanel = nil
            onFinishCapture(img, sel, .copy)
        case .save:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            translationPanel?.closePanel()
            translationPanel = nil
            textExtractPanel?.closePanel()
            textExtractPanel = nil
            onFinishCapture(img, sel, .save)
        case .saveAs:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            translationPanel?.closePanel()
            translationPanel = nil
            textExtractPanel?.closePanel()
            textExtractPanel = nil
            onFinishCapture(img, sel, .saveAs)
        case .cancel:
            exitLiveTextMode()
            translationLoadingPill.isHidden = true
            hudView?.setTranslating(false)
            translationPanel?.closePanel()
            translationPanel = nil
            textExtractPanel?.closePanel()
            textExtractPanel = nil
            onCancel(selectionRect)
        }
    }

    // MARK: - Translation Workflow

    private func startTranslation() {
        guard let sel = selectionRect, sel.width > 20, sel.height > 20 else { return }
        guard let image = renderCurrentSelectionImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        translationPanel?.closePanel()
        translationPanel = nil

        // Show in-place loading indicator immediately
        translationLoadingPill.frame = CGRect(x: sel.midX - 110, y: sel.midY - 18, width: 220, height: 36)
        translationLoadingPill.isHidden = false
        hudView?.setTranslating(true)

        var origin = CGPoint(x: sel.maxX + 12, y: sel.midY - 180)
        if let window = window, let screen = window.screen {
            if origin.x + 430 > screen.frame.maxX {
                origin.x = max(screen.frame.minX + 20, sel.minX - 432)
            }
            origin.y = max(screen.frame.minY + 20, min(origin.y, screen.frame.maxY - 380))
        }

        let panel = TranslationPanelController(
            ocr: OCRResult(fullText: "", blocks: []),
            initialResult: nil,
            settings: settings,
            at: origin
        )
        panel.setLoading(true)
        panel.onToggleOverlay = { [weak self] result in
            self?.translatedBlocks = result?.blocks
            self?.needsDisplay = true
        }
        panel.onClosed = { [weak self] in
            self?.translationPanel = nil
        }
        panel.show()
        self.translationPanel = panel

        Task {
            do {
                let ocrResult = try await OCRService.shared.recognizeText(in: cgImage)
                guard !ocrResult.isEmpty else {
                    await MainActor.run {
                        self.translationLoadingPill.isHidden = true
                        self.hudView?.setTranslating(false)
                        panel.setError("Không tìm thấy văn bản trong vùng chọn.")
                    }
                    return
                }

                let transResult = try await TranslationService.shared.translate(
                    ocr: ocrResult,
                    provider: settings.translationProvider,
                    targetLanguage: settings.translationTargetLanguage,
                    openaiApiKey: settings.openaiApiKey,
                    openaiBaseURL: settings.openaiBaseURL,
                    openaiModel: settings.openaiModel
                )

                await MainActor.run {
                    self.translationLoadingPill.isHidden = true
                    self.hudView?.setTranslating(false)
                    panel.update(result: transResult)
                    // Automatically show overlay on image
                    self.translatedBlocks = transResult.blocks
                    self.needsDisplay = true
                }
            } catch {
                await MainActor.run {
                    self.translationLoadingPill.isHidden = true
                    self.hudView?.setTranslating(false)
                    panel.setError(error.localizedDescription)
                }
            }
        }
    }

    private func drawTranslatedBlocks(in context: CGContext, selectionRect sel: CGRect) {
        guard let blocks = translatedBlocks, !blocks.isEmpty else { return }

        for block in blocks {
            let boxX = sel.origin.x + block.normalizedRect.origin.x * sel.width
            let boxY = sel.origin.y + block.normalizedRect.origin.y * sel.height
            let boxW = block.normalizedRect.width * sel.width
            let boxH = block.normalizedRect.height * sel.height
            let blockRect = CGRect(x: boxX, y: boxY, width: max(boxW, 20), height: max(boxH, 14))

            context.saveGState()

            // 1. Draw solid dark backdrop over original text with rounded corners
            let bgPath = CGPath(roundedRect: blockRect.insetBy(dx: -2, dy: -1), cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(bgPath)
            context.setFillColor(NSColor(white: 0.10, alpha: 0.94).cgColor)
            context.fillPath()

            context.addPath(bgPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            context.setLineWidth(1)
            context.strokePath()

            // 2. Draw translated text inside the box
            let fontSize = min(max(10, blockRect.height * 0.72), 26)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            paragraphStyle.lineBreakMode = .byTruncatingTail

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle
            ]

            let textRect = blockRect.insetBy(dx: 2, dy: 1)
            let attrString = NSAttributedString(string: block.translatedText, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrString)

            context.textPosition = CGPoint(x: textRect.minX, y: textRect.minY + (textRect.height - fontSize) * 0.5)
            CTLineDraw(ctLine, context)

            context.restoreGState()
        }
    }

    // MARK: - Live Text & Text Extraction Workflow

    private func liveBlockRect(_ block: RecognizedTextBlock, in sel: CGRect) -> CGRect {
        let boxX = sel.origin.x + block.normalizedRect.origin.x * sel.width
        let boxY = sel.origin.y + block.normalizedRect.origin.y * sel.height
        let boxW = block.normalizedRect.width * sel.width
        let boxH = block.normalizedRect.height * sel.height
        return CGRect(x: boxX, y: boxY, width: max(boxW, 20), height: max(boxH, 14))
    }

    private func startTextExtraction() {
        guard let sel = selectionRect, sel.width > 20, sel.height > 20 else { return }
        guard let image = renderCurrentSelectionImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        exitLiveTextMode()

        // Show in-place loading indicator immediately
        translationLoadingPill.frame = CGRect(x: sel.midX - 110, y: sel.midY - 18, width: 220, height: 36)
        translationLoadingPill.isHidden = false
        hudView?.setTranslating(true)

        Task {
            do {
                let ocrResult = try await OCRService.shared.recognizeText(in: cgImage)
                await MainActor.run {
                    self.translationLoadingPill.isHidden = true
                    self.hudView?.setTranslating(false)
                    if ocrResult.isEmpty {
                        self.showToast("Không tìm thấy văn bản nào trong vùng chọn")
                    } else {
                        self.enterLiveTextMode(blocks: ocrResult.blocks)
                        self.showToast("Đã nhận diện \(ocrResult.blocks.count) dòng chữ. Nhấp hoặc kéo để chọn!")
                    }
                }
            } catch {
                await MainActor.run {
                    self.translationLoadingPill.isHidden = true
                    self.hudView?.setTranslating(false)
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    private func enterLiveTextMode(blocks: [RecognizedTextBlock]) {
        isLiveTextMode = true
        liveTextBlocks = blocks
        selectedLiveBlockIds = Set(blocks.map(\.id)) // Pre-select all so user can copy immediately or select lines
        showLiveTextToolbar()
        needsDisplay = true
    }

    private func exitLiveTextMode() {
        isLiveTextMode = false
        liveTextBlocks = []
        selectedLiveBlockIds = []
        hoveredLiveBlockId = nil
        isDraggingLiveText = false
        liveTextToolbar?.removeFromSuperview()
        liveTextToolbar = nil
        textExtractPanel?.closePanel()
        textExtractPanel = nil
        needsDisplay = true
    }

    private func showLiveTextToolbar() {
        guard let sel = selectionRect else { return }
        liveTextToolbar?.removeFromSuperview()

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 16
        bar.layer?.masksToBounds = false
        bar.layer?.shadowColor = NSColor.black.cgColor
        bar.layer?.shadowOpacity = 0.5
        bar.layer?.shadowOffset = CGSize(width: 0, height: -2)
        bar.layer?.shadowRadius = 8

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bar.addSubview(glass)
        glass.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        icon.contentTintColor = .systemCyan
        stack.addArrangedSubview(icon)

        let countLabel = NSTextField(labelWithString: "\(selectedLiveBlockIds.count)/\(liveTextBlocks.count) dòng")
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .labelColor
        self.liveTextCountLabel = countLabel
        stack.addArrangedSubview(countLabel)

        let selectAllBtn = NSButton(title: "Bỏ chọn", target: self, action: #selector(toggleSelectAllLiveText))
        selectAllBtn.bezelStyle = .inline
        selectAllBtn.font = NSFont.systemFont(ofSize: 11)
        self.liveTextSelectAllButton = selectAllBtn
        stack.addArrangedSubview(selectAllBtn)

        let copyBtn = NSButton(title: "Copy (⌘C)", target: self, action: #selector(copySelectedLiveText))
        copyBtn.bezelStyle = .inline
        copyBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        copyBtn.contentTintColor = .systemCyan
        self.liveTextCopyButton = copyBtn
        stack.addArrangedSubview(copyBtn)

        let detailBtn = NSButton(title: "Bảng chi tiết", target: self, action: #selector(openDetailsPanel))
        detailBtn.bezelStyle = .inline
        detailBtn.font = NSFont.systemFont(ofSize: 11)
        stack.addArrangedSubview(detailBtn)

        let closeBtn = NSButton(title: "✕", target: self, action: #selector(closeLiveTextModeAction))
        closeBtn.bezelStyle = .inline
        closeBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeBtn.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(closeBtn)

        bar.addSubview(stack)
        stack.autoresizingMask = [.width, .height]

        let barWidth: CGFloat = 370
        let barHeight: CGFloat = 32
        var barX = sel.midX - barWidth / 2
        var barY = sel.maxY + 10
        if barY + barHeight > bounds.height - 10 {
            barY = max(10, sel.minY - barHeight - 10)
        }
        barX = max(10, min(barX, bounds.width - barWidth - 10))

        bar.frame = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
        addSubview(bar)
        self.liveTextToolbar = bar
    }

    private func updateLiveTextToolbarState() {
        liveTextCountLabel?.stringValue = "\(selectedLiveBlockIds.count)/\(liveTextBlocks.count) dòng"
        if selectedLiveBlockIds.count == liveTextBlocks.count {
            liveTextSelectAllButton?.title = "Bỏ chọn"
        } else {
            liveTextSelectAllButton?.title = "Chọn tất cả"
        }
        liveTextCopyButton?.title = selectedLiveBlockIds.isEmpty ? "Copy (⌘C)" : "Copy (\(selectedLiveBlockIds.count))"
    }

    @objc private func copySelectedLiveText() {
        let blocksToCopy = selectedLiveBlockIds.isEmpty
            ? liveTextBlocks
            : liveTextBlocks.filter { selectedLiveBlockIds.contains($0.id) }
        let text = blocksToCopy.map(\.text).joined(separator: "\n")
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showToast("Đã copy \(blocksToCopy.count) dòng chữ vào Clipboard! ✓")
        }
    }

    @objc private func toggleSelectAllLiveText() {
        if selectedLiveBlockIds.count == liveTextBlocks.count {
            selectedLiveBlockIds.removeAll()
        } else {
            selectedLiveBlockIds = Set(liveTextBlocks.map(\.id))
        }
        updateLiveTextToolbarState()
        needsDisplay = true
    }

    @objc private func openDetailsPanel() {
        guard let sel = selectionRect else { return }
        var origin = CGPoint(x: sel.maxX + 12, y: sel.midY - 190)
        if let window = window, let screen = window.screen {
            if origin.x + 450 > screen.frame.maxX {
                origin.x = max(screen.frame.minX + 20, sel.minX - 452)
            }
            origin.y = max(screen.frame.minY + 20, min(origin.y, screen.frame.maxY - 400))
        }

        let ocr = OCRResult(
            fullText: liveTextBlocks.map(\.text).joined(separator: "\n"),
            blocks: liveTextBlocks
        )
        let panel = TextExtractPanelController(ocr: ocr, at: origin)
        panel.onClosed = { [weak self] in
            self?.textExtractPanel = nil
        }
        panel.show()
        self.textExtractPanel = panel
    }

    @objc private func closeLiveTextModeAction() {
        exitLiveTextMode()
    }

    private func showToast(_ message: String) {
        guard let sel = selectionRect else { return }
        toastView?.removeFromSuperview()

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        pill.layer?.masksToBounds = false
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = 0.5
        pill.layer?.shadowOffset = CGSize(width: 0, height: -2)
        pill.layer?.shadowRadius = 8

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.4).cgColor
        pill.addSubview(glass)
        glass.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        pill.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5)
        ])

        let toastWidth = min(bounds.width - 40, max(200, label.intrinsicContentSize.width + 28))
        pill.frame = CGRect(x: sel.midX - toastWidth / 2, y: max(20, sel.minY + 10), width: toastWidth, height: 28)

        addSubview(pill)
        self.toastView = pill

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self, weak pill] in
            guard let pill, self?.toastView == pill else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                pill.animator().alphaValue = 0.0
            }, completionHandler: {
                pill.removeFromSuperview()
                if self?.toastView == pill {
                    self?.toastView = nil
                }
            })
        }
    }

    private func drawLiveTextHighlights(in context: CGContext, selectionRect sel: CGRect) {
        guard isLiveTextMode, !liveTextBlocks.isEmpty else { return }

        for block in liveTextBlocks {
            let blockRect = liveBlockRect(block, in: sel)
            let isSelected = selectedLiveBlockIds.contains(block.id)
            let isHovered = (hoveredLiveBlockId == block.id)

            context.saveGState()

            let path = CGPath(roundedRect: blockRect.insetBy(dx: -2, dy: -1), cornerWidth: 3, cornerHeight: 3, transform: nil)
            context.addPath(path)

            if isSelected {
                // Apple Live Text blue selection highlight
                context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.40).cgColor)
                context.fillPath()

                context.addPath(path)
                context.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.85).cgColor)
                context.setLineWidth(1.5)
                context.strokePath()
            } else if isHovered {
                // Subtle hover highlight
                context.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
                context.fillPath()

                context.addPath(path)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.strokePath()
            } else {
                // Selectable text indicator: subtle dashed frame
                context.addPath(path)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [3, 3])
                context.strokePath()
            }

            context.restoreGState()
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Live Text Mode: click or drag select text lines directly on the screenshot
        if isLiveTextMode, let sel = selectionRect, sel.contains(point) {
            // Double click on a text line: copy that line immediately!
            if event.clickCount == 2, let hit = liveTextBlocks.first(where: { liveBlockRect($0, in: sel).contains(point) }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.text, forType: .string)
                showToast("Đã copy: \"\(hit.text.prefix(32))...\" ✓")
                selectedLiveBlockIds = [hit.id]
                updateLiveTextToolbarState()
                needsDisplay = true
                return
            }

            // Click or drag selection across lines
            if let hit = liveTextBlocks.first(where: { liveBlockRect($0, in: sel).contains(point) }) {
                if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
                    if selectedLiveBlockIds.contains(hit.id) {
                        selectedLiveBlockIds.remove(hit.id)
                    } else {
                        selectedLiveBlockIds.insert(hit.id)
                    }
                } else {
                    selectedLiveBlockIds = [hit.id]
                }
            } else {
                if !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command) {
                    selectedLiveBlockIds.removeAll()
                }
            }
            isDraggingLiveText = true
            liveTextDragStartPoint = point
            updateLiveTextToolbarState()
            needsDisplay = true
            return
        }

        // 0. Eyedropper mode: pick the colour under the cursor and leave the mode.
        if isEyedropperActive {
            isEyedropperActive = false
            magnifierView?.isHidden = true
            if let color = sampleColor(at: point) {
                currentColor = color
                hudView?.changeColor(color)
            }
            return
        }

        // 1. Double click inside the selection copies it (if enabled).
        if onRegionPicked == nil, event.clickCount == 2, let sel = selectionRect, sel.contains(point), copyOnDoubleClick {
            guard let img = renderCurrentSelectionImage() else { return }
            onFinishCapture(img, sel, .copy)
            return
        }

        // 2. If no selection exists yet, start dragging new selection
        guard let sel = selectionRect else {
            isSelecting = true
            dragStartPoint = point
            selectionRect = CGRect(origin: point, size: .zero)
            hudView?.isHidden = true
            needsDisplay = true
            return
        }

        // 3. Check if clicking on a resize handle
        let handle = detectHandle(at: point, in: sel)
        if handle != .none {
            activeHandle = handle
            dragStartPoint = point
            initialSelectionRect = sel
            selectedAnnotationIndex = nil
            hudView?.isHidden = true
            return
        }

        // 4. With the selection tool, clicking an existing annotation selects it
        //    (Delete then removes it) and dragging moves it.
        if selectedTool == .select, sel.contains(point), let index = hitTestAnnotation(at: point) {
            selectedAnnotationIndex = index
            movingAnnotationIndex = index
            annotationDragStartPoint = point
            annotationDragOriginal = annotations[index]
            needsDisplay = true
            return
        }
        selectedAnnotationIndex = nil

        // 5. Check if moving whole selection (Alt or the Move tool)
        if event.modifierFlags.contains(.option) || selectedTool == .move {
            if sel.contains(point) {
                isMovingSelection = true
                dragStartPoint = point
                initialSelectionRect = sel
                hudView?.isHidden = true
                needsDisplay = true
                return
            }
        }

        // 6. Drawing tools inside selection
        if sel.contains(point) {
            handleDrawingMouseDown(at: point)
            return
        }

        // 7. Clicked outside selection -> start new selection
        isSelecting = true
        dragStartPoint = point
        selectionRect = CGRect(origin: point, size: .zero)
        annotations.removeAll()
        selectedAnnotationIndex = nil
        currentCounter = 1
        hudView?.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)

        if isLiveTextMode, isDraggingLiveText, let sel = selectionRect {
            let dragRect = CGRect(
                x: min(liveTextDragStartPoint.x, current.x),
                y: min(liveTextDragStartPoint.y, current.y),
                width: abs(current.x - liveTextDragStartPoint.x),
                height: abs(current.y - liveTextDragStartPoint.y)
            )
            for block in liveTextBlocks {
                if dragRect.intersects(liveBlockRect(block, in: sel)) {
                    selectedLiveBlockIds.insert(block.id)
                }
            }
            updateLiveTextToolbarState()
            needsDisplay = true
            return
        }

        if isSelecting {
            selectionRect = CGRect(
                x: min(dragStartPoint.x, current.x),
                y: min(dragStartPoint.y, current.y),
                width: abs(current.x - dragStartPoint.x),
                height: abs(current.y - dragStartPoint.y)
            )
            needsDisplay = true
            return
        }

        if activeHandle != .none {
            // Shift mirrors the resize: the opposite handle moves as well.
            selectionRect = resizeSelection(
                from: initialSelectionRect,
                handle: activeHandle,
                currentPoint: current,
                mirror: event.modifierFlags.contains(.shift)
            )
            needsDisplay = true
            return
        }

        if isMovingSelection {
            let dx = current.x - dragStartPoint.x
            let dy = current.y - dragStartPoint.y
            selectionRect = initialSelectionRect.offsetBy(dx: dx, dy: dy)
            needsDisplay = true
            return
        }

        // Dragging the selected annotation to a new position (Select tool).
        if let index = movingAnnotationIndex,
           annotations.indices.contains(index),
           let original = annotationDragOriginal,
           let sel = selectionRect {
            annotations[index] = Self.moved(
                original,
                by: CGPoint(x: current.x - annotationDragStartPoint.x,
                            y: current.y - annotationDragStartPoint.y),
                within: sel
            )
            needsDisplay = true
            return
        }

        // Drawing dragged
        if var ann = currentAnnotation {
            let constrain = event.modifierFlags.contains(.control)
            switch ann.kind {
            case .freehand:
                ann.points.append(current)
                ann.end = current
            case .marker:
                if constrain {
                    // Ctrl constrains the marker to a straight, 45°-snapped line.
                    let snapped = constrainedPoint(from: ann.start, to: current)
                    ann.points = [ann.start, snapped]
                    ann.end = snapped
                } else {
                    ann.points.append(current)
                    ann.end = current
                }
            case .line, .arrow:
                ann.end = constrain ? constrainedPoint(from: ann.start, to: current) : current
            case .rectangle, .filledRectangle, .ellipse, .invert, .blur, .pixelate:
                ann.end = constrain ? aspectLockedPoint(from: ann.start, to: current) : current
            default:
                ann.end = current
            }
            currentAnnotation = ann
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)

        if isLiveTextMode, isDraggingLiveText {
            isDraggingLiveText = false
            updateLiveTextToolbarState()
            needsDisplay = true
            return
        }

        if isSelecting {
            isSelecting = false
            guard var sel = selectionRect else { return }
            // Click without drag = full screen
            if sel.width < 5 && sel.height < 5 {
                sel = bounds
                selectionRect = sel
            }
            // Region-picking mode: report the region and finish — no HUD.
            if let onRegionPicked {
                onRegionPicked(sel)
                return
            }
            positionHUD(for: sel)
            needsDisplay = true
            return
        }

        if activeHandle != .none || isMovingSelection {
            activeHandle = .none
            isMovingSelection = false
            if let sel = selectionRect {
                positionHUD(for: sel)
            }
            needsDisplay = true
            return
        }

        if movingAnnotationIndex != nil {
            movingAnnotationIndex = nil
            annotationDragOriginal = nil
            needsDisplay = true
            return
        }

        // Commit current annotation
        if var ann = currentAnnotation {
            switch ann.kind {
            case .freehand, .marker:
                ann.end = current
            default:
                ann.end = current
            }
            if isValid(annotation: ann) {
                annotations.append(ann)
                undoStack.removeAll()
            }
            currentAnnotation = nil
            needsDisplay = true
        }
    }

    private func handleDrawingMouseDown(at point: CGPoint) {
        switch selectedTool {
        case .select:
            break
        case .counter:
            // Auto-increment step counter
            let ann = Annotation(
                kind: .counter, points: [], start: point, end: point,
                color: currentColor, strokeWidth: strokeWidth,
                text: nil, count: currentCounter
            )
            currentCounter += 1
            annotations.append(ann)
            undoStack.removeAll()
            needsDisplay = true
        case .text:
            activeTextView?.commit()
            // Freeze the stroke width / font size at creation time so the committed
            // annotation renders exactly like the edit box that is on screen.
            let frozenStrokeWidth = strokeWidth
            let fontSize = max(16, frozenStrokeWidth * 5)
            let textView = InPlaceTextView(
                at: point,
                textColor: currentColor,
                fontSize: fontSize,
                onCommit: { [weak self] text, baseline in
                    guard let self else { return }
                    let ann = Annotation(
                        kind: .text, points: [], start: baseline, end: baseline,
                        color: self.currentColor, strokeWidth: frozenStrokeWidth,
                        text: text
                    )
                    self.annotations.append(ann)
                    self.undoStack.removeAll()
                    self.activeTextView = nil
                    self.needsDisplay = true
                },
                onCancel: { [weak self] in
                    self?.activeTextView = nil
                }
            )
            addSubview(textView)
            textView.focus()
            activeTextView = textView
        case .freehand, .marker:
            currentAnnotation = Annotation(
                kind: selectedTool, points: [point], start: point, end: point,
                color: currentColor, strokeWidth: selectedTool == .marker ? strokeWidth * 3 : strokeWidth
            )
        default:
            currentAnnotation = Annotation(
                kind: selectedTool, points: [], start: point, end: point,
                color: currentColor, strokeWidth: strokeWidth
            )
        }
    }

    private func isValid(annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .freehand, .marker:
            return annotation.points.count > 1
        case .counter, .text:
            return true
        default:
            return annotation.bounds.width > 2 || annotation.bounds.height > 2
        }
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let last = annotations.popLast() else { return }
        undoStack.append(last)
        refreshCounter()
        needsDisplay = true
    }

    func redo() {
        guard let last = undoStack.popLast() else { return }
        annotations.append(last)
        refreshCounter()
        needsDisplay = true
    }

    /// Keeps the auto-incrementing step counter in sync with the badges that are
    /// actually on the canvas (undo/redo must not leave gaps or duplicates).
    private func refreshCounter() {
        let highest = annotations.compactMap { annotation -> Int? in
            annotation.kind == .counter ? annotation.count : nil
        }.max() ?? 0
        currentCounter = highest + 1
    }

    // MARK: - Handles & Selection Management

    private func detectHandle(at point: CGPoint, in rect: CGRect) -> Handle {
        let handleSize: CGFloat = 10
        for (handle, p) in handlePoints(in: rect) {
            let hitRect = CGRect(x: p.x - handleSize, y: p.y - handleSize, width: handleSize * 2, height: handleSize * 2)
            if hitRect.contains(point) {
                return handle
            }
        }
        return .none
    }

    /// The positions of the eight resize handles.
    private func handlePoints(in rect: CGRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topMiddle, CGPoint(x: rect.midX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.middleLeft, CGPoint(x: rect.minX, y: rect.midY)),
            (.middleRight, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomMiddle, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
        ]
    }

    private func resizeSelection(from rect: CGRect, handle: Handle, currentPoint: CGPoint, mirror: Bool = false) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = min(currentPoint.x, maxX - 10)
            maxY = max(currentPoint.y, minY + 10)
        case .topMiddle:
            maxY = max(currentPoint.y, minY + 10)
        case .topRight:
            maxX = max(currentPoint.x, minX + 10)
            maxY = max(currentPoint.y, minY + 10)
        case .middleLeft:
            minX = min(currentPoint.x, maxX - 10)
        case .middleRight:
            maxX = max(currentPoint.x, minX + 10)
        case .bottomLeft:
            minX = min(currentPoint.x, maxX - 10)
            minY = min(currentPoint.y, maxY - 10)
        case .bottomMiddle:
            minY = min(currentPoint.y, maxY - 10)
        case .bottomRight:
            maxX = max(currentPoint.x, minX + 10)
            minY = min(currentPoint.y, maxY - 10)
        case .none:
            break
        }

        if mirror {
            // The handle opposite of the dragged one moves the same distance the
            // other way, so the selection keeps its centre.
            switch handle {
            case .topLeft, .middleLeft, .bottomLeft:
                maxX = rect.maxX + (rect.minX - minX)
            case .topRight, .middleRight, .bottomRight:
                minX = rect.minX - (maxX - rect.maxX)
            default:
                break
            }
            switch handle {
            case .topLeft, .topMiddle, .topRight:
                minY = rect.minY - (maxY - rect.maxY)
            case .bottomLeft, .bottomMiddle, .bottomRight:
                maxY = rect.maxY + (rect.minY - minY)
            default:
                break
            }
        }

        var result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // A mirrored resize can collapse the selection — keep a usable minimum.
        if result.width < 10 { result.size.width = 10 }
        if result.height < 10 { result.size.height = 10 }
        return result
    }

    // MARK: - Drawing constraints

    /// Snaps `to` onto the closest 45° ray starting at `from`, keeping the distance.
    private func constrainedPoint(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return to }

        let step = CGFloat.pi / 4
        let angle = atan2(dy, dx)
        let snapped = (angle / step).rounded() * step
        return CGPoint(x: from.x + cos(snapped) * length, y: from.y + sin(snapped) * length)
    }

    /// Keeps the drawn shape square (same width and height), like Flameshot's
    /// Ctrl + rectangle/circle behaviour.
    private func aspectLockedPoint(from: CGPoint, to: CGPoint) -> CGPoint {
        let width = abs(to.x - from.x)
        let height = abs(to.y - from.y)
        let size = max(width, height)
        // The drag direction is preserved, only the size is locked.
        let x = to.x >= from.x ? from.x + size : from.x - size
        let y = to.y >= from.y ? from.y + size : from.y - size
        return CGPoint(x: x, y: y)
    }

    // MARK: - Annotation hit testing

    /// Returns the index of the annotation below `point`, if any.
    private func hitTestAnnotation(at point: CGPoint) -> Int? {
        for index in annotations.indices.reversed() {
            if contains(annotations[index], point) { return index }
        }
        return nil
    }

    private func contains(_ annotation: Annotation, _ point: CGPoint) -> Bool {
        let tolerance = max(6, annotation.strokeWidth)
        switch annotation.kind {
        case .line, .arrow:
            return distance(from: point, toSegment: (annotation.start, annotation.end)) <= tolerance
        case .freehand, .marker:
            if annotation.points.contains(where: { distance(from: point, to: $0) <= tolerance }) { return true }
            return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return textBounds(annotation).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .counter:
            return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default:
            return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// The rendered size of a text annotation.
    private func textBounds(_ annotation: Annotation) -> CGRect {
        guard let text = annotation.text else { return annotation.bounds }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: max(16, annotation.strokeWidth * 5))
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        return CGRect(
            x: annotation.start.x,
            y: annotation.start.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func distance(from point: CGPoint, to other: CGPoint) -> CGFloat {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func distance(from point: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = segment
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(from: point, to: a) }

        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(from: point, to: projection)
    }

    /// Samples the colour of the captured screen below `point` (view coordinates).
    private func sampleColor(at point: CGPoint) -> NSColor? {
        let scaleX = CGFloat(backgroundImage.width) / bounds.width
        let scaleY = CGFloat(backgroundImage.height) / bounds.height
        // The bitmap is top-left based, the view is bottom-left based.
        let pixel = CGPoint(x: point.x * scaleX, y: (bounds.height - point.y) * scaleY)
        return PixelSampler.color(in: backgroundImage, at: pixel)
    }

    /// Set once the HUD has played its entrance animation for this capture —
    /// repositioning after a resize/move must be instant, not animated.
    private var didRevealHUD = false

    private func positionHUD(for rect: CGRect) {
        guard let hud = hudView else { return }
        let wasHidden = hud.isHidden
        hud.isHidden = false

        // Use the HUD's intrinsic size instead of a hardcoded width so the toolbar
        // can never be clipped when the tool set changes.
        let size = hud.fittingSize
        let hudWidth = size.width > 0 ? size.width : 680
        let hudHeight = size.height > 0 ? size.height : 38

        // Prefer placing the HUD below the selection; fall back to the top and clamp
        // it back into the screen (a full-screen selection has no room underneath).
        var hudY: CGFloat
        let belowY = rect.minY - hudHeight - 10
        if belowY >= 10 {
            hudY = belowY
        } else {
            hudY = min(rect.maxY + 10, bounds.maxY - hudHeight - 10)
            hudY = max(hudY, 10)
        }

        var hudX = rect.midX - hudWidth / 2
        hudX = max(10, min(hudX, bounds.maxX - hudWidth - 10))

        let targetFrame = CGRect(x: hudX, y: hudY, width: hudWidth, height: hudHeight)

        if wasHidden && !didRevealHUD {
            // Glass Pro entrance: fade in while settling 6pt into place.
            didRevealHUD = true
            hud.alphaValue = 0
            hud.frame = targetFrame.offsetBy(dx: 0, dy: -6)
            hud.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                hud.animator().alphaValue = 1
                hud.animator().frame = targetFrame
            }
        } else {
            hud.alphaValue = 1
            hud.frame = targetFrame
            hud.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw raw desktop snapshot background
        context.draw(backgroundImage, in: bounds)

        // 2. Draw crisp punch-through selection or dimmed overlay
        if let sel = selectionRect, sel.width > 0, sel.height > 0 {
            // Fill dimming only outside selection rect
            context.setFillColor(NSColor.black.withAlphaComponent(dimOpacity).cgColor)

            // Top
            let topRect = CGRect(x: 0, y: sel.maxY, width: bounds.width, height: bounds.height - sel.maxY)
            context.fill(topRect)
            // Bottom
            let bottomRect = CGRect(x: 0, y: 0, width: bounds.width, height: sel.minY)
            context.fill(bottomRect)
            // Left
            let leftRect = CGRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height)
            context.fill(leftRect)
            // Right
            let rightRect = CGRect(x: sel.maxX, y: sel.minY, width: bounds.width - sel.maxX, height: sel.height)
            context.fill(rightRect)

            // Draw committed annotations inside selection
            context.saveGState()
            context.clip(to: sel)
            drawTranslatedBlocks(in: context, selectionRect: sel)
            drawLiveTextHighlights(in: context, selectionRect: sel)
            for ann in annotations {
                drawAnnotation(ann, in: context)
            }
            if let current = currentAnnotation {
                drawAnnotation(current, in: context)
            }
            context.restoreGState()

            // Highlight the selected annotation
            if let index = selectedAnnotationIndex, annotations.indices.contains(index) {
                drawSelectionHighlight(for: annotations[index], in: context)
            }

            // Draw selection borders & 8 handles
            drawSelectionBorderAndHandles(sel, in: context)

            // Draw size indicator W × H
            drawSizeLabel(for: sel, in: context)
        } else {
            // No selection yet: subtle dim overlay
            context.setFillColor(NSColor.black.withAlphaComponent(min(dimOpacity, 0.2)).cgColor)
            context.fill(bounds)
        }
    }

    /// Dashed outline around the annotation the user selected.
    private func drawSelectionHighlight(for annotation: Annotation, in context: CGContext) {
        let bounds: CGRect
        switch annotation.kind {
        case .text:
            bounds = textBounds(annotation)
        case .counter:
            bounds = annotation.bounds.insetBy(dx: -13, dy: -13)
        case .line, .arrow, .freehand, .marker:
            bounds = annotation.bounds.insetBy(dx: -4, dy: -4)
        default:
            bounds = annotation.bounds
        }
        guard bounds.width > 0, bounds.height > 0 else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(bounds)
        context.restoreGState()
    }

    private func drawSelectionBorderAndHandles(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect)

        let handleSize: CGFloat = 8

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)

        for (_, p) in handlePoints(in: rect) {
            let hRect = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
            context.fill(hRect)
            context.stroke(hRect)
        }
    }

    // MARK: - Cursor

    /// Shows the hand cursor over the selection, resize cursors on the handles and a
    /// crosshair while a drawing tool is active — the same affordances Flameshot has.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let sel = selectionRect else { return }

        for (handle, point) in handlePoints(in: sel) {
            let rect = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            addCursorRect(rect, cursor: Self.cursor(for: handle))
        }

        if selectedTool == .move {
            addCursorRect(sel, cursor: isMovingSelection ? .closedHand : .openHand)
        } else if selectedTool != .select, isDrawingTool(selectedTool) {
            addCursorRect(sel, cursor: .crosshair)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isMovingSelection {
            NSCursor.closedHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// The cursor shapes depend on the selection, so they have to be recalculated
    /// whenever the overlay redraws.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    /// The cursor shown when hovering a resize handle.
    private static func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .middleLeft, .middleRight:
            return .resizeLeftRight
        case .topMiddle, .bottomMiddle:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            return diagonalResizeCursor(flipped: false)
        case .topRight, .bottomLeft:
            return diagonalResizeCursor(flipped: true)
        case .none:
            return .arrow
        }
    }

    /// macOS has no public diagonal resize cursor, so one is drawn.
    private static func diagonalResizeCursor(flipped: Bool) -> NSCursor {
        let key = flipped ? "diagonal.flipped" : "diagonal"
        if let cached = diagonalCursors[key] { return cached }

        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        let start = flipped ? NSPoint(x: 3, y: 13) : NSPoint(x: 3, y: 3)
        let end = flipped ? NSPoint(x: 13, y: 3) : NSPoint(x: 13, y: 13)

        func arrowHead(at tip: NSPoint, towards other: NSPoint) -> NSBezierPath {
            let path = NSBezierPath()
            let dx = other.x - tip.x
            let dy = other.y - tip.y
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let ux = dx / length
            let uy = dy / length
            let size: CGFloat = 4
            path.move(to: tip)
            path.line(to: NSPoint(x: tip.x + ux * size - uy * size * 0.6, y: tip.y + uy * size + ux * size * 0.6))
            path.move(to: tip)
            path.line(to: NSPoint(x: tip.x + ux * size + uy * size * 0.6, y: tip.y + uy * size - ux * size * 0.6))
            return path
        }

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: end)
        shaft.lineWidth = 1.2
        shaft.lineCapStyle = .round

        let head1 = arrowHead(at: start, towards: end)
        let head2 = arrowHead(at: end, towards: start)
        head1.lineWidth = 1.2
        head2.lineWidth = 1.2
        head1.lineCapStyle = .round
        head2.lineCapStyle = .round

        // White outline first, then the black arrow on top.
        for path in [shaft, head1, head2] {
            path.lineWidth += 2
            NSColor.white.setStroke()
            path.stroke()
        }
        NSColor.black.setStroke()
        for path in [shaft, head1, head2] {
            path.lineWidth -= 2
            path.stroke()
        }

        image.unlockFocus()

        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        diagonalCursors[key] = cursor
        return cursor
    }

    private static var diagonalCursors: [String: NSCursor] = [:]

    /// Whether the tool draws something on the canvas.
    private func isDrawingTool(_ tool: Annotation.Kind) -> Bool {
        switch tool {
        case .select, .move: return false
        default: return true
        }
    }

    private func drawSizeLabel(for rect: CGRect, in context: CGContext) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 11, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: NSColor.white.cgColor
        ]
        let attrString = CFAttributedStringCreate(kCFAllocatorDefault, label as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        let labelRect = CGRect(x: rect.minX, y: rect.maxY + 4, width: bounds.width + 14, height: bounds.height + 8)

        context.setFillColor(NSColor(calibratedWhite: 0.1, alpha: 0.85).cgColor)
        let path = CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.fillPath()

        context.saveGState()
        context.textPosition = CGPoint(x: labelRect.minX + 7, y: labelRect.minY + 4)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawAnnotation(_ ann: Annotation, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(ann.color.cgColor)
        context.setFillColor(ann.color.cgColor)
        context.setLineWidth(ann.strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch ann.kind {
        case .select, .move:
            break
        case .arrow:
            drawArrow(start: ann.start, end: ann.end, in: context)
        case .line:
            context.move(to: ann.start)
            context.addLine(to: ann.end)
            context.strokePath()
        case .rectangle:
            context.stroke(ann.bounds)
        case .filledRectangle:
            context.fill(ann.bounds)
        case .ellipse:
            context.strokeEllipse(in: ann.bounds)
        case .freehand:
            if ann.points.count > 1 {
                context.move(to: ann.points[0])
                for p in ann.points.dropFirst() {
                    context.addLine(to: p)
                }
                context.strokePath()
            }
        case .marker:
            // Semi-transparent highlighter
            context.setBlendMode(.multiply)
            context.setStrokeColor(ann.color.withAlphaComponent(0.4).cgColor)
            if ann.points.count > 1 {
                context.move(to: ann.points[0])
                for p in ann.points.dropFirst() {
                    context.addLine(to: p)
                }
                context.strokePath()
            }
        case .counter:
            if let count = ann.count {
                drawCounterBadge(count: count, at: ann.start, color: ann.color, in: context)
            }
        case .text:
            if let text = ann.text {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: max(16, ann.strokeWidth * 5)),
                    .foregroundColor: ann.color
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                context.saveGState()
                context.textPosition = CGPoint(x: ann.start.x, y: ann.start.y)
                CTLineDraw(line, context)
                context.restoreGState()
            }
        case .blur, .pixelate, .invert:
            drawBackgroundEffect(ann: ann, in: context)
        }

        context.restoreGState()
    }

    private func drawArrow(start: CGPoint, end: CGPoint, in context: CGContext) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 16
        let arrowAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: end.x - arrowLength * cos(angle - arrowAngle),
            y: end.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = CGPoint(
            x: end.x - arrowLength * cos(angle + arrowAngle),
            y: end.y - arrowLength * sin(angle + arrowAngle)
        )

        context.move(to: end)
        context.addLine(to: p1)
        context.move(to: end)
        context.addLine(to: p2)
        context.strokePath()
    }

    private func drawCounterBadge(count: Int, at point: CGPoint, color: NSColor, in context: CGContext) {
        let radius: CGFloat = 13
        let badgeRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

        // Circle fill
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: badgeRect)

        // Circle white stroke
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: badgeRect)

        // Number text via CoreText
        let str = "\(count)"
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: NSColor.white.cgColor
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, str as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        context.saveGState()
        context.textPosition = CGPoint(x: point.x - lineBounds.width / 2, y: point.y - lineBounds.height / 2 + 1)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Draws an effect that is based on the captured screen: blur, pixelate or invert.
    private func drawBackgroundEffect(ann: Annotation, in context: CGContext) {
        let rect = ann.bounds
        let scaleX = CGFloat(backgroundImage.width) / bounds.width
        let scaleY = CGFloat(backgroundImage.height) / bounds.height
        // In CGImage bitmap coordinate system, origin (0, 0) is top-left, so flip Y:
        let flippedY = (bounds.height - rect.maxY) * scaleY
        let cropRect = CGRect(
            x: rect.origin.x * scaleX,
            y: flippedY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )

        guard let cropped = backgroundImage.cropping(to: cropRect) else { return }

        // `cropped` is already the cropped image, so its own coordinate space starts
        // at the origin — sampling from `cropRect` (which carries a non-zero origin)
        // would address a region outside the image and render nothing.
        let sourceRect = CGRect(x: 0, y: 0, width: CGFloat(cropped.width), height: CGFloat(cropped.height))

        switch ann.kind {
        case .blur:
            let blurFilter = CIFilter(name: "CIGaussianBlur")
            blurFilter?.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
            blurFilter?.setValue(12, forKey: kCIInputRadiusKey)
            if let output = blurFilter?.outputImage {
                let ciContext = CIContext(cgContext: context, options: nil)
                ciContext.draw(output, in: rect, from: sourceRect)
            }
        case .invert:
            let invertFilter = CIFilter(name: "CIColorInvert")
            invertFilter?.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
            if let output = invertFilter?.outputImage {
                let ciContext = CIContext(cgContext: context, options: nil)
                ciContext.draw(output, in: rect, from: sourceRect)
            }
        default:
            let smallWidth = max(1, Int(rect.width / 8))
            let smallHeight = max(1, Int(rect.height / 8))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let smallContext = CGContext(
                data: nil, width: smallWidth, height: smallHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            smallContext.interpolationQuality = .none
            smallContext.draw(cropped, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
            guard let smallImage = smallContext.makeImage() else { return }
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(smallImage, in: rect)
            context.restoreGState()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Mouse wheel adjusts tool stroke width like Flameshot
        let delta = event.deltaY
        guard abs(delta) > 0.1 else { return }
        if delta > 0 {
            strokeWidth = min(strokeWidth + 0.5, 20)
        } else {
            strokeWidth = max(strokeWidth - 0.5, 1)
        }
        hudView?.setStrokeWidth(strokeWidth)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right click opens quick color / tool menu like Flameshot color wheel
        let point = convert(event.locationInWindow, from: nil)
        showContextMenu(at: point)
    }

    private func showContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Flameshot Quick Menu")

        let colors: [(String, NSColor)] = [
            ("Red", .systemRed),
            ("Orange", .systemOrange),
            ("Yellow", .systemYellow),
            ("Green", .systemGreen),
            ("Blue", .systemBlue),
            ("Purple", .systemPurple),
            ("White", .white),
            ("Black", .black)
        ]

        let colorMenu = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let subMenu = NSMenu()
        for (name, col) in colors {
            let item = NSMenuItem(title: name, action: #selector(contextColorSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = col
            subMenu.addItem(item)
        }
        colorMenu.submenu = subMenu
        menu.addItem(colorMenu)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy (⌘C / Enter)", action: #selector(contextCopyAction), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let saveItem = NSMenuItem(title: "Save (⌘S)", action: #selector(contextSaveAction), keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        let pinItem = NSMenuItem(title: "Pin to Screen (⌘P)", action: #selector(contextPinAction), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let cancelItem = NSMenuItem(title: "Cancel (Esc)", action: #selector(contextCancelAction), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)

        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func contextColorSelected(_ sender: NSMenuItem) {
        if let col = sender.representedObject as? NSColor {
            currentColor = col
            hudView?.changeColor(col)
        }
    }

    @objc private func contextCopyAction() {
        if let img = renderCurrentSelectionImage(), let sel = selectionRect {
            onFinishCapture(img, sel, .copy)
        }
    }

    @objc private func contextSaveAction() {
        if let img = renderCurrentSelectionImage(), let sel = selectionRect {
            onFinishCapture(img, sel, .save)
        }
    }

    @objc private func contextPinAction() {
        if let img = renderCurrentSelectionImage(), let sel = selectionRect {
            onPinCapture(img, sel)
        }
    }

    @objc private func contextCancelAction() {
        onCancel(selectionRect)
    }

    // MARK: - Export

    func renderCurrentSelectionImage() -> NSImage? {
        guard let sel = selectionRect, sel.width > 0, sel.height > 0 else { return nil }

        // Render at full Retina resolution
        let scaleX = CGFloat(backgroundImage.width) / bounds.width
        let scaleY = CGFloat(backgroundImage.height) / bounds.height
        let pixelWidth = Int(sel.width * scaleX)
        let pixelHeight = Int(sel.height * scaleY)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw cropped background
        // In CGImage bitmap coordinate system, origin (0, 0) is top-left, while NSView is bottom-left.
        // Therefore, we must flip Y coordinate for CGImage.cropping:
        let flippedCropY = (bounds.height - sel.maxY) * scaleY
        let cropRect = CGRect(
            x: sel.origin.x * scaleX,
            y: flippedCropY,
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        )
        if let cropped = backgroundImage.cropping(to: cropRect) {
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }

        // Draw annotations scaled
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.translateBy(x: -sel.origin.x, y: -sel.origin.y)

        drawTranslatedBlocks(in: ctx, selectionRect: sel)
        for ann in annotations {
            drawAnnotation(ann, in: ctx)
        }

        guard let finalCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: finalCG, size: sel.size)
    }

    // MARK: - Keyboard Shortcuts

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Shortcuts in Live Text selection mode
        if isLiveTextMode {
            if event.keyCode == UInt16(kVK_Escape) {
                exitLiveTextMode()
                return
            }
            if flags.contains(.command) {
                if event.charactersIgnoringModifiers?.lowercased() == "c" {
                    copySelectedLiveText()
                    return
                }
                if event.charactersIgnoringModifiers?.lowercased() == "a" {
                    selectedLiveBlockIds = Set(liveTextBlocks.map(\.id))
                    updateLiveTextToolbarState()
                    needsDisplay = true
                    return
                }
            }
        }

        // 1. Esc: Cancel capture
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel(selectionRect)
            return
        }

        // Region-picking mode has no other shortcuts.
        if onRegionPicked != nil { return }

        // 2. Enter: Copy to clipboard (or Cmd+C)
        if event.keyCode == UInt16(kVK_Return) {
            triggerCopy()
            return
        }

        // 3. Delete / Backspace: remove the selected annotation
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            deleteSelectedAnnotation()
            return
        }

        // 4. Arrow keys: Move or Resize selection 1px / 2px (like Flameshot)
        if handleArrowKeys(event: event, flags: flags) {
            return
        }

        // 5. Command shortcuts (⌘C, ⌘S, ⇧⌘S, ⌘P, ⌘Z, ⇧⌘Z, ⌘Q)
        if flags.contains(.command) || flags.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                triggerCopy()
                return
            case "s":
                if flags.contains(.shift) { triggerSaveAs() } else { triggerSave() }
                return
            case "p":
                triggerPin()
                return
            case "m":
                // Move the selection area (like Flameshot's Ctrl+M).
                hudView?.selectTool(.move)
                return
            case "z":
                if flags.contains(.shift) { redo() } else { undo() }
                return
            case "q":
                onCancel(selectionRect)
                return
            default:
                break
            }
        }

        // 6. Flameshot 1-key tools shortcuts:
        // P = Pencil/Freehand, D = Line, A = Arrow, S = Selection, R = Rectangle,
        // C = Circle/Ellipse, M = Marker, T = Text, B = Blur, I = Invert, N = Counter
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p": hudView?.selectTool(.freehand)
        case "d": hudView?.selectTool(.line)
        case "a": hudView?.selectTool(.arrow)
        case "s": hudView?.selectTool(.select)
        case "r": hudView?.selectTool(.rectangle)
        case "c": hudView?.selectTool(.ellipse)
        case "m": hudView?.selectTool(.marker)
        case "t": hudView?.selectTool(.text)
        case "b": hudView?.selectTool(.blur)
        case "i": hudView?.selectTool(.invert)
        case "n": hudView?.selectTool(.counter)
        case "g": isEyedropperActive = true
        case " ":
            // Spacebar toggles HUD visibility
            if let hud = hudView {
                hud.isHidden = !hud.isHidden
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Returns `annotation` shifted by `delta`, clamped so the shape stays
    /// inside `limit` (annotations are clipped to the selection when drawn, so
    /// an unclamped move could push a shape out of sight).
    private static func moved(_ annotation: Annotation, by delta: CGPoint, within limit: CGRect) -> Annotation {
        // The shape's extent comes from its endpoints and (for freehand paths)
        // every recorded point — `bounds` alone is empty for counters.
        var xs = [annotation.start.x, annotation.end.x]
        var ys = [annotation.start.y, annotation.end.y]
        xs += annotation.points.map(\.x)
        ys += annotation.points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return annotation }

        func clamped(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            // If the shape is larger than the limit on this axis, don't move it.
            guard low <= high else { return 0 }
            return min(max(value, low), high)
        }
        let dx = clamped(delta.x, limit.minX - minX, limit.maxX - maxX)
        let dy = clamped(delta.y, limit.minY - minY, limit.maxY - maxY)
        guard dx != 0 || dy != 0 else { return annotation }

        var result = annotation
        result.start = CGPoint(x: annotation.start.x + dx, y: annotation.start.y + dy)
        result.end = CGPoint(x: annotation.end.x + dx, y: annotation.end.y + dy)
        result.points = annotation.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return result
    }

    /// Removes the annotation the user selected and makes the removal undoable.
    private func deleteSelectedAnnotation() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        let removed = annotations.remove(at: index)
        undoStack.append(removed)
        selectedAnnotationIndex = nil
        refreshCounter()
        needsDisplay = true
    }

    private func triggerCopy() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        onFinishCapture(img, sel, .copy)
    }

    private func triggerSave() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        onFinishCapture(img, sel, .save)
    }

    private func triggerSaveAs() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        onFinishCapture(img, sel, .saveAs)
    }

    private func triggerPin() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        onPinCapture(img, sel)
    }

    private func handleArrowKeys(event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard var sel = selectionRect else { return false }
        let isShift = flags.contains(.shift)
        let isControl = flags.contains(.control)

        // Shift resizes by 1px, Ctrl+Shift resizes symmetrically by 2px.
        let step: CGFloat = isShift ? (isControl ? 2 : 1) : 1
        let symmetric = isShift && isControl

        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            if isShift {
                sel.size.width = max(10, sel.size.width - step)
                if symmetric { sel.origin.x += step }
            } else {
                sel.origin.x = max(0, sel.origin.x - step)
            }
        case kVK_RightArrow:
            if isShift {
                sel.size.width = min(bounds.width - sel.origin.x, sel.size.width + step)
                if symmetric { sel.origin.x = max(0, sel.origin.x - step) }
            } else {
                sel.origin.x = min(bounds.width - sel.size.width, sel.origin.x + step)
            }
        case kVK_UpArrow:
            if isShift {
                sel.size.height = min(bounds.height - sel.origin.y, sel.size.height + step)
                if symmetric { sel.origin.y += step }
            } else {
                sel.origin.y = min(bounds.height - sel.size.height, sel.origin.y + step)
            }
        case kVK_DownArrow:
            if isShift {
                sel.size.height = max(10, sel.size.height - step)
                if symmetric { sel.origin.y = max(0, sel.origin.y - step) }
            } else {
                sel.origin.y = max(0, sel.origin.y - step)
            }
        default:
            return false
        }

        selectionRect = sel
        positionHUD(for: sel)
        needsDisplay = true
        return true
    }
}
