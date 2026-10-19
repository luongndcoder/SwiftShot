import AppKit
import SwiftUI

/// SwiftUI preferences panel opened from the menu bar.
///
/// It observes the app-wide `Settings` object so there is exactly one source of
/// truth for the preferences (no duplicated `@AppStorage` values).
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @StateObject private var recorder = HotkeyRecorderModel()

    var body: some View {
        Form {
            Section("Capture") {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    Text(settings.hotkey.displayString)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(recorder.isRecording ? "Press keys…" : "Record") {
                        recorder.isRecording ? recorder.stop() : recorder.start()
                    }
                }
                Toggle("Also copy to clipboard after capture", isOn: $settings.copyToClipboard)
                Toggle("Also auto-save to folder", isOn: $settings.autoSave)
                HStack {
                    Text("Save folder")
                    Spacer()
                    Text(settings.saveDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        chooseSaveDirectory()
                    }
                }
            }

            Section("Annotation") {
                ColorPicker("Default Color", selection: defaultColor)
                HStack {
                    Text("Stroke width")
                    Spacer()
                    Slider(value: $settings.strokeWidth, in: 1...20, step: 0.5)
                        .frame(width: 160)
                    Text(String(format: "%.1f", settings.strokeWidth))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
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
        .frame(width: 460, height: 380)
        .onAppear {
            recorder.onCapture = { [settings] combo in
                settings.hotkey = combo
            }
        }
        .onDisappear {
            recorder.stop()
        }
    }

    private var defaultColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: settings.defaultColor) },
            set: { newColor in
                if let nsColor = NSColor(newColor) as NSColor? {
                    settings.defaultColor = nsColor
                }
            }
        )
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.saveDirectory = url
    }
}

// MARK: - Hotkey recorder

/// Captures the next key combination pressed by the user.
@MainActor
final class HotkeyRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false

    var onCapture: ((KeyCombo) -> Void)?

    private var monitor: Any?

    func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Escape cancels the recording.
            if event.keyCode == 53 {
                self.stop()
                return nil
            }

            // Ignore presses of modifier keys on their own.
            guard !KeyCodeTable.modifierKeyCodes.contains(event.keyCode) else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // A usable global shortcut needs at least one of ⌘ / ⌃ / ⌥.
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                return event
            }

            let combo = KeyCombo(keyCode: event.keyCode, modifiers: flags)
            self.stop()
            self.onCapture?(combo)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
