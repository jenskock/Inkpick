import PDFKit
import XCTest
@testable import Inkpick

final class NoteArchiveTests: XCTestCase {
    func testVersion5StrokeKeepsBothPoints() throws {
        let page = RemarkableLines.page(from: version5Page(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 90)))
        let stroke = try XCTUnwrap(page.strokes.first)
        XCTAssertEqual(stroke.points.count, 2)
        XCTAssertEqual(stroke.points[0].x, 10, accuracy: 0.01)
        XCTAssertEqual(stroke.points[0].y, 20, accuracy: 0.01)
        XCTAssertEqual(stroke.points[1].x, 80, accuracy: 0.01)
        XCTAssertFalse(page.usesCenterOrigin)
    }

    func testVersion6SampleDrawsTheStrokes() throws {
        let url = try XCTUnwrap(
            Bundle(for: NoteArchiveTests.self).url(forResource: "WithSceneInfo", withExtension: "rm", subdirectory: "Fixtures")
                ?? Bundle(for: NoteArchiveTests.self).url(forResource: "WithSceneInfo", withExtension: "rm")
        )
        let page = RemarkableLines.page(from: try Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(page.strokes.count, 10)
        XCTAssertTrue(page.usesCenterOrigin)
        XCTAssertFalse(page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testStoredArchiveBecomesAPDF() throws {
        let lines = version5Page(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 40, y: 50))
        let archive = storedZip(entries: [
            "note.content": Data(#"{"pages":["page-1"]}"#.utf8),
            "page-1.rm": lines,
        ])
        let rendered = try NoteArchive.render(archive: archive)
        XCTAssertTrue(rendered.pdfData.starts(with: Data("%PDF-".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: rendered.pdfData))
        XCTAssertEqual(document.pageCount, 1)
    }

    func testDeflateZipRoundTrips() throws {
        let bytes: [UInt8] = [
            80, 75, 3, 4, 20, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 18, 0, 0, 0, 16, 0, 0, 0, 9, 0, 0, 0,
            104, 101, 108, 108, 111, 46, 116, 120, 116, 203, 72, 205, 201, 201, 87, 40, 74, 205, 77, 44, 202, 78, 76, 202, 73, 5, 0,
            80, 75, 1, 2, 20, 0, 20, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 18, 0, 0, 0, 16, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            104, 101, 108, 108, 111, 46, 116, 120, 116,
            80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 55, 0, 0, 0, 57, 0, 0, 0, 0, 0,
        ]
        let files = try ZipArchive.extract(Data(bytes))
        XCTAssertEqual(files["hello.txt"]?.data, Data("hello remarkable".utf8))
    }

    func testPageTimestampUsesTheEarliestClock() {
        let content = Data(#"""
        {"cPages":{"pages":[
            {"id":"page-a","template":{"timestamp":"1:1700000005000","value":"Blank"},"redir":{"timestamp":"1:1700000000000","value":0}},
            {"id":"page-b","template":{"timestamp":"0:0","value":"Blank"}},
            "page-c"
        ]}}
        """#.utf8)
        let dates = PageListing.addedDates(in: content)
        XCTAssertEqual(dates["page-a"], Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(dates["page-b"])
        XCTAssertNil(dates["page-c"])
        XCTAssertNil(PageListing.lwwDate("0:0"))
    }

    private func version5Page(from start: CGPoint, to end: CGPoint) -> Data {
        var data = Data("reMarkable .lines file, version=5".utf8)
        while data.count < 43 {
            data.append(0x20)
        }
        data.appendUInt32(1)
        data.appendUInt32(1)
        data.appendUInt32(2)
        data.appendUInt32(0)
        data.appendUInt32(0)
        data.appendFloat(2)
        data.appendUInt32(0)
        data.appendUInt32(2)
        for point in [start, end] {
            data.appendFloat(Float(point.x))
            data.appendFloat(Float(point.y))
            data.appendFloat(0)
            data.appendFloat(0)
            data.appendFloat(2)
            data.appendFloat(1)
        }
        return data
    }

    private func storedZip(entries: [String: Data]) -> Data {
        var local = Data()
        var central = Data()
        for name in entries.keys.sorted() {
            let payload = entries[name] ?? Data()
            let nameBytes = Data(name.utf8)
            let offset = UInt32(local.count)
            local.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(0)
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt32(UInt32(payload.count))
            local.appendUInt16(UInt16(nameBytes.count))
            local.appendUInt16(0)
            local.append(nameBytes)
            local.append(payload)

            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(offset)
            central.append(nameBytes)
        }
        var archive = local
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt32(UInt32(central.count))
        archive.appendUInt32(centralOffset)
        archive.appendUInt16(0)
        return archive
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendFloat(_ value: Float) {
        appendUInt32(value.bitPattern)
    }
}
