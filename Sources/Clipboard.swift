import AppKit

/// Copies an NSImage to the system pasteboard.
enum Clipboard {
    @discardableResult
    static func copy(_ image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Encode from the CGImage directly: `tiffRepresentation` plus
        // `NSBitmapImageRep(data:)` builds and then re-parses a full-size TIFF
        // of the capture, costing an extra copy of the whole bitmap per copy.
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            // Offer both PNG (universally supported) and TIFF (native AppKit flavour).
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                if let tiff = bitmap.representation(using: .tiff, properties: [:]) {
                    item.setData(tiff, forType: .tiff)
                }
                return pasteboard.writeObjects([item])
            }
        }

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return false }

        if let png = bitmap.representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setData(tiff, forType: .tiff)
            return pasteboard.writeObjects([item])
        }

        return pasteboard.writeObjects([image])
    }
}
