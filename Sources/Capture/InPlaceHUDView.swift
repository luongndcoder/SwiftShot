import AppKit
import CoreGraphics

/// Floating in-place HUD toolbar positioned directly outside the selection rectangle.
///
/// Design goals:
/// * every button is a rounded "tile" that highlights on hover, so it is obvious
///   which icon reacts to the mouse
/// * the tiles are grouped by purpose (move/select · shapes · freehand · effects)
/// * a status label always shows what the hovered (or active) tool does, so the
///   icons never have to be guessed
/// * the layout is split over two rows to stay compact on small screens
final class InPlaceHUDView: NSView {
    enum Action {
        case selectTool(Annotation.Kind)
        case changeColor(NSColor)
        case addColorPreset
        case openColorPicker
        case eyedropper
        case undo
        case redo
        case pin
        case copy
        case save
        case saveAs
        case cancel
    }

    private let onAction: (Action) -> Void
    private var toolButtons: [Annotation.Kind: TileButton] = [:]
    private var currentTool: Annotation.Kind = .arrow
    private var currentColor: NSColor
    private var presetStack: NSStackView?
    private let statusLabel = NSTextField(labelWithString: "")

    init(initialColor: NSColor = .systemRed, presets: [NSColor] = [], onAction: @escaping (Action) -> Void) {
        self.currentColor = initialColor
        self.onAction = onAction
        super.init(frame: .zero)
        setupUI()
        setPresets(presets)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.92).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 12

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 6
        rows.alignment = .leading
        rows.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)

        rows.addArrangedSubview(makeToolsRow())
        rows.addArrangedSubview(makeBottomRow())

        addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        selectTool(.arrow)
    }

    /// Row 1: the drawing tools, grouped by purpose.
    private func makeToolsRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4

        // Group 1 — move & select
        row.addArrangedSubview(createToolButton(.move, symbol: "hand.raised", name: "Move Selection"))
        row.addArrangedSubview(createToolButton(.select, symbol: "cursorarrow.click.2", name: "Select Object"))
        row.addArrangedSubview(makeSeparator())

        // Group 2 — shapes
        row.addArrangedSubview(createToolButton(.arrow, symbol: "arrow.up.right", name: "Arrow"))
        row.addArrangedSubview(createToolButton(.line, symbol: "line.diagonal", name: "Line"))
        row.addArrangedSubview(createToolButton(.rectangle, symbol: "rectangle", name: "Rectangle"))
        row.addArrangedSubview(createToolButton(.filledRectangle, symbol: "rectangle.fill", name: "Filled Rectangle"))
        row.addArrangedSubview(createToolButton(.ellipse, symbol: "circle", name: "Ellipse"))
        row.addArrangedSubview(makeSeparator())

        // Group 3 — freehand & text
        row.addArrangedSubview(createToolButton(.freehand, symbol: "pencil.tip", name: "Pencil"))
        row.addArrangedSubview(createToolButton(.marker, symbol: "highlighter", name: "Marker"))
        row.addArrangedSubview(createToolButton(.text, symbol: "textformat", name: "Text"))
        row.addArrangedSubview(createToolButton(.counter, symbol: "1.circle.fill", name: "Step Counter"))
        row.addArrangedSubview(makeSeparator())

        // Group 4 — effects
        row.addArrangedSubview(createToolButton(.blur, symbol: "drop", name: "Blur"))
        row.addArrangedSubview(createToolButton(.pixelate, symbol: "square.grid.3x3", name: "Pixelate"))
        row.addArrangedSubview(createToolButton(.invert, symbol: "circle.lefthalf.filled.inverse", name: "Invert Colors"))

        return row
    }

    /// Row 2: colours on the left, the status label in the middle, actions on the right.
    private func makeBottomRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        // Colour palette
        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow,
            .systemGreen, .systemBlue, .systemPurple,
            .white, .black
        ]
        for color in colors {
            row.addArrangedSubview(createColorButton(color: color, name: "Colour"))
        }

        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 3
        row.addArrangedSubview(presets)
        presetStack = presets

        row.addArrangedSubview(makeSeparator())

        // Colour tools
        row.addArrangedSubview(createIconButton(
            symbol: "plus.circle", name: "Add colour to palette", tint: .labelColor
        ) { [weak self] in
            self?.onAction(.addColorPreset)
        })
        row.addArrangedSubview(createIconButton(
            symbol: "paintpalette", name: "Custom colour…", tint: .labelColor
        ) { [weak self] in
            self?.openColorPanel()
        })
        row.addArrangedSubview(createIconButton(
            symbol: "eyedropper", name: "Pick colour from screen (G)", tint: .labelColor
        ) { [weak self] in
            self?.onAction(.eyedropper)
        })

        row.addArrangedSubview(makeSeparator())

        // Status label — always shows what the hovered/active tool does.
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        row.addArrangedSubview(statusLabel)

        // Actions
        row.addArrangedSubview(createIconButton(
            symbol: "arrow.uturn.backward", name: "Undo (⌘Z)", tint: .labelColor
        ) { [weak self] in
            self?.onAction(.undo)
        })
        row.addArrangedSubview(createIconButton(
            symbol: "arrow.uturn.forward", name: "Redo (⇧⌘Z)", tint: .labelColor
        ) { [weak self] in
            self?.onAction(.redo)
        })
        row.addArrangedSubview(makeSeparator())
        row.addArrangedSubview(createIconButton(
            symbol: "pin.fill", name: "Pin to screen (⌘P)", tint: .systemYellow
        ) { [weak self] in
            self?.onAction(.pin)
        })
        row.addArrangedSubview(createIconButton(
            symbol: "doc.on.clipboard.fill", name: "Copy (⌘C / Enter)", tint: .systemTeal
        ) { [weak self] in
            self?.onAction(.copy)
        })
        row.addArrangedSubview(createIconButton(
            symbol: "square.and.arrow.down.fill", name: "Save (⌘S)", tint: .systemBlue
        ) { [weak self] in
            self?.onAction(.save)
        })
        row.addArrangedSubview(createIconButton(
            symbol: "square.and.arrow.down.on.square", name: "Save as… (⇧⌘S)", tint: .systemBlue
        ) { [weak self] in
            self?.onAction(.saveAs)
        })
        row.addArrangedSubview(createIconButton(
            symbol: "xmark", name: "Cancel (Esc)", tint: .systemRed
        ) { [weak self] in
            self?.onAction(.cancel)
        })

        return row
    }

    // MARK: - Public API

    /// Replaces the user defined colour presets shown in the palette.
    func setPresets(_ colors: [NSColor]) {
        guard let presetStack else { return }
        for view in presetStack.arrangedSubviews {
            presetStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for color in colors {
            presetStack.addArrangedSubview(createColorButton(color: color, name: "Preset colour"))
        }
    }

    func changeColor(_ color: NSColor) {
        currentColor = color
        onAction(.changeColor(color))
    }

    func selectTool(_ tool: Annotation.Kind) {
        currentTool = tool
        for (kind, btn) in toolButtons {
            if kind == tool {
                btn.isActive = true
            } else {
                btn.isActive = false
            }
        }
        updateStatus(for: tool)
        onAction(.selectTool(tool))
    }

    /// Shows the description of a tool in the status label.
    private func updateStatus(for tool: Annotation.Kind) {
        statusLabel.stringValue = Self.name(for: tool)
    }

    private static func name(for tool: Annotation.Kind) -> String {
        switch tool {
        case .move: return "Move Selection"
        case .select: return "Select Object"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .freehand: return "Pencil"
        case .marker: return "Marker"
        case .text: return "Text"
        case .counter: return "Step Counter"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .invert: return "Invert Colors"
        }
    }

    // MARK: - Colour panel

    /// Opens the system colour panel on top of the capture overlay.
    private func openColorPanel() {
        let panel = NSColorPanel.shared
        // The capture overlay lives on the .screenSaver level — the shared colour
        // panel has to be raised as well, otherwise it would be hidden behind it.
        panel.level = .screenSaver + 1
        panel.showsAlpha = true
        panel.isFloatingPanel = true
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = currentColor
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        let color = sender.color
        currentColor = color
        onAction(.changeColor(color))
    }

    // MARK: - Button factories

    private func createToolButton(_ tool: Annotation.Kind, symbol: String, name: String) -> NSButton {
        let btn = createIconButton(symbol: symbol, name: name, tint: .labelColor) { [weak self] in
            self?.selectTool(tool)
        }
        toolButtons[tool] = btn
        return btn
    }

    private func createIconButton(
        symbol: String,
        name: String,
        tint: NSColor,
        action: @escaping () -> Void
    ) -> TileButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage()
        // A slightly larger, medium weight symbol reads much better in a 28pt tile.
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let sized = image.withSymbolConfiguration(configuration) ?? image
        let btn = TileButton(image: sized, name: name, action: action)
        btn.contentTintColor = tint
        btn.onHover = { [weak self] hovered in
            guard let self else { return }
            if let hovered {
                self.statusLabel.stringValue = hovered
                self.statusLabel.textColor = .labelColor
            } else {
                self.statusLabel.textColor = .secondaryLabelColor
                self.updateStatus(for: self.currentTool)
            }
        }
        return btn
    }

    private func createColorButton(color: NSColor, name: String) -> NSButton {
        let btn = TileButton(image: NSImage(), name: name, action: {}, size: 22)
        btn.isColorSwatch = true
        btn.swatchColor = color
        btn.contentTintColor = .labelColor
        return btn
    }

    private func makeSeparator() -> NSView {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return sep
    }
}

