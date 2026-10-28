import AppKit
import SwiftUI

/// SwiftUI interface for the floating translation results panel.
struct TranslationPanelView: View {
    let originalText: String
    let translatedText: String
    let detectedSourceLang: String
    @Binding var targetLang: String
    let providerName: String
    let isLoading: Bool
    let errorMessage: String?
    let isOverlayApplied: Bool

    let onRetranslate: (String) -> Void
    let onToggleOverlay: () -> Void
    let onCopyTranslation: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Header bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "character.bubble.fill")
                        .foregroundColor(.green)
                    Text("Translation")
                        .font(.headline)
                        .fontWeight(.semibold)
                }

                Spacer()

                Text(providerName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .cornerRadius(4)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Language selector row
            HStack(spacing: 8) {
                Text(detectedSourceLang.uppercased())
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(6)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Picker("", selection: $targetLang) {
                    ForEach(TranslationLanguage.supported) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .onChange(of: targetLang) { _, newLang in
                    onRetranslate(newLang)
                }

                Spacer()

                if isLoading {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Đang dịch…")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.green)
                    }
                }
            }

            // Text areas
            VStack(spacing: 8) {
                // Original text card
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Original Text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(originalText, forType: .string)
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }

                    ScrollView {
                        Text(originalText.isEmpty ? "(No text recognized)" : originalText)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .textSelection(.enabled)
                    }
                    .frame(height: 70)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(6)
                }

                // Translated text card
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Translated Text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: onCopyTranslation) {
                            Label("Copy", systemImage: "doc.on.clipboard")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                    }

                    ScrollView {
                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        } else if isLoading {
                            VStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Đang nhận diện chữ & dịch thuật…")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 88, alignment: .center)
                            .padding(6)
                        } else {
                            Text(translatedText.isEmpty ? "(Chưa có kết quả dịch)" : translatedText)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(height: 100)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(6)
                }
            }

            // Action footer
            HStack(spacing: 10) {
                Button(action: onToggleOverlay) {
                    HStack(spacing: 5) {
                        Image(systemName: isOverlayApplied ? "checkmark.circle.fill" : "photo.artframe")
                        Text(isOverlayApplied ? "Overlay Active" : "Overlay on Image")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isOverlayApplied ? .green : .blue)
                .controlSize(.regular)

                Spacer()

                Button("Copy & Close", action: onCopyTranslation)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
    }
}

/// Backing visual effect blur for macOS glass aesthetics.
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
