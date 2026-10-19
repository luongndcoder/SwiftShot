import AppKit

/// Saves NSImage as PNG to a directory with a timestamped filename.
enum FileStore {
    static var defaultDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return pictures.appendingPathComponent("SwiftShot", isDirectory: true)
    }

    @discardableResult
    static func save(_ image: NSImage, directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[SwiftShot] could not create \(directory.path): \(error.localizedDescription)")
            return false
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = "SwiftShot_\(formatter.string(from: Date()))"

        // Two saves within the same second must not overwrite each other.
        var url = directory.appendingPathComponent("\(baseName).png")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName)_\(counter).png")
            counter += 1
        }

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
