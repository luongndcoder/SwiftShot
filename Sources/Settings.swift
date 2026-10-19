import AppKit
import Combine

/// User settings persisted via UserDefaults.
final class Settings: ObservableObject {
    private enum Key {
        static let hotkeyKeyCombo = "hotkeyKeyCombo"
        static let autoSave = "autoSave"
        static let saveDirectory = "saveDirectory"
        static let copyToClipboard = "copyToClipboard"
        static let defaultColor = "defaultColor"
        static let strokeWidth = "strokeWidth"
    }

    /// Current global hotkey, defaults to ⇧⌘4 (Command + Shift + 4) like native macOS region screenshot.
    @Published var hotkey: KeyCombo = .init(key: .four, modifiers: [.shift, .command]) {
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

    private let defaults = UserDefaults.standard

    init() {
        if let raw = defaults.string(forKey: Key.hotkeyKeyCombo), let combo = KeyCombo(rawValue: raw) {
            hotkey = combo
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
    }
}

// MARK: - KeyCombo

struct KeyCombo: Equatable {
    var key: KeyCode
    var modifiers: NSEvent.ModifierFlags

    var rawValue: String {
        "\(key.rawValue)||\(modifiers.rawValue)"
    }

    init(key: KeyCode, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(rawValue: String) {
        let parts = rawValue.components(separatedBy: "||")
        guard parts.count == 2, let key = KeyCode(rawValue: parts[0]),
              let raw = UInt(parts[1]) else { return nil }
        self.key = key
        self.modifiers = NSEvent.ModifierFlags(rawValue: raw)
    }

    var displayString: String {
        modifiers.displayString + key.displayString
    }
}

enum KeyCode: String {
    case one = "1", two = "2", three = "3", four = "4", five = "5"
    case a, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z

    var keyCode: UInt16 {
        switch self {
        case .one: return 0x12
        case .two: return 0x13
        case .three: return 0x14
        case .four: return 0x15
        case .five: return 0x17
        case .a: return 0x00
        case .b: return 0x0B
        case .c: return 0x08
        case .d: return 0x02
        case .e: return 0x0E
        case .f: return 0x03
        case .g: return 0x05
        case .h: return 0x04
        case .i: return 0x22
        case .j: return 0x26
        case .k: return 0x28
        case .l: return 0x25
        case .m: return 0x2E
        case .n: return 0x2D
        case .o: return 0x1F
        case .p: return 0x23
        case .q: return 0x0C
        case .r: return 0x0F
        case .s: return 0x01
        case .t: return 0x11
        case .u: return 0x20
        case .v: return 0x09
        case .w: return 0x0D
        case .x: return 0x07
        case .y: return 0x10
        case .z: return 0x06
        }
    }

    var displayString: String {
        switch self {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        default: return rawValue.uppercased()
        }
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
