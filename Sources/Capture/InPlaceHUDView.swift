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
        case changeStrokeWidth(CGFloat)
        case addColorPreset
        case openColorPicker
        case eyedropper
        case undo
        case redo
        case pin
        case translate
        case copy
        case save
        case saveAs
        case cancel
    }

    private let onAction: (Action) -> Void
    private var toolButtons: [Annotation.Kind: TileButton] = [:]
    private var colorButtons: [TileButton] = []
    private var currentTool: Annotation.Kind = .arrow
    private var currentColor: NSColor
    private var currentStrokeWidth: CGFloat
    private var presetStack: NSStackView?
    private let statusLabel = NSTextField(labelWithString: "")
    private let strokeWidthLabel = NSTextField(labelWithString: "")

    init(initialColor: NSColor = .systemRed, initialStrokeWidth: CGFloat = 3, presets: [NSColor] = [], onAction: @escaping (Action) -> Void) {
        self.currentColor = initialColor
        self.currentStrokeWidth = initialStrokeWidth
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
        // The HUD is always dark glass, whatever the system appearance is —
        // forcing dark aqua also makes every label and tint inside render in
        // its light variant, so text stays readable on the dark panel.
        appearance = NSAppearance(named: .darkAqua)

        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.shadowRadius = 16

        // Real frosted glass behind the controls: blurs the captured screen
        // showing through the (transparent) overlay window.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // A whisper of dark tint over the glass keeps white icons crisp even
        // over a bright desktop.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        tint.layer?.cornerRadius = 16
        tint.layer?.masksToBounds = true
        addSubview(tint)
        tint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 7
        rows.alignment = .leading
        rows.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

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
        refreshColorSelection()
    }

    /// Row 1: the drawing tools, each purpose group in its own subtle pill.
    private func makeToolsRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        // Group 1 — move & select
        row.addArrangedSubview(makeGroupPill([
            createToolButton(.move, symbol: "hand.raised", name: "Move Selection"),
            createToolButton(.select, symbol: "cursorarrow.click.2", name: "Select Object")
        ]))

        // Group 2 — shapes
        row.addArrangedSubview(makeGroupPill([
            createToolButton(.arrow, symbol: "arrow.up.right", name: "Arrow"),
            createToolButton(.line, symbol: "line.diagonal", name: "Line"),
            createToolButton(.rectangle, symbol: "rectangle", name: "Rectangle"),
            createToolButton(.filledRectangle, symbol: "rectangle.fill", name: "Filled Rectangle"),
            createToolButton(.ellipse, symbol: "circle", name: "Ellipse")
        ]))

        // Group 3 — freehand & text
        row.addArrangedSubview(makeGroupPill([
            createToolButton(.freehand, symbol: "pencil.tip", name: "Pencil"),
            createToolButton(.marker, symbol: "highlighter", name: "Marker"),
            createToolButton(.text, symbol: "textformat", name: "Text"),
            createToolButton(.counter, symbol: "1.circle.fill", name: "Step Counter")
        ]))

        // Group 4 — effects
        row.addArrangedSubview(makeGroupPill([
            createToolButton(.blur, symbol: "drop", name: "Blur"),
            createToolButton(.pixelate, symbol: "square.grid.3x3", name: "Pixelate"),
            createToolButton(.invert, symbol: "circle.lefthalf.filled.inverse", name: "Invert Colors")
        ]))

        // Group 5 — stroke width (also adjustable with the scroll wheel)
        let minusButton = createIconButton(
            symbol: "minus", name: "Thinner stroke", tint: .labelColor
        ) { [weak self] in
            self?.adjustStrokeWidth(by: -1)
        }
        strokeWidthLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        strokeWidthLabel.textColor = .labelColor
        strokeWidthLabel.alignment = .center
        strokeWidthLabel.toolTip = "Stroke width"
        strokeWidthLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let plusButton = createIconButton(
            symbol: "plus", name: "Thicker stroke", tint: .labelColor
        ) { [weak self] in
            self?.adjustStrokeWidth(by: 1)
        }
        row.addArrangedSubview(makeGroupPill([minusButton, strokeWidthLabel, plusButton]))
        updateStrokeWidthLabel()

        return row
    }

    /// Wraps a group of controls in a soft pill so the groups read at a glance.
    private func makeGroupPill(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        pill.layer?.cornerRadius = 11
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
        pill.layer?.borderWidth = 1
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor)
        ])
        return pill
    }

    /// Row 2: colours on the left, the status label in the middle, actions on the right.
    private func makeBottomRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        // Colour palette (built-in swatches + user presets) in one pill
        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow,
            .systemGreen, .systemBlue, .systemPurple,
            .white, .black
        ]
        var paletteViews: [NSView] = colors.map { createColorButton(color: $0, name: "Colour") }

        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 3
        paletteViews.append(presets)
        presetStack = presets
        row.addArrangedSubview(makeGroupPill(paletteViews))

        // Colour tools in one pill
        row.addArrangedSubview(makeGroupPill([
            createIconButton(
                symbol: "plus.circle", name: "Add colour to palette", tint: .labelColor
            ) { [weak self] in
                self?.onAction(.addColorPreset)
            },
            createIconButton(
                symbol: "paintpalette", name: "Custom colour…", tint: .labelColor
            ) { [weak self] in
                self?.openColorPanel()
            },
            createIconButton(
                symbol: "eyedropper", name: "Pick colour from screen (G)", tint: .labelColor
            ) { [weak self] in
                self?.onAction(.eyedropper)
            }
        ]))

        // Status label — always shows what the hovered/active tool does.
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        row.addArrangedSubview(statusLabel)

        // Undo / redo in one pill
        row.addArrangedSubview(makeGroupPill([
            createIconButton(
                symbol: "arrow.uturn.backward", name: "Undo (⌘Z)", tint: .labelColor
            ) { [weak self] in
                self?.onAction(.undo)
            },
            createIconButton(
                symbol: "arrow.uturn.forward", name: "Redo (⇧⌘Z)", tint: .labelColor
            ) { [weak self] in
                self?.onAction(.redo)
            }
        ]))

        // Finish actions in one pill
        row.addArrangedSubview(makeGroupPill([
            createIconButton(
                symbol: "character.bubble.fill", name: "Translate text in selection", tint: .systemGreen
            ) { [weak self] in
                self?.onAction(.translate)
            },
            createIconButton(
                symbol: "pin.fill", name: "Pin to screen (⌘P)", tint: .systemYellow
            ) { [weak self] in
                self?.onAction(.pin)
            },
            createIconButton(
                symbol: "doc.on.clipboard.fill", name: "Copy (⌘C / Enter)", tint: .systemTeal
            ) { [weak self] in
                self?.onAction(.copy)
            },
            createIconButton(
                symbol: "square.and.arrow.down.fill", name: "Save (⌘S)", tint: .systemBlue
            ) { [weak self] in
                self?.onAction(.save)
            },
            createIconButton(
                symbol: "square.and.arrow.down.on.square", name: "Save as… (⇧⌘S)", tint: .systemBlue
            ) { [weak self] in
                self?.onAction(.saveAs)
            },
            createIconButton(
                symbol: "xmark", name: "Cancel (Esc)", tint: .systemRed
            ) { [weak self] in
                self?.onAction(.cancel)
            }
        ]))

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
        refreshColorSelection()
    }

    func changeColor(_ color: NSColor) {
        currentColor = color
        refreshColorSelection()
        onAction(.changeColor(color))
    }

    /// Updates the stroke width display without firing an action — used when the
    /// width changes elsewhere (the scroll wheel on the canvas).
    func setStrokeWidth(_ width: CGFloat) {
        currentStrokeWidth = min(max(width, 1), 20)
        updateStrokeWidthLabel()
    }

    private func adjustStrokeWidth(by delta: CGFloat) {
        setStrokeWidth(currentStrokeWidth + delta)
        onAction(.changeStrokeWidth(currentStrokeWidth))
    }

    private func updateStrokeWidthLabel() {
        if currentStrokeWidth == currentStrokeWidth.rounded() {
            strokeWidthLabel.stringValue = "\(Int(currentStrokeWidth))"
        } else {
            strokeWidthLabel.stringValue = String(format: "%.1f", currentStrokeWidth)
        }
    }

    /// Highlights the palette swatch that matches the current colour.
    private func refreshColorSelection() {
        for btn in colorButtons where btn.superview != nil {
            btn.isActive = Self.colorsMatch(btn.swatchColor, currentColor)
        }
    }

    private static func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let aRGB = a.usingColorSpace(.deviceRGB),
              let bRGB = b.usingColorSpace(.deviceRGB) else {
            return a == b
        }
        return abs(aRGB.redComponent - bRGB.redComponent) < 0.02
            && abs(aRGB.greenComponent - bRGB.greenComponent) < 0.02
            && abs(aRGB.blueComponent - bRGB.blueComponent) < 0.02
            && abs(aRGB.alphaComponent - bRGB.alphaComponent) < 0.02
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
        refreshColorSelection()
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
        // A slightly larger, semibold symbol reads much better in a 32pt tile.
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
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
        let btn = TileButton(image: NSImage(), name: name, action: { [weak self] in
            self?.changeColor(color)
        }, size: 24)
        btn.isColorSwatch = true
        btn.swatchColor = color
        btn.contentTintColor = .labelColor
        colorButtons.append(btn)
        return btn
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

    /// The tile's edge length (colour swatches are drawn as circles of it).
    private let tileSize: CGFloat

    init(image: NSImage, name: String, action: @escaping () -> Void, size: CGFloat = 32) {
        self.actionClosure = action
        self.tileSize = size
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
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0

        if isColorSwatch {
            // Swatches are circles, not rounded squares.
            layer?.cornerRadius = tileSize / 2
            layer?.backgroundColor = swatchColor.cgColor
            if isActive {
                // The currently selected colour gets a thick bright ring.
                layer?.borderColor = NSColor.white.cgColor
                layer?.borderWidth = 3
            } else if hoverActive {
                layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
                layer?.borderWidth = 2
            } else {
                layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
                layer?.borderWidth = 1.5
            }
            return
        }

        layer?.cornerRadius = 9
        if isActive {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
            // A soft blue glow lifts the active tool off the glass.
            layer?.shadowColor = NSColor.systemBlue.cgColor
            layer?.shadowOpacity = 0.55
            layer?.shadowRadius = 7
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        } else if hoverActive {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
        }
    }
}
