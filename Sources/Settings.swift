import AppKit
import Combine

/// User settings persisted via UserDefaults.
///
/// This is the single source of truth for user preferences: the SwiftUI settings
/// panel observes this object directly instead of duplicating the values with
/// `@AppStorage`.
final class Settings: ObservableObject {
    private enum Key {
        static let hotkeyKeyCombo = "hotkeyKeyCombo"
        static let autoSave = "autoSave"
        static let saveDirectory = "saveDirectory"
        static let copyToClipboard = "copyToClipboard"
        static let defaultColor = "defaultColor"
        static let strokeWidth = "strokeWidth"
        static let saveFormat = "saveFormat"
        static let jpegQuality = "jpegQuality"
        static let askWhereToSave = "askWhereToSave"
        static let copyPathAfterSave = "copyPathAfterSave"
        static let copyOnDoubleClick = "copyOnDoubleClick"
        static let useLastRegion = "useLastRegion"
        static let lastRegion = "lastRegion"
        static let customColors = "customColors"
        static let showMagnifier = "showMagnifier"
        static let selectionOpacity = "selectionOpacity"
        static let recordSystemAudio = "recordSystemAudio"
        static let autoCheckForUpdates = "autoCheckForUpdates"
    }

    /// Default global hotkey: ⇧⌘4 (Command + Shift + 4), same as the native macOS region capture.
    static let defaultHotkey = KeyCombo(keyCode: KeyCodeTable.four, modifiers: [.shift, .command])

