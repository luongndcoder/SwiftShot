import AppKit
import CoreGraphics
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
    var currentColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 3.5
    private var annotations: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var undoStack: [Annotation] = []
    private var currentCounter = 1

    // Subviews
    private var hudView: InPlaceHUDView?
    private var activeTextView: InPlaceTextView?
    private var magnifierView: MagnifierView?

    // Callbacks
    private let onFinishCapture: (NSImage, CGRect) -> Void
    private let onPinCapture: (NSImage, CGRect) -> Void
    private let onCancel: () -> Void

    init(
        backgroundImage: CGImage,
        screenFrame: NSRect,
        onFinishCapture: @escaping (NSImage, CGRect) -> Void,
        onPinCapture: @escaping (NSImage, CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.backgroundImage = backgroundImage
        self.screenFrame = screenFrame
        self.onFinishCapture = onFinishCapture
        self.onPinCapture = onPinCapture
        self.onCancel = onCancel
        super.init(frame: screenFrame)

        setupHUD()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupHUD() {
        let hud = InPlaceHUDView { [weak self] action in
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
        // Show magnifier when no selection is made yet, or when in select mode
        if selectionRect == nil || isSelecting {
            magnifierView?.isHidden = false
            magnifierView?.update(at: point, in: bounds, backgroundImage: backgroundImage, scale: 2.0)
        } else {
            magnifierView?.isHidden = true
        }
    }

    // MARK: - HUD Actions

    private func handleHUDAction(_ action: InPlaceHUDView.Action) {
        switch action {
        case .selectTool(let tool):
            selectedTool = tool
        case .changeColor(let color):
            currentColor = color
        case .undo:
            undo()
        case .redo:
            redo()
        case .pin:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            onPinCapture(img, sel)
        case .copy:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            Clipboard.copy(img)
            onFinishCapture(img, sel)
        case .save:
            guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
            onFinishCapture(img, sel)
        case .cancel:
            onCancel()
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 1. If HUD is clicked, don't handle here
        if let hud = hudView, !hud.isHidden, hud.frame.contains(point) {
            super.mouseDown(with: event)
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
            hudView?.isHidden = true
            return
        }

        // 4. Check if moving whole selection (if spacebar or Alt or tool == .select)
        if event.modifierFlags.contains(.option) || selectedTool == .select {
            if sel.contains(point) {
                isMovingSelection = true
                dragStartPoint = point
                initialSelectionRect = sel
                hudView?.isHidden = true
                return
            }
        }

        // 5. Drawing tools inside selection
        if sel.contains(point) {
            handleDrawingMouseDown(at: point)
            return
        }

        // 6. Clicked outside selection -> start new selection
        isSelecting = true
        dragStartPoint = point
        selectionRect = CGRect(origin: point, size: .zero)
        annotations.removeAll()
        currentCounter = 1
        hudView?.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)

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
            selectionRect = resizeSelection(from: initialSelectionRect, handle: activeHandle, currentPoint: current)
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

        // Drawing dragged
        if var ann = currentAnnotation {
            switch ann.kind {
            case .freehand, .marker:
                ann.points.append(current)
                ann.end = current
            default:
                ann.end = current
            }
            currentAnnotation = ann
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let current = convert(event.locationInWindow, from: nil)

        if isSelecting {
            isSelecting = false
            guard var sel = selectionRect else { return }
            // Click without drag = full screen
            if sel.width < 5 && sel.height < 5 {
                sel = bounds
                selectionRect = sel
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
            let textView = InPlaceTextView(
                at: point,
                textColor: currentColor,
                fontSize: max(16, strokeWidth * 5),
                onCommit: { [weak self] text in
                    guard let self else { return }
                    let ann = Annotation(
                        kind: .text, points: [], start: point, end: point,
                        color: self.currentColor, strokeWidth: self.strokeWidth,
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
        if last.kind == .counter && currentCounter > 1 {
            currentCounter -= 1
        }
        needsDisplay = true
    }

    func redo() {
        guard let last = undoStack.popLast() else { return }
        annotations.append(last)
        if last.kind == .counter {
            currentCounter += 1
        }
        needsDisplay = true
    }

    // MARK: - Handles & Selection Management

    private func detectHandle(at point: CGPoint, in rect: CGRect) -> Handle {
        let handleSize: CGFloat = 10
        let handles: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topMiddle, CGPoint(x: rect.midX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.middleLeft, CGPoint(x: rect.minX, y: rect.midY)),
            (.middleRight, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomMiddle, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
        ]
        for (h, p) in handles {
            let hitRect = CGRect(x: p.x - handleSize, y: p.y - handleSize, width: handleSize * 2, height: handleSize * 2)
            if hitRect.contains(point) {
                return h
            }
        }
        return .none
    }

    private func resizeSelection(from rect: CGRect, handle: Handle, currentPoint: CGPoint) -> CGRect {
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
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func positionHUD(for rect: CGRect) {
        guard let hud = hudView else { return }
        hud.isHidden = false
        hud.layoutSubtreeIfNeeded()

        let hudWidth: CGFloat = 680
        let hudHeight: CGFloat = 38
        var hudX = rect.midX - hudWidth / 2
        var hudY = rect.minY - hudHeight - 10

        // Keep HUD on-screen
        if hudY < 10 {
            // Place on top if bottom edge is clipped
            hudY = rect.maxY + 10
        }
        if hudX < 10 { hudX = 10 }
        if hudX + hudWidth > bounds.width - 10 {
            hudX = bounds.width - hudWidth - 10
        }

        hud.frame = CGRect(x: hudX, y: hudY, width: hudWidth, height: hudHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw raw desktop snapshot background
        context.draw(backgroundImage, in: bounds)

        // 2. Draw crisp punch-through selection or dimmed overlay
        if let sel = selectionRect, sel.width > 0, sel.height > 0 {
            // Fill dimming only outside selection rect
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)

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
            for ann in annotations {
                drawAnnotation(ann, in: context)
            }
            if let current = currentAnnotation {
                drawAnnotation(current, in: context)
            }
            context.restoreGState()

            // Draw selection borders & 8 handles
            drawSelectionBorderAndHandles(sel, in: context)

            // Draw size indicator W × H
            drawSizeLabel(for: sel, in: context)
        } else {
            // No selection yet: subtle dim overlay (20% opacity like Flameshot)
            context.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
            context.fill(bounds)
        }
    }

    private func drawSelectionBorderAndHandles(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.stroke(rect)

        let handleSize: CGFloat = 8
        let handlePoints = [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
        ]

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)

        for p in handlePoints {
            let hRect = CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
            context.fill(hRect)
            context.stroke(hRect)
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
        case .select:
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
        case .blur, .pixelate:
            drawBlurOrPixelate(ann: ann, in: context)
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

    private func drawBlurOrPixelate(ann: Annotation, in context: CGContext) {
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

        if ann.kind == .blur {
            let blurFilter = CIFilter(name: "CIGaussianBlur")
            blurFilter?.setValue(CIImage(cgImage: cropped), forKey: kCIInputImageKey)
            blurFilter?.setValue(12, forKey: kCIInputRadiusKey)
            if let output = blurFilter?.outputImage {
                let ciContext = CIContext(cgContext: context, options: nil)
                ciContext.draw(output, in: rect, from: cropRect)
            }
        } else {
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
            context.interpolationQuality = .none
            context.draw(smallImage, in: rect)
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
            Clipboard.copy(img)
            onFinishCapture(img, sel)
        }
    }

    @objc private func contextSaveAction() {
        if let img = renderCurrentSelectionImage(), let sel = selectionRect {
            onFinishCapture(img, sel)
        }
    }

    @objc private func contextPinAction() {
        if let img = renderCurrentSelectionImage(), let sel = selectionRect {
            onPinCapture(img, sel)
        }
    }

    @objc private func contextCancelAction() {
        onCancel()
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

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        for ann in annotations {
            drawAnnotation(ann, in: ctx)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let finalCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: finalCG, size: sel.size)
    }

    // MARK: - Keyboard Shortcuts

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 1. Esc: Cancel capture
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel()
            return
        }

        // 2. Enter: Copy to clipboard (or Cmd+C)
        if event.keyCode == UInt16(kVK_Return) {
            triggerCopy()
            return
        }

        // 3. Arrow keys: Move or Resize selection 1px / 2px (like Flameshot)
        if handleArrowKeys(event: event, flags: flags) {
            return
        }

        // 4. Command shortcuts (⌘C, ⌘S, ⌘P, ⌘Z, ⇧⌘Z, ⌘Q)
        if flags.contains(.command) || flags.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                triggerCopy()
                return
            case "s":
                triggerSave()
                return
            case "p":
                triggerPin()
                return
            case "z":
                if flags.contains(.shift) { redo() } else { undo() }
                return
            case "q":
                onCancel()
                return
            default:
                break
            }
        }

        // 5. Flameshot 1-key tools shortcuts:
        // P = Pencil/Freehand, D = Line, A = Arrow, S = Selection, R = Rectangle,
        // C = Circle/Ellipse, M = Marker, T = Text, B = Blur, N = Step Counter
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
        case "n": hudView?.selectTool(.counter)
        case " ":
            // Spacebar toggles HUD visibility
            if let hud = hudView {
                hud.isHidden = !hud.isHidden
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func triggerCopy() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        Clipboard.copy(img)
        onFinishCapture(img, sel)
    }

    private func triggerSave() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        onFinishCapture(img, sel)
    }

    private func triggerPin() {
        guard let img = renderCurrentSelectionImage(), let sel = selectionRect else { return }
        onPinCapture(img, sel)
    }

    private func handleArrowKeys(event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard var sel = selectionRect else { return false }
        let isShift = flags.contains(.shift)

        let step: CGFloat = 1.0

        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            if isShift {
                sel.size.width = max(10, sel.size.width - step)
            } else {
                sel.origin.x = max(0, sel.origin.x - step)
            }
        case kVK_RightArrow:
            if isShift {
                sel.size.width = min(bounds.width - sel.origin.x, sel.size.width + step)
            } else {
                sel.origin.x = min(bounds.width - sel.size.width, sel.origin.x + step)
            }
        case kVK_UpArrow:
            if isShift {
                sel.size.height = min(bounds.height - sel.origin.y, sel.size.height + step)
            } else {
                sel.origin.y = min(bounds.height - sel.size.height, sel.origin.y + step)
            }
        case kVK_DownArrow:
            if isShift {
                sel.size.height = max(10, sel.size.height - step)
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