// MARK: - Tile button

/// A rounded icon tile that highlights on hover and stays highlighted while active.
final class TileButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var hoverActive = false
    private let actionClosure: () -> Void

    /// Draws the button as a colour swatch instead of an icon.
    var isColorSwatch = false {
        didSet { updateAppearance() }
    }

    var swatchColor: NSColor = .systemRed {
        didSet { updateAppearance() }
    }

    /// The highlighted (selected) state.
    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    /// Called with the description while the mouse hovers the tile.
    var onHover: ((String?) -> Void)?

    init(image: NSImage, name: String, action: @escaping () -> Void, size: CGFloat = 28) {
        self.actionClosure = action
        super.init(frame: .zero)
        self.image = image
        self.target = self
        self.action = #selector(tileTapped)
        self.toolTip = name
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.wantsLayer = true
        self.focusRingType = .none
        self.widthAnchor.constraint(equalToConstant: size).isActive = true
        self.heightAnchor.constraint(equalToConstant: size).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func tileTapped() {
        actionClosure()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingAreaRef {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverActive = true
        updateAppearance()
        onHover?(toolTip)
    }

    override func mouseExited(with event: NSEvent) {
        hoverActive = false
        updateAppearance()
        onHover?(nil)
    }

    private func updateAppearance() {
        layer?.cornerRadius = 7
        layer?.borderWidth = 1

        if isColorSwatch {
            layer?.backgroundColor = swatchColor.cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
            layer?.borderWidth = 1.5
            return
        }

        if isActive {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        } else if hoverActive {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