    /// Current global hotkey.
    @Published var hotkey: KeyCombo = Settings.defaultHotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: Key.hotkeyKeyCombo) }
    }
    @Published var autoSave: Bool = false {
        didSet { defaults.set(autoSave, forKey: Key.autoSave) }
    }
    @Published var saveDirectory: URL = FileStore.defaultDirectory {
        didSet { defaults.set(saveDirectory.path, forKey: Key.saveDirectory) }
    }
    @Published var copyToClipboard: Bool = true {
        didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) }
    }
    @Published var defaultColor: NSColor = .systemRed {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: defaultColor, requiringSecureCoding: false) {
                defaults.set(data, forKey: Key.defaultColor)
            }
        }
    }
    @Published var strokeWidth: CGFloat = 3 {
        didSet { defaults.set(strokeWidth, forKey: Key.strokeWidth) }
    }

    // MARK: - Saving

    /// File format used for saved screenshots.
    @Published var saveFormat: SaveFormat = .png {
        didSet { defaults.set(saveFormat.rawValue, forKey: Key.saveFormat) }
    }

    /// JPEG quality (0.1 – 1.0), only relevant for the JPEG format.
    @Published var jpegQuality: Double = 0.9 {
        didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) }
    }

    /// When enabled the save panel is shown instead of writing to `saveDirectory`.
    @Published var askWhereToSave: Bool = false {
        didSet { defaults.set(askWhereToSave, forKey: Key.askWhereToSave) }
    }

    /// Copies the path of the saved file to the clipboard.
    @Published var copyPathAfterSave: Bool = false {
        didSet { defaults.set(copyPathAfterSave, forKey: Key.copyPathAfterSave) }
    }

    // MARK: - Capture behaviour

    /// Double clicking inside the selection copies it and finishes the capture.
    @Published var copyOnDoubleClick: Bool = true {
        didSet { defaults.set(copyOnDoubleClick, forKey: Key.copyOnDoubleClick) }
    }

    /// Reuses the last selection rectangle for the next capture.
    @Published var useLastRegion: Bool = false {
        didSet { defaults.set(useLastRegion, forKey: Key.useLastRegion) }
    }

    /// The last selection rectangle in screen coordinates.
    @Published var lastRegion: CGRect? {
        didSet {
            if let lastRegion {
                defaults.set(Self.encode(lastRegion), forKey: Key.lastRegion)
            } else {
                defaults.removeObject(forKey: Key.lastRegion)
            }
        }
    }

    // MARK: - Appearance

    /// User defined colour presets shown in the toolbar next to the default palette.
    @Published var customColors: [NSColor] = [] {
        didSet {
            let data = try? NSKeyedArchiver.archivedData(
                withRootObject: customColors,
                requiringSecureCoding: false
            )
            defaults.set(data, forKey: Key.customColors)
        }
    }

    /// Shows the pixel magnifier while selecting a region.
    @Published var showMagnifier: Bool = true {
        didSet { defaults.set(showMagnifier, forKey: Key.showMagnifier) }
    }

    /// Opacity of the dimmed area outside of the selection (0 – 1).
    @Published var selectionOpacity: Double = 0.35 {
        didSet { defaults.set(selectionOpacity, forKey: Key.selectionOpacity) }
    }

    // MARK: - Recording

    /// Records system audio (sounds played by the Mac and other apps) into the
    /// video file. Microphone capture is not offered (macOS 15 API).
    @Published var recordSystemAudio: Bool = true {
        didSet { defaults.set(recordSystemAudio, forKey: Key.recordSystemAudio) }
    }

    // MARK: - Updates

    /// Checks GitHub Releases once a day for a newer version.
    @Published var autoCheckForUpdates: Bool = true {
        didSet { defaults.set(autoCheckForUpdates, forKey: Key.autoCheckForUpdates) }
    }

    private let defaults = UserDefaults.standard

    init() {
        if let raw = defaults.string(forKey: Key.hotkeyKeyCombo), let combo = KeyCombo(rawValue: raw) {
            hotkey = combo
        } else {
            // No (or an outdated, unparsable) stored value — fall back to the default
            // and normalise the stored representation.
            defaults.set(hotkey.rawValue, forKey: Key.hotkeyKeyCombo)
        }
        autoSave = defaults.bool(forKey: Key.autoSave)
        if let path = defaults.string(forKey: Key.saveDirectory) {
            saveDirectory = URL(fileURLWithPath: path)
        }
        copyToClipboard = defaults.object(forKey: Key.copyToClipboard) as? Bool ?? true
        if let data = defaults.data(forKey: Key.defaultColor),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            defaultColor = color
        }
        strokeWidth = defaults.object(forKey: Key.strokeWidth) as? Double ?? 3
        if let raw = defaults.string(forKey: Key.saveFormat), let format = SaveFormat(rawValue: raw) {
            saveFormat = format
        }
        jpegQuality = defaults.object(forKey: Key.jpegQuality) as? Double ?? 0.9
        askWhereToSave = defaults.bool(forKey: Key.askWhereToSave)
        copyPathAfterSave = defaults.bool(forKey: Key.copyPathAfterSave)
        copyOnDoubleClick = defaults.object(forKey: Key.copyOnDoubleClick) as? Bool ?? true
        useLastRegion = defaults.bool(forKey: Key.useLastRegion)
        if let raw = defaults.string(forKey: Key.lastRegion), let rect = Self.decode(raw) {
            lastRegion = rect
        }
        if let data = defaults.data(forKey: Key.customColors),
           let colors = try? NSKeyedUnarchiver.unarchivedArrayOfObjects(ofClass: NSColor.self, from: data) {
            customColors = colors
        }
        showMagnifier = defaults.object(forKey: Key.showMagnifier) as? Bool ?? true
        selectionOpacity = defaults.object(forKey: Key.selectionOpacity) as? Double ?? 0.35
        recordSystemAudio = defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? true
        autoCheckForUpdates = defaults.object(forKey: Key.autoCheckForUpdates) as? Bool ?? true
    }

    // MARK: - Region coding

    private static func encode(_ rect: CGRect) -> String {
        "\(rect.origin.x)|\(rect.origin.y)|\(rect.size.width)|\(rect.size.height)"
    }

    private static func decode(_ raw: String) -> CGRect? {
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 4,
              let x = Double(parts[0]), let y = Double(parts[1]),
              let w = Double(parts[2]), let h = Double(parts[3]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - KeyCombo

/// A keyboard shortcut expressed as a virtual key code + modifier flags.
struct KeyCombo: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    var rawValue: String {
        "\(keyCode)||\(modifiers.rawValue)"
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(rawValue: String) {
        let parts = rawValue.components(separatedBy: "||")
        guard parts.count == 2,
              let code = UInt16(parts[0]),
              let raw = UInt(parts[1]) else { return nil }
        self.keyCode = code
        self.modifiers = NSEvent.ModifierFlags(rawValue: raw)
    }

    var displayString: String {
        modifiers.displayString + KeyCodeTable.displayName(for: keyCode)
    }
}

// MARK: - Key code names

/// Maps macOS virtual key codes to human readable names (used by the hotkey recorder).
enum KeyCodeTable {
    static let four: UInt16 = 0x15  // "4"

    /// Key codes of the modifier keys themselves — used to ignore modifier-only presses.
    static let modifierKeyCodes: Set<UInt16> = [55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let names: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6",
        0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
        0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/",
        0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "Tab", 0x31: "Space", 0x32: "`",
        0x33: "Delete", 0x35: "Esc", 0x36: "F5", 0x37: "F4", 0x38: "F3", 0x39: "F2",
        0x40: "F1", 0x41: "→", 0x42: "←", 0x43: "↓", 0x44: "↑", 0x4A: "F6",
        0x4B: "F7", 0x4C: "F8", 0x4D: "F9", 0x4E: "F10", 0x4F: "F11", 0x50: "F12"
    ]

    static func displayName(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}

extension NSEvent.ModifierFlags {
    var displayString: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}
