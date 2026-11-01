import AppKit
import CoreGraphics
import PDFKit

enum ClipboardService {
    static func copyPage(image: CGImage, pdfPage: PDFPage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let representation = NSBitmapImageRep(cgImage: image)
        let png = representation.representation(using: .png, properties: [:])
        let tiff = representation.tiffRepresentation

        let document = PDFDocument()
        if let copy = pdfPage.copy() as? PDFPage {
            document.insert(copy, at: 0)
        }
        let pdfData = document.pageCount > 0 ? document.dataRepresentation() : nil

        var types: [NSPasteboard.PasteboardType] = []
        if png != nil { types.append(.png) }
        if tiff != nil { types.append(.tiff) }
        if pdfData != nil { types.append(.pdf) }
        pasteboard.declareTypes(types, owner: nil)
        if let png {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff {
            pasteboard.setData(tiff, forType: .tiff)
        }
        if let pdfData {
            pasteboard.setData(pdfData, forType: .pdf)
        }
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
