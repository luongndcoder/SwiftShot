import AppKit

/// Copies an NSImage to the system pasteboard.
enum Clipboard {
    @discardableResult
    static func copy(_ image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}
