import AppKit
import CoreGraphics

/// The annotation model — a single drawable shape, blur/pixelate region, or counter badge.
struct Annotation: Equatable {
    enum Kind: String, Codable, CaseIterable {
        case select     // Selection mode (picks drawn objects)
        case move       // Move the selection rectangle (the "hand" tool)
        case arrow
        case line
        case rectangle
        case filledRectangle
        case ellipse
        case freehand
        case marker     // Semi-transparent highlighter
        case text
        case counter    // Auto-incrementing circled number: ① ② ③...
        case blur
        case pixelate
        case invert     // Inverts the colours of the underlying image
    }

    var kind: Kind
    var points: [CGPoint]   // Freehand path or blur/pixelate bounding corners
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var strokeWidth: CGFloat
    var text: String?       // For .text
    var count: Int?         // For .counter (1, 2, 3...)

    var bounds: CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
