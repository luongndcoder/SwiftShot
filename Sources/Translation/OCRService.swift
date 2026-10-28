import Foundation
import Vision
import CoreGraphics

/// A single recognized line or block of text with spatial coordinates.
struct RecognizedTextBlock: Identifiable, Sendable {
    let id = UUID()
    let text: String
    /// Normalized coordinates [0, 1] with origin at bottom-left (Vision standard).
    let normalizedRect: CGRect
    /// Coordinates mapped to image pixels (origin at bottom-left).
    let pixelRect: CGRect
    let confidence: Float
}

/// The aggregated result of text recognition on an image.
struct OCRResult: Sendable {
    let fullText: String
    let blocks: [RecognizedTextBlock]

    var isEmpty: Bool {
        fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Native on-device OCR engine powered by Apple Vision (`VNRecognizeTextRequest`).
final class OCRService: Sendable {
    static let shared = OCRService()

    /// Supported recognition languages ordered by likelihood.
    private let preferredLanguages = [
        "vi-VN", "en-US", "zh-Hans", "zh-Hant",
        "ja-JP", "ko-KR", "fr-FR", "de-DE",
        "es-ES", "ru-RU", "it-IT", "pt-BR"
    ]

    /// Performs OCR asynchronously on a given CGImage.
    func recognizeText(in cgImage: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(fullText: "", blocks: []))
                    return
                }

                let imgWidth = CGFloat(cgImage.width)
                let imgHeight = CGFloat(cgImage.height)

                var blocks: [RecognizedTextBlock] = []
                var lineStrings: [String] = []

                // Sort observations vertically from top to bottom, then left to right
                let sortedObservations = observations.sorted { a, b in
                    // a.boundingBox.maxY vs b.boundingBox.maxY (higher Y = higher on screen in bottom-left origin)
                    let yDiff = a.boundingBox.maxY - b.boundingBox.maxY
                    if abs(yDiff) > 0.02 {
                        return a.boundingBox.maxY > b.boundingBox.maxY
                    }
                    return a.boundingBox.minX < b.boundingBox.minX
                }

                for obs in sortedObservations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let normBox = obs.boundingBox
                    let pixelBox = CGRect(
                        x: normBox.origin.x * imgWidth,
                        y: normBox.origin.y * imgHeight,
                        width: normBox.size.width * imgWidth,
                        height: normBox.size.height * imgHeight
                    )

                    blocks.append(RecognizedTextBlock(
                        text: text,
                        normalizedRect: normBox,
                        pixelRect: pixelBox,
                        confidence: candidate.confidence
                    ))
                    lineStrings.append(text)
                }

                let fullText = lineStrings.joined(separator: "\n")
                continuation.resume(returning: OCRResult(fullText: fullText, blocks: blocks))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }
            request.recognitionLanguages = preferredLanguages

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
