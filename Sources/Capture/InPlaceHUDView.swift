import AppKit
import CoreGraphics

/// Floating in-place HUD toolbar positioned directly outside the selection rectangle.
/// Contains tool buttons, color indicators, undo, redo, pin, copy, save and cancel.
final class InPlaceHUDView: NSView {
    enum Action {
        case selectTool(Annotation.Kind)
        case changeColor(NSColor)
        case undo
        case redo
        case pin
        case copy
        case save
        case cancel
    }

    private let onAction: (Action) -> Void
    private var toolButtons: [Annotation.Kind: NSButton] = [:]
    private var currentTool: Annotation.Kind = .arrow
    private var currentColor: NSColor

    init(initialColor: NSColor = .systemRed, onAction: @escaping (Action) -> Void) {
        self.currentColor = initialColor
        self.onAction = onAction
        super.init(frame: .zero)
        setupUI()
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

        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.spacing = 3
        mainStack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)

        // 1. Drawing tools: Arrow, Line, Rect, FilledRect, Circle, Pencil, Marker, Text, Counter, Blur, Pixelate
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
        ]

        for (tool, icon, tip) in tools {
            let btn = createIconButton(systemName: icon, tooltip: tip) { [weak self] in
                self?.selectTool(tool)
            }
            toolButtons[tool] = btn
            mainStack.addArrangedSubview(btn)
        }

        mainStack.addArrangedSubview(createSeparator())

        // 2. Color Palette buttons (Red, Orange, Yellow, Green, Blue, Purple, White, Black)
        let colors: [NSColor] = [
            .systemRed, .systemOrange, .systemYellow,
            .systemGreen, .systemBlue, .systemPurple,
            .white, .black
        ]

        let colorStack = NSStackView()
        colorStack.orientation = .horizontal
        colorStack.spacing = 3

        for color in colors {
            let colorDot = createColorButton(color: color) { [weak self] in
                self?.currentColor = color
                self?.onAction(.changeColor(color))
            }
            colorStack.addArrangedSubview(colorDot)
        }
        mainStack.addArrangedSubview(colorStack)

        mainStack.addArrangedSubview(createSeparator())

        // 3. Actions: Undo, Redo, Pin, Copy, Save, Cancel
        let undoBtn = createIconButton(systemName: "arrow.uturn.backward", tooltip: "Undo (⌘Z)") { [weak self] in
            self?.onAction(.undo)
        }
        mainStack.addArrangedSubview(undoBtn)

        let redoBtn = createIconButton(systemName: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)") { [weak self] in
            self?.onAction(.redo)
        }
        mainStack.addArrangedSubview(redoBtn)

        let pinBtn = createIconButton(systemName: "pin.fill", tooltip: "Pin to Screen (⌘P)") { [weak self] in
            self?.onAction(.pin)
        }
        pinBtn.contentTintColor = .systemYellow
        mainStack.addArrangedSubview(pinBtn)

        let copyBtn = createIconButton(systemName: "doc.on.clipboard.fill", tooltip: "Copy (⌘C / Enter)") { [weak self] in
            self?.onAction(.copy)
        }
        copyBtn.contentTintColor = .systemTeal
        mainStack.addArrangedSubview(copyBtn)

        let saveBtn = createIconButton(systemName: "square.and.arrow.down.fill", tooltip: "Save (⌘S)") { [weak self] in
            self?.onAction(.save)
        }
        saveBtn.contentTintColor = .systemBlue
        mainStack.addArrangedSubview(saveBtn)

        let cancelBtn = createIconButton(systemName: "xmark", tooltip: "Cancel (Esc)") { [weak self] in
            self?.onAction(.cancel)
        }
        cancelBtn.contentTintColor = .systemRed
        mainStack.addArrangedSubview(cancelBtn)

        addSubview(mainStack)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        selectTool(.arrow)
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
