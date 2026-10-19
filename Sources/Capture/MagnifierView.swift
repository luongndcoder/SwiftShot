import AppKit
import CoreGraphics

/// Floating magnifying glass loupe showing 4x zoomed pixels and RGB/HEX color inspection.
final class MagnifierView: NSView {
    private var pixelImage: CGImage?
    private var colorText: String = ""
    private var hexText: String = ""
    private var currentColor: NSColor = .black

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 160))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.95).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(at point: CGPoint, in bounds: CGRect, backgroundImage: CGImage, scale: CGFloat) {
        let sampleSize: CGFloat = 24
        let bgW = CGFloat(backgroundImage.width)
        let bgH = CGFloat(backgroundImage.height)

        let pixelX = (point.x / bounds.width) * bgW
        let pixelY = ((bounds.height - point.y) / bounds.height) * bgH

        let cropRect = CGRect(
            x: max(0, min(pixelX - sampleSize / 2, bgW - sampleSize)),
            y: max(0, min(pixelY - sampleSize / 2, bgH - sampleSize)),
            width: sampleSize,
            height: sampleSize
        )

        self.pixelImage = backgroundImage.cropping(to: cropRect)

        if let crop = self.pixelImage,
           let data = crop.dataProvider?.data,
           let ptr = CFDataGetBytePtr(data) {
            let cx = Int(sampleSize / 2)
            let cy = Int(sampleSize / 2)
            let bpr = crop.bytesPerRow
            let offset = cy * bpr + cx * 4
            let r = ptr[offset]
            let g = ptr[offset + 1]
            let b = ptr[offset + 2]
            self.currentColor = NSColor(red: CGFloat(r)/255.0, green: CGFloat(g)/255.0, blue: CGFloat(b)/255.0, alpha: 1.0)
            self.colorText = "RGB: \(r), \(g), \(b)"
            self.hexText = String(format: "#%02X%02X%02X", r, g, b)
        }

        var mx = point.x + 20
        var my = point.y - 180
        if mx + 140 > bounds.width { mx = point.x - 160 }
        if my < 10 { my = point.y + 20 }
        self.frame = NSRect(x: mx, y: my, width: 140, height: 160)

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Top zoomed pixel grid
        let zoomRect = CGRect(x: 10, y: bounds.height - 110, width: 120, height: 100)
        ctx.saveGState()
        let clipPath = CGPath(roundedRect: zoomRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()

        if let crop = pixelImage {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: zoomRect)
        }

        // Draw crosshair at center
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1)
        let midX = zoomRect.midX
        let midY = zoomRect.midY
        ctx.move(to: CGPoint(x: midX - 8, y: midY))
        ctx.addLine(to: CGPoint(x: midX + 8, y: midY))
        ctx.move(to: CGPoint(x: midX, y: midY - 8))
        ctx.addLine(to: CGPoint(x: midX, y: midY + 8))
        ctx.strokePath()

        ctx.restoreGState()
        ctx.addPath(clipPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // 2. Color preview box
        let colorBox = CGRect(x: 10, y: 12, width: 24, height: 24)
        ctx.setFillColor(currentColor.cgColor)
        ctx.fill(colorBox)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(colorBox)

        // 3. Draw text info via CoreText (100% thread-safe & zero AppKit nil-dict exceptions)
        if !hexText.isEmpty {
            drawCoreText(hexText, at: CGPoint(x: 42, y: 26), in: ctx, fontSize: 10, isBold: true, color: .white)
        }
        if !colorText.isEmpty {
            drawCoreText(colorText, at: CGPoint(x: 42, y: 12), in: ctx, fontSize: 9, isBold: false, color: NSColor(calibratedWhite: 0.8, alpha: 1.0))
        }
    }

    private func drawCoreText(_ text: String, at point: CGPoint, in ctx: CGContext, fontSize: CGFloat, isBold: Bool, color: NSColor) {
        let font = CTFontCreateWithName((isBold ? "Menlo-Bold" : "Menlo") as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
