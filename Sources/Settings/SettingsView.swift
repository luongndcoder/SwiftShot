import SwiftUI

/// SwiftUI preferences panel opened from the menu bar.
struct SettingsView: View {
    @AppStorage("hotkeyKeyCombo") private var hotkeyRaw: String = KeyCombo(key: .four, modifiers: [.control, .shift, .command]).rawValue
    @AppStorage("autoSave") private var autoSave: Bool = false
    @AppStorage("copyToClipboard") private var copyToClipboard: Bool = true
    @AppStorage("defaultColor") private var defaultColorData: Data = (try? NSKeyedArchiver.archivedData(withRootObject: NSColor.systemRed, requiringSecureCoding: false)) ?? Data()

    private var defaultColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: defaultColorData)) ?? .systemRed) },
            set: { newColor in
                if let nsColor = NSColor(newColor) as NSColor?,
                   let data = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
                    defaultColorData = data
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Capture") {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    TextField("Hotkey", text: $hotkeyRaw)
                        .frame(width: 120)
                        .textFieldStyle(.roundedBorder)
                    Button("Record") {
                        // Placeholder — real implementation would install a local event monitor
                        // to capture the next key combination.
                    }
                    .disabled(true)
                }
                Toggle("Copy to clipboard after capture", isOn: $copyToClipboard)
                Toggle("Auto-save to folder", isOn: $autoSave)
            }

            Section("Annotation") {
                ColorPicker("Default Color", selection: defaultColor)
            }

            Section("About") {
                HStack {
                    Text("SwiftShot")
                    Spacer()
                    Text("v1.0.0")
                        .foregroundColor(.secondary)
                }
                Text("Lightweight native macOS screenshot tool. Inspired by Flameshot.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 320)
    }
}
