import CoreGraphics
import Foundation
import PDFKit

enum PageRendererError: Error {
    case renderingFailed
}

enum PageRenderer {
    static let renderDPI: CGFloat = 300
    static let maximumEdge = 4_096
    static let maximumPixels = 12_000_000

    /// Returns the page's text layer when it contains real writing.
    /// Digit-only strings, such as a page number, fall through to handwriting recognition.
    static func textLayer(of page: PDFPage) -> String? {
        let raw = page.string ?? page.attributedString?.string ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLetter = trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        guard hasLetter else { return nil }
        return trimmed
    }

    static func image(of page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw PageRendererError.renderingFailed
        }

        let pointsPerInch: CGFloat = 72
        let dpiScale = renderDPI / pointsPerInch
        let edgeScale = CGFloat(maximumEdge) / max(bounds.width, bounds.height)
        let pixelScale = sqrt(CGFloat(maximumPixels) / (bounds.width * bounds.height))
        let scale = min(dpiScale, edgeScale, pixelScale)
        guard scale.isFinite, scale > 0 else {
            throw PageRendererError.renderingFailed
        }

        let width = max(1, Int(floor(bounds.width * scale)))
        let height = max(1, Int(floor(bounds.height * scale)))
        let thumbnail = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              image.width > 0,
              image.height > 0 else {
            throw PageRendererError.renderingFailed
        }
        return image
    }
}
