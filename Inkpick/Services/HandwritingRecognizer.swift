import CoreGraphics
import Foundation
import Vision

struct RecognizedLine: Equatable, Sendable {
    var text: String
    var minX: CGFloat
    var midY: CGFloat
}

enum ReadingOrder {
    static let lineTolerance: CGFloat = 0.02

    static func sort(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        let highestFirst = lines.sorted { $0.midY > $1.midY }
        var rows: [[RecognizedLine]] = []
        for line in highestFirst {
            if let anchor = rows.last?.first, abs(anchor.midY - line.midY) <= lineTolerance {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row in
            row.sorted { $0.minX < $1.minX }
        }
    }

    static func join(_ lines: [RecognizedLine]) -> String {
        sort(lines).map(\.text).joined(separator: "\n")
    }
}

enum LanguagePreferences {
    private static let cachedSupportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    static func supportedRecognitionLanguages() -> [String] {
        cachedSupportedLanguages
    }

    static func resolved(stored: String) -> [String] {
        let supported = supportedRecognitionLanguages()
        let supportedSet = Set(supported)
        let chosen = stored
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { supportedSet.contains($0) }
        if !chosen.isEmpty {
            return chosen
        }

        let preferred = Locale.preferredLanguages.filter { supportedSet.contains($0) }
        if !preferred.isEmpty {
            return preferred
        }
        if supportedSet.contains("en-US") {
            return ["en-US"]
        }
        return Array(supported.prefix(1))
    }
}

enum HandwritingRecognizer {
    static func recognize(image: CGImage, languages: [String]) async throws -> String {
        if #available(macOS 26.0, *) {
            let documentText = try? await recognizeDocument(image: image, languages: languages)
            if let documentText, !documentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return documentText
            }
        }
        return try await recognizeLines(image: image, languages: languages)
    }

    @available(macOS 26.0, *)
    private static func recognizeDocument(image: CGImage, languages: [String]) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        if languages.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            request.textRecognitionOptions.recognitionLanguages = languages.map {
                Locale.Language(identifier: $0)
            }
        }
        request.barcodeDetectionOptions.enabled = false

        let observations = try await request.perform(on: image)
        return observations.map { observation in
            let paragraphs = observation.document.paragraphs
            if paragraphs.isEmpty {
                return observation.document.text.transcript
            }
            return paragraphs
                .map(\.transcript)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }

    private static func recognizeLines(image: CGImage, languages: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let box = observation.boundingBox
                return RecognizedLine(text: text, minX: box.minX, midY: box.midY)
            }
            return ReadingOrder.join(lines)
        }.value
    }
}
