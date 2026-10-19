import AppKit

/// Copies an NSImage to the system pasteboard.
enum Clipboard {
    @discardableResult
    static func copy(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Offer both PNG (universally supported) and TIFF (native AppKit flavour).
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            item.setData(tiff, forType: .tiff)
            return pasteboard.writeObjects([item])
        }

        return pasteboard.writeObjects([image])
    }
}
