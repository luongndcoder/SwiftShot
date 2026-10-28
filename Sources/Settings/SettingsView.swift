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
                Toggle("Copy on double click", isOn: $settings.copyOnDoubleClick)
                Toggle("Reuse last region for next capture", isOn: $settings.useLastRegion)
                if settings.useLastRegion, settings.lastRegion != nil {
                    Button("Forget last region") {
                        settings.lastRegion = nil
                    }
                    .controlSize(.small)
                }
                Toggle("Show pixel magnifier", isOn: $settings.showMagnifier)
            }

            Section("Saving") {
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
                Picker("Format", selection: $settings.saveFormat) {
                    ForEach(SaveFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                if settings.saveFormat == .jpeg {
                    HStack {
                        Text("JPEG quality")
                        Spacer()
                        Slider(value: $settings.jpegQuality, in: 0.4...1.0, step: 0.05)
                            .frame(width: 160)
                        Text("\(Int(settings.jpegQuality * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Toggle("Ask where to save every time", isOn: $settings.askWhereToSave)
                Toggle("Copy file path after saving", isOn: $settings.copyPathAfterSave)
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
                HStack {
                    Text("Dim outside selection")
                    Spacer()
                    Slider(value: $settings.selectionOpacity, in: 0...0.8, step: 0.05)
                        .frame(width: 160)
                    Text("\(Int(settings.selectionOpacity * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }

            Section("Recording") {
                Toggle("Record system audio", isOn: $settings.recordSystemAudio)
                Text("Recordings are saved as MP4 (H.264) in the save folder, at the display's native resolution and 60 fps. The microphone is not recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Auto-zoom on clicks", isOn: $settings.autoZoomOnClicks)
                if settings.autoZoomOnClicks {
                    Picker("Zoom level", selection: $settings.autoZoomLevel) {
                        Text("1.5×").tag(1.5)
                        Text("2.0×").tag(2.0)
                        Text("2.5×").tag(2.5)
                    }
                    Text("When a recording stops, an extra version is rendered with a “-zoom” suffix: its camera glides in on every click and back out when things go quiet, Cursorful-style. The original recording is kept as-is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Translation") {
                Picker("Provider", selection: $settings.translationProvider) {
                    ForEach(TranslationProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Picker("Target Language", selection: $settings.translationTargetLanguage) {
                    ForEach(TranslationLanguage.supported) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }

                if settings.translationProvider == .google {
                    Text("Uses Google Translate's free public endpoint. Fast, on-device OCR via Apple Vision, zero API key required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.translationProvider == .openai {
                    SecureField("OpenAI API Key", text: $settings.openaiApiKey)
                    TextField("Base URL", text: $settings.openaiBaseURL)
                    TextField("Model", text: $settings.openaiModel)
                    Text("Compatible with OpenAI, OpenRouter, DeepSeek, LocalAI, etc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $settings.autoCheckForUpdates)
                HStack {
                    Text("Current version: \(UpdateChecker.shared.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now…") {
                        UpdateChecker.shared.check(manual: true)
                    }
                }
            }

            Section("Color Presets") {
                if settings.customColors.isEmpty {
                    Text("No presets yet — pick a color in the capture toolbar and press + to add it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(Array(settings.customColors.enumerated()), id: \.offset) { index, color in
                            ColorSwatch(color: color) {
                                settings.customColors.remove(at: index)
                            }
                        }
                        Spacer()
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("SwiftShot")
                    Spacer()
                    Text("v\(UpdateChecker.shared.currentVersion)")
                        .foregroundColor(.secondary)
                }
                Text("Lightweight native macOS screenshot tool. Inspired by Flameshot.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500, height: 540)
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

/// A colour chip with a small remove button.
private struct ColorSwatch: View {
    let color: NSColor
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: color))
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                )
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
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
