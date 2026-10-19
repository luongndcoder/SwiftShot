import AppKit

/// Saves NSImage as PNG to a directory with a timestamped filename.
enum FileStore {
    static var defaultDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("SwiftShot", isDirectory: true)
    }

    @discardableResult
    static func save(_ image: NSImage, directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "SwiftShot_\(formatter.string(from: Date())).png"
        let url = directory.appendingPathComponent(name)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: url)
            return true
        } catch {
            NSLog("[SwiftShot] save failed: \(error.localizedDescription)")
            return false
        }
    }
}
