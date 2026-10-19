import AppKit
import CoreGraphics
import CoreImage

/// Reads single pixels out of a `CGImage`.
///
/// Screen captures are delivered as **BGRA** by ScreenCaptureKit, so reading the
/// raw bytes directly would swap red and blue. Going through CoreImage returns
/// canonical RGBA regardless of the source layout.
enum PixelSampler {
    private static let ciContext = CIContext(options: nil)
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Samples the colour of the pixel at `point`.
    ///
    /// - Parameters:
    ///   - image: the image to sample.
    ///   - point: location in **image pixel coordinates** (origin top-left).
    static func color(in image: CGImage, at point: CGPoint) -> NSColor? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let x = Int(point.x.rounded())
        // The bitmap is top-left based, CoreImage is bottom-left based.
        let y = Int((CGFloat(height) - point.y).rounded()) - 1
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            CIImage(cgImage: image),
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return NSColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: 1.0
        )
    }
}
