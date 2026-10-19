import AppKit
import UniformTypeIdentifiers

/// The file format used when saving a screenshot.
///
/// WebP is intentionally not offered: neither `NSBitmapImageRep` nor `ImageIO`
/// can encode it on macOS, it would require a third-party encoder.
enum SaveFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG (lossless)"
        case .jpeg: return "JPEG (lossy)"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    var fileType: NSBitmapImageRep.FileType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    /// Encodes an image with this format.
    func data(for image: NSImage, quality: Double = 1.0) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if self == .jpeg {
            properties[.compressionFactor] = max(0.1, min(quality, 1.0))
        }
        return bitmap.representation(using: fileType, properties: properties)
    }
}

/// Saves NSImage to a directory with a timestamped filename.
enum FileStore {
    static var defaultDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return pictures.appendingPathComponent("SwiftShot", isDirectory: true)
    }

    static func timestampedName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SwiftShot_\(formatter.string(from: date))"
    }

    /// Writes the image into `directory` with a timestamped name.
    /// Returns the URL that was written, or `nil` on failure.
    @discardableResult
    static func save(
        _ image: NSImage,
        directory: URL,
        format: SaveFormat = .png,
        quality: Double = 1.0
    ) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[SwiftShot] could not create \(directory.path): \(error.localizedDescription)")
            return nil
        }

        guard let data = format.data(for: image, quality: quality) else { return nil }

        let baseName = timestampedName()
        var url = directory.appendingPathComponent("\(baseName).\(format.fileExtension)")
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName)_\(counter).\(format.fileExtension)")
            counter += 1
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("[SwiftShot] save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes the image to an explicit URL, creating the parent directory if needed.
    @discardableResult
    static func write(_ image: NSImage, to url: URL, format: SaveFormat, quality: Double = 1.0) -> Bool {
        guard let data = format.data(for: image, quality: quality) else { return false }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            NSLog("[SwiftShot] write failed: \(error.localizedDescription)")
            return false
        }
    }
}
