import AppKit
import CoreGraphics

/// Floating in-place HUD toolbar positioned directly outside the selection rectangle.
///
/// Layout is split over two rows so that the toolbar stays compact on small screens:
/// * row 1 — drawing tools + capture actions
/// * row 2 — colour palette, user presets and colour tools
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
    private var toolButtons: [Annotation.Kind: NSButton] = [:]
    private var currentTool: Annotation.Kind = .arrow
    private var currentColor: NSColor
    private var presetStack: NSStackView?

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

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.95).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)

        rows.addArrangedSubview(makeToolsRow())
        rows.addArrangedSubview(makeColorsRow())

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

    // MARK: - Rows

    private func makeToolsRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 3

        // Drawing tools
        let tools: [(Annotation.Kind, String, String)] = [
            (.arrow, "arrow.up.right", "Arrow (A)"),
            (.line, "line.diagonal", "Line (D)"),
            (.rectangle, "rectangle", "Rectangle (R)"),
            (.filledRectangle, "rectangle.fill", "Filled Rectangle"),
            (.ellipse, "circle", "Ellipse (C)"),
            (.freehand, "scribble", "Pencil (P)"),
            (.marker, "highlighter", "Marker (M)"),
            (.text, "textformat", "Text (T)"),
            (.counter, "1.circle.fill", "Step Counter (N)"),
            (.blur, "camera.filters", "Blur (B)"),
            (.pixelate, "grid", "Pixelate"),
            (.invert, "circle.lefthalf.filled", "Invert Colors (I)"),
        ]

        for (tool, icon, tip) in tools {
            let btn = createIconButton(systemName: icon, tooltip: tip) { [weak self] in
                self?.selectTool(tool)
            }
            toolButtons[tool] = btn
            row.addArrangedSubview(btn)
        }

        row.addArrangedSubview(createSeparator())

        // Capture actions
        let undoBtn = createIconButton(systemName: "arrow.uturn.backward", tooltip: "Undo (⌘Z)") { [weak self] in
            self?.onAction(.undo)
        }
        row.addArrangedSubview(undoBtn)

        let redoBtn = createIconButton(systemName: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)") { [weak self] in
            self?.onAction(.redo)
        }
        row.addArrangedSubview(redoBtn)

        let pinBtn = createIconButton(systemName: "pin.fill", tooltip: "Pin to Screen (⌘P)") { [weak self] in
            self?.onAction(.pin)
        }
        pinBtn.contentTintColor = .systemYellow
        row.addArrangedSubview(pinBtn)

        let copyBtn = createIconButton(systemName: "doc.on.clipboard.fill", tooltip: "Copy (⌘C / Enter)") { [weak self] in
            self?.onAction(.copy)
        }
        copyBtn.contentTintColor = .systemTeal
        row.addArrangedSubview(copyBtn)

        let saveBtn = createIconButton(systemName: "square.and.arrow.down.fill", tooltip: "Save (⌘S)") { [weak self] in
            self?.onAction(.save)
        }
        saveBtn.contentTintColor = .systemBlue
        row.addArrangedSubview(saveBtn)

        let saveAsBtn = createIconButton(systemName: "square.and.arrow.down.on.square", tooltip: "Save As… (⇧⌘S)") { [weak self] in
            self?.onAction(.saveAs)
        }
        saveAsBtn.contentTintColor = .systemBlue
        row.addArrangedSubview(saveAsBtn)

        let cancelBtn = createIconButton(systemName: "xmark", tooltip: "Cancel (Esc)") { [weak self] in
            self?.onAction(.cancel)
        }
        cancelBtn.contentTintColor = .systemRed
        row.addArrangedSubview(cancelBtn)

        return row
    }

    private func makeColorsRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 3

        // Default palette
        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow,
            .systemGreen, .systemBlue, .systemPurple,
            .white, .black
        ]
        for color in colors {
            let dot = createColorButton(color: color) { [weak self] in
                self?.currentColor = color
                self?.onAction(.changeColor(color))
            }
            row.addArrangedSubview(dot)
        }

        // User presets
        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 3
        row.addArrangedSubview(presets)
        presetStack = presets

        row.addArrangedSubview(createSeparator())

        let pickerBtn = createIconButton(systemName: "paintpalette", tooltip: "Custom Color…") { [weak self] in
            self?.openColorPanel()
        }
        row.addArrangedSubview(pickerBtn)

        let dropperBtn = createIconButton(systemName: "eyedropper", tooltip: "Pick Color From Screen (G)") { [weak self] in
            self?.onAction(.eyedropper)
        }
        row.addArrangedSubview(dropperBtn)

        let addPresetBtn = createIconButton(systemName: "plus.circle", tooltip: "Add Current Color To Palette") { [weak self] in
            self?.onAction(.addColorPreset)
        }
        row.addArrangedSubview(addPresetBtn)

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
            let dot = createColorButton(color: color) { [weak self] in
                self?.currentColor = color
                self?.onAction(.changeColor(color))
            }
            presetStack.addArrangedSubview(dot)
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
                btn.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
                btn.layer?.cornerRadius = 4
            } else {
                btn.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        onAction(.selectTool(tool))
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

    private func createIconButton(systemName: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: tooltip) ?? NSImage()
        let btn = ClosureButton(image: image, action: action)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.contentTintColor = .white
        btn.wantsLayer = true
        btn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return btn
    }

    private func createColorButton(color: NSColor, action: @escaping () -> Void) -> NSButton {
        let btn = ClosureButton(image: NSImage(), action: action)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 8
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        btn.layer?.borderWidth = 1
        btn.widthAnchor.constraint(equalToConstant: 16).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return btn
    }

    private func createSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return sep
    }
}

// MARK: - Closure-based NSButton Helper

private final class ClosureButton: NSButton {
    private let actionClosure: () -> Void

    init(image: NSImage, action: @escaping () -> Void) {
        self.actionClosure = action
        super.init(frame: .zero)
        self.image = image
        self.target = self
        self.action = #selector(buttonTapped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func buttonTapped() {
        actionClosure()
    }
}
