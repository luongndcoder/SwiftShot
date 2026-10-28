import AppKit
import SwiftUI

/// SwiftUI panel for inspecting, selecting, and copying recognized OCR text blocks.
struct TextExtractPanelView: View {
    let fullText: String
    let blocks: [RecognizedTextBlock]
    let isLoading: Bool
    let errorMessage: String?

    @State private var selectedBlockIds: Set<UUID> = []
    @State private var viewMode: ViewMode = .blocks
    @State private var copiedNotice: String?

    let onCopyAll: () -> Void
    let onCopySelected: ([String]) -> Void
    let onToggleCanvasHighlight: (Bool) -> Void
    let onClose: () -> Void

    enum ViewMode: String, CaseIterable {
        case blocks = "Từng dòng / Khối"
        case fullText = "Toàn bộ văn bản"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .foregroundColor(.cyan)
                    Text("Trích xuất văn bản (OCR)")
                        .font(.headline)
                        .fontWeight(.semibold)
                }

                Spacer()

                if let notice = copiedNotice {
                    Text(notice)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Mode Picker
            Picker("", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // Content
            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Đang nhận diện văn bản bằng Apple Vision…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.title2)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if blocks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.title2)
                    Text("Không tìm thấy văn bản nào trong vùng chọn.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                if viewMode == .blocks {
                    // Block by block selection
                    VStack(spacing: 6) {
                        HStack {
                            Button(selectedBlockIds.count == blocks.count ? "Bỏ chọn tất cả" : "Chọn tất cả") {
                                if selectedBlockIds.count == blocks.count {
                                    selectedBlockIds.removeAll()
                                } else {
                                    selectedBlockIds = Set(blocks.map(\.id))
                                }
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)

                            Spacer()

                            Text("\(selectedBlockIds.count)/\(blocks.count) dòng được chọn")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                                    BlockRow(
                                        index: index + 1,
                                        block: block,
                                        isSelected: selectedBlockIds.contains(block.id),
                                        onToggle: {
                                            if selectedBlockIds.contains(block.id) {
                                                selectedBlockIds.remove(block.id)
                                            } else {
                                                selectedBlockIds.insert(block.id)
                                            }
                                        },
                                        onCopySingle: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(block.text, forType: .string)
                                            showCopiedNotice("Đã copy dòng \(index + 1)!")
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(height: 190)
                        .background(Color.black.opacity(0.15))
                        .cornerRadius(6)
                    }
                } else {
                    // Full text editable / selectable
                    ScrollView {
                        Text(fullText)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .textSelection(.enabled)
                    }
                    .frame(height: 210)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(6)
                }
            }

            // Action Footer
            HStack(spacing: 10) {
                if !selectedBlockIds.isEmpty && viewMode == .blocks {
                    Button(action: {
                        let selectedTexts = blocks.filter { selectedBlockIds.contains($0.id) }.map(\.text)
                        onCopySelected(selectedTexts)
                        showCopiedNotice("Đã copy \(selectedTexts.count) dòng đã chọn!")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Copy đã chọn (\(selectedBlockIds.count))")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .controlSize(.regular)
                }

                if selectedBlockIds.isEmpty || viewMode == .fullText {
                    Button(action: {
                        onCopyAll()
                        showCopiedNotice("Đã copy toàn bộ văn bản!")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy Tất Cả")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.regular)
                } else {
                    Button(action: {
                        onCopyAll()
                        showCopiedNotice("Đã copy toàn bộ văn bản!")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy Tất Cả")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Spacer()

                Button("Đóng", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.18)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Default: select all blocks
            selectedBlockIds = Set(blocks.map(\.id))
        }
    }

    private func showCopiedNotice(_ msg: String) {
        withAnimation {
            copiedNotice = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                copiedNotice = nil
            }
        }
    }
}

/// A single row representing a recognized text block.
private struct BlockRow: View {
    let index: Int
    let block: RecognizedTextBlock
    let isSelected: Bool
    let onToggle: () -> Void
    let onCopySingle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(isSelected ? .cyan : .secondary)
            }
            .buttonStyle(.plain)

            Text("\(index).")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .trailing)

            Text(block.text)
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCopySingle) {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundColor(isHovered ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy riêng dòng này")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isSelected ? Color.cyan.opacity(0.12) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
        .cornerRadius(4)
        .onHover { isHovered = $0 }
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
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
