import AppKit
import Foundation
import PDFKit

struct RenderedNote: Sendable {
    var pdfData: Data
    var pageText: [Int: String]
    var pageStamps: [PageStamp?]
}

enum NoteArchiveError: Error {
    case unreadable
}

enum NoteArchive {
    static func render(archive data: Data) throws -> RenderedNote {
        let files: [String: ZipFile]
        do {
            files = try ZipArchive.extract(data)
        } catch {
            throw NoteArchiveError.unreadable
        }
        let pages = PageListing.pages(in: files)
        let background = embeddedPDF(in: files)
        let hasInk = pages.contains { !$0.ink.strokes.isEmpty || !$0.ink.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !hasInk, let background {
            return RenderedNote(pdfData: background, pageText: [:], pageStamps: pages.map(\.stamp))
        }
        guard hasInk || !pages.isEmpty else { throw NoteArchiveError.unreadable }
        let document = PDFDocument(data: background ?? Data())
        let pdfData = try draw(pages: pages.map(\.ink), background: hasInk ? document : nil)
        var pageText: [Int: String] = [:]
        for (index, page) in pages.enumerated() {
            let trimmed = page.ink.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pageText[index] = trimmed
            }
        }
        let count = max(pages.count, hasInk ? (document?.pageCount ?? 0) : pages.count)
        var stamps = pages.map(\.stamp)
        if stamps.count < count {
            stamps.append(contentsOf: Array(repeating: nil, count: count - stamps.count))
        }
        return RenderedNote(pdfData: pdfData, pageText: pageText, pageStamps: stamps)
    }

    private static func embeddedPDF(in files: [String: ZipFile]) -> Data? {
        files.first { name, file in
            let lower = name.lowercased()
            return lower.hasSuffix(".pdf") && !lower.contains("__macosx") && file.data.starts(with: Data("%PDF-".utf8))
        }?.value.data
    }

    private static func draw(pages: [InkPage], background: PDFDocument?) throws -> Data {
        let count = max(pages.count, background?.pageCount ?? 0)
        guard count > 0 else { throw NoteArchiveError.unreadable }
        let storage = NSMutableData()
        var first = CGRect(x: 0, y: 0, width: 447, height: 596)
        guard let consumer = CGDataConsumer(data: storage as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &first, nil) else {
            throw NoteArchiveError.unreadable
        }
        for index in 0..<count {
            let ink = index < pages.count ? pages[index] : .empty
            let source = background?.page(at: index)
            var box = source?.bounds(for: .mediaBox) ?? bounds(for: ink)
            if box.width < 1 || box.height < 1 {
                box = CGRect(x: 0, y: 0, width: 447, height: 596)
            }
            context.beginPage(mediaBox: &box)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(box)
            source?.draw(with: .mediaBox, to: context)
            draw(ink, in: context, box: box, overDocument: source != nil)
            drawText(ink.text, in: context, box: box, whenEmpty: ink.strokes.isEmpty && source == nil)
            context.endPage()
        }
        context.closePDF()
        guard storage.length > 5 else { throw NoteArchiveError.unreadable }
        return storage as Data
    }

    private static func bounds(for page: InkPage) -> CGRect {
        let scale: CGFloat = 72.0 / 226.0
        let xs = page.strokes.flatMap { $0.points.map(\.x) }
        let ys = page.strokes.flatMap { $0.points.map(\.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return CGRect(x: 0, y: 0, width: 447, height: 596)
        }
        let pad: Float = 48
        let width = max(CGFloat(maxX - minX + pad * 2) * scale, 240)
        let height = max(CGFloat(maxY - minY + pad * 2) * scale, 240)
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func draw(_ page: InkPage, in context: CGContext, box: CGRect, overDocument: Bool) {
        let points = page.strokes.flatMap(\.points)
        guard !points.isEmpty else { return }
        let transform = pointTransform(page: page, points: points, box: box, overDocument: overDocument)
        for stroke in page.strokes {
            context.saveGState()
            context.setStrokeColor(
                red: CGFloat(stroke.red),
                green: CGFloat(stroke.green),
                blue: CGFloat(stroke.blue),
                alpha: CGFloat(stroke.alpha)
            )
            context.setFillColor(
                red: CGFloat(stroke.red),
                green: CGFloat(stroke.green),
                blue: CGFloat(stroke.blue),
                alpha: CGFloat(stroke.alpha)
            )
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setBlendMode(stroke.isHighlighter ? .multiply : .normal)
            if stroke.points.count == 1, let only = stroke.points.first {
                let center = transform.place(only)
                let radius = max(0.6, CGFloat(only.width) * transform.scale / 2)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            } else {
                for index in 1..<stroke.points.count {
                    let start = transform.place(stroke.points[index - 1])
                    let end = transform.place(stroke.points[index])
                    let width = max(stroke.points[index - 1].width, stroke.points[index].width)
                    context.setLineWidth(max(0.4, CGFloat(width) * transform.scale))
                    context.move(to: start)
                    context.addLine(to: end)
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
    }

    private static func pointTransform(
        page: InkPage,
        points: [InkPoint],
        box: CGRect,
        overDocument: Bool
    ) -> (place: (InkPoint) -> CGPoint, scale: CGFloat) {
        if overDocument {
            let maxX = points.map { abs($0.x) }.max() ?? 0
            let maxY = points.map(\.y).max() ?? 0
            let canvas = (maxX > 760 || maxY > 1900)
                ? CGSize(width: 1620, height: 2160)
                : CGSize(width: 1404, height: 1872)
            let shift: CGFloat = page.usesCenterOrigin ? canvas.width / 2 : 0
            let scale = min(box.width / canvas.width, box.height / canvas.height)
            let originX = (box.width - canvas.width * scale) / 2
            let originY = (box.height - canvas.height * scale) / 2
            return ({ point in
                CGPoint(
                    x: originX + (CGFloat(point.x) + shift) * scale,
                    y: originY + (canvas.height - CGFloat(point.y)) * scale
                )
            }, scale)
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = (xs.min() ?? 0) - 48
        let minY = (ys.min() ?? 0) - 48
        let scale: CGFloat = 72.0 / 226.0
        return ({ point in
            CGPoint(
                x: (CGFloat(point.x) - CGFloat(minX)) * scale,
                y: box.height - (CGFloat(point.y) - CGFloat(minY)) * scale
            )
        }, scale)
    }

    private static func drawText(_ text: String, in context: CGContext, box: CGRect, whenEmpty: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whenEmpty, !trimmed.isEmpty else { return }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let inset = box.insetBy(dx: 28, dy: 28)
        (trimmed as NSString).draw(
            in: inset,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.black,
            ]
        )
        NSGraphicsContext.current = previous
    }
}
