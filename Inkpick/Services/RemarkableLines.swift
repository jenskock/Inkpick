import Foundation

struct InkPoint: Sendable {
    var x: Float
    var y: Float
    var width: Float
}

struct InkStroke: Sendable {
    var points: [InkPoint]
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var isHighlighter: Bool
}

struct InkPage: Sendable {
    var strokes: [InkStroke]
    var text: String
    /// Version 6 stores x as a distance from the middle of the page.
    var usesCenterOrigin: Bool

    static let empty = InkPage(strokes: [], text: "", usesCenterOrigin: false)
}

enum RemarkableLines {
    static func page(from data: Data) -> InkPage {
        guard data.count >= 43 else { return .empty }
        let version = data[32]
        if version >= UInt8(ascii: "6") {
            return parseVersion6(data)
        }
        if version == UInt8(ascii: "3") || version == UInt8(ascii: "5") {
            return parseClassic(data, shortStrokeHeader: version == UInt8(ascii: "3"))
        }
        return .empty
    }

    private static func parseClassic(_ data: Data, shortStrokeHeader: Bool) -> InkPage {
        var cursor = ByteCursor(data: data, offset: 43)
        guard let layerCount = try? cursor.u32(), layerCount < 100 else { return .empty }
        var strokes: [InkStroke] = []
        for _ in 0..<layerCount {
            guard let strokeCount = try? cursor.u32(), strokeCount < 100_000 else { break }
            for _ in 0..<strokeCount {
                do {
                    if let stroke = try classicStroke(&cursor, shortHeader: shortStrokeHeader) {
                        strokes.append(stroke)
                    }
                } catch {
                    break
                }
            }
        }
        return InkPage(strokes: strokes, text: "", usesCenterOrigin: false)
    }

    private static func classicStroke(_ cursor: inout ByteCursor, shortHeader: Bool) throws -> InkStroke? {
        let pen = try cursor.u32()
        let color = try cursor.u32()
        _ = try cursor.u32()
        let baseWidth = try cursor.f32()
        if !shortHeader {
            _ = try cursor.u32()
        }
        let count = try cursor.u32()
        guard count < 200_000 else { throw LinesError.overflow }
        var points: [InkPoint] = []
        points.reserveCapacity(Int(count))
        for _ in 0..<count {
            let x = try cursor.f32()
            let y = try cursor.f32()
            _ = try cursor.f32()
            _ = try cursor.f32()
            let width = try cursor.f32()
            _ = try cursor.f32()
            let used = width > 0 ? width : baseWidth
            points.append(InkPoint(x: x, y: y, width: min(max(used, 0.4), 40)))
        }
        return styledStroke(points: points, pen: pen, color: color, rgba: nil)
    }

    private static func parseVersion6(_ data: Data) -> InkPage {
        var cursor = ByteCursor(data: data, offset: 43)
        var strokes: [InkStroke] = []
        var text: [String] = []
        while cursor.remaining >= 8 {
            guard let size = try? cursor.u32() else { break }
            guard (try? cursor.u8()) != nil else { break }
            _ = try? cursor.u8()
            guard let current = try? cursor.u8(), let type = try? cursor.u8() else { break }
            guard size < 50_000_000, cursor.remaining >= Int(size) else { break }
            let payload = cursor.take(Int(size))
            switch type {
            case 0x05:
                if let stroke = try? version6Stroke(payload, pointVersion: Int(current)) {
                    strokes.append(stroke)
                }
            case 0x07:
                if let pageText = try? version6Text(payload), !pageText.isEmpty {
                    text.append(pageText)
                }
            default:
                break
            }
        }
        return InkPage(
            strokes: strokes,
            text: text.joined(separator: "\n"),
            usesCenterOrigin: true
        )
    }

    private static func version6Stroke(_ data: Data, pointVersion: Int) throws -> InkStroke? {
        var cursor = ByteCursor(data: data)
        try cursor.expect(index: 1, type: 0xF)
        _ = try cursor.crdtID()
        try cursor.expect(index: 2, type: 0xF)
        _ = try cursor.crdtID()
        try cursor.expect(index: 3, type: 0xF)
        _ = try cursor.crdtID()
        try cursor.expect(index: 4, type: 0xF)
        _ = try cursor.crdtID()
        try cursor.expect(index: 5, type: 0x4)
        let deleted = try cursor.u32()
        guard deleted == 0 else { return nil }
        guard cursor.matches(index: 6, type: 0xC) else { return nil }
        try cursor.expect(index: 6, type: 0xC)
        let valueLength = try cursor.u32()
        let value = cursor.take(Int(valueLength))
        var valueCursor = ByteCursor(data: value)
        guard try valueCursor.u8() == 0x03 else { return nil }
        try valueCursor.expect(index: 1, type: 0x4)
        let pen = try valueCursor.u32()
        try valueCursor.expect(index: 2, type: 0x4)
        let color = try valueCursor.u32()
        try valueCursor.expect(index: 3, type: 0x8)
        let thickness = try valueCursor.f64()
        try valueCursor.expect(index: 4, type: 0x4)
        _ = try valueCursor.f32()
        try valueCursor.expect(index: 5, type: 0xC)
        let pointBytes = Int(try valueCursor.u32())
        let pointData = valueCursor.take(pointBytes)
        _ = valueCursor.optionalID(index: 6)
        _ = valueCursor.optionalID(index: 7)
        let rgba = valueCursor.optionalColor(index: 8)
        let points = try pointsFrom(pointData, version: pointVersion, thickness: thickness)
        return styledStroke(points: points, pen: pen, color: color, rgba: rgba)
    }

    private static func pointsFrom(_ data: Data, version: Int, thickness: Double) throws -> [InkPoint] {
        let stride = version <= 1 ? 24 : 14
        guard data.count % stride == 0 else { throw LinesError.overflow }
        let count = data.count / stride
        guard count < 200_000 else { throw LinesError.overflow }
        let scale = thickness == 0 ? 1 : thickness
        var cursor = ByteCursor(data: data)
        var points: [InkPoint] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            let x = try cursor.f32()
            let y = try cursor.f32()
            let width: Float
            if version <= 1 {
                _ = try cursor.f32()
                _ = try cursor.f32()
                width = try cursor.f32() * Float(scale)
                _ = try cursor.f32()
            } else {
                _ = try cursor.u16()
                let stored = try cursor.u16()
                _ = try cursor.u8()
                _ = try cursor.u8()
                width = Float(stored) / 4 * Float(scale)
            }
            points.append(InkPoint(x: x, y: y, width: min(max(width, 0.4), 40)))
        }
        return points
    }

    private static func version6Text(_ data: Data) throws -> String {
        var cursor = ByteCursor(data: data)
        try cursor.expect(index: 1, type: 0xF)
        _ = try cursor.crdtID()
        try cursor.expect(index: 2, type: 0xC)
        let bodyLength = try cursor.u32()
        var body = ByteCursor(data: cursor.take(Int(bodyLength)))
        try body.expect(index: 1, type: 0xC)
        let itemsLength = try body.u32()
        var items = ByteCursor(data: body.take(Int(itemsLength)))
        try items.expect(index: 1, type: 0xC)
        _ = try items.u32()
        let count = try items.varuint()
        guard count < 100_000 else { throw LinesError.overflow }
        var pieces: [String] = []
        for _ in 0..<count {
            if let piece = try textItem(&items) {
                pieces.append(piece)
            }
        }
        return pieces.joined()
    }

    private static func textItem(_ cursor: inout ByteCursor) throws -> String? {
        try cursor.expect(index: 0, type: 0xC)
        let length = try cursor.u32()
        var item = ByteCursor(data: cursor.take(Int(length)))
        try item.expect(index: 2, type: 0xF)
        _ = try item.crdtID()
        try item.expect(index: 3, type: 0xF)
        _ = try item.crdtID()
        try item.expect(index: 4, type: 0xF)
        _ = try item.crdtID()
        try item.expect(index: 5, type: 0x4)
        let deleted = Int(try item.u32())
        guard item.matches(index: 6, type: 0xC) else { return nil }
        try item.expect(index: 6, type: 0xC)
        let textLength = try item.u32()
        var text = ByteCursor(data: item.take(Int(textLength)))
        let characterCount = try text.varuint()
        _ = try text.u8()
        guard characterCount < 100_000, text.remaining >= Int(characterCount) else { return nil }
        let bytes = text.take(Int(characterCount))
        guard var string = String(data: bytes, encoding: .utf8) else { return nil }
        if deleted > 0 {
            if deleted >= string.count { return nil }
            string = String(string.dropFirst(deleted))
        }
        return string
    }

    private static func styledStroke(
        points: [InkPoint],
        pen: UInt32,
        color: UInt32,
        rgba: (UInt8, UInt8, UInt8, UInt8)?
    ) -> InkStroke? {
        guard !points.isEmpty, pen != 6, pen != 8 else { return nil }
        let highlighter = pen == 5 || pen == 18
        let channels = inkColor(id: color, rgba: rgba, highlighter: highlighter)
        return InkStroke(
            points: points,
            red: channels.0,
            green: channels.1,
            blue: channels.2,
            alpha: channels.3,
            isHighlighter: highlighter
        )
    }

    private static func inkColor(
        id: UInt32,
        rgba: (UInt8, UInt8, UInt8, UInt8)?,
        highlighter: Bool
    ) -> (Double, Double, Double, Double) {
        if let rgba {
            let alpha = rgba.3 == 0 ? 1 : Double(rgba.3) / 255
            return (Double(rgba.0) / 255, Double(rgba.1) / 255, Double(rgba.2) / 255, highlighter ? 0.45 : alpha)
        }
        let rgb: (Double, Double, Double)
        switch id {
        case 1, 8:
            rgb = (0.45, 0.45, 0.45)
        case 2:
            rgb = (0.95, 0.95, 0.95)
        case 3, 9, 13:
            rgb = (0.93, 0.78, 0.18)
        case 4, 10:
            rgb = (0.18, 0.55, 0.28)
        case 5:
            rgb = (0.86, 0.35, 0.55)
        case 6:
            rgb = (0.18, 0.38, 0.78)
        case 7:
            rgb = (0.78, 0.18, 0.18)
        case 11:
            rgb = (0.15, 0.65, 0.75)
        case 12:
            rgb = (0.7, 0.2, 0.6)
        default:
            rgb = (0.08, 0.08, 0.08)
        }
        return (rgb.0, rgb.1, rgb.2, highlighter ? 0.45 : 1)
    }
}

private enum LinesError: Error {
    case tag
    case overflow
}

private struct ByteCursor {
    var data: Data
    var offset: Int = 0

    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) -> Data {
        guard count > 0, offset + count <= data.count else {
            offset = data.count
            return Data()
        }
        let slice = data[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw LinesError.overflow }
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw LinesError.overflow }
        let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw LinesError.overflow }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    mutating func f64() throws -> Double {
        guard remaining >= 8 else { throw LinesError.overflow }
        var bits: UInt64 = 0
        for shift in 0..<8 {
            bits |= UInt64(data[offset + shift]) << (8 * shift)
        }
        offset += 8
        return Double(bitPattern: bits)
    }

    mutating func varuint() throws -> UInt64 {
        var shift = 0
        var result: UInt64 = 0
        while shift <= 63 {
            let byte = try u8()
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw LinesError.overflow
    }

    mutating func crdtID() throws {
        _ = try u8()
        _ = try varuint()
    }

    func matches(index: Int, type: UInt8) -> Bool {
        var copy = self
        guard let tag = try? copy.varuint() else { return false }
        return Int(tag >> 4) == index && UInt8(tag & 0xF) == type
    }

    mutating func expect(index: Int, type: UInt8) throws {
        let tag = try varuint()
        guard Int(tag >> 4) == index, UInt8(tag & 0xF) == type else {
            throw LinesError.tag
        }
    }

    mutating func optionalID(index: Int) -> Bool {
        var copy = self
        guard (try? copy.expect(index: index, type: 0xF)) != nil else { return false }
        guard (try? copy.crdtID()) != nil else { return false }
        self = copy
        return true
    }

    mutating func optionalColor(index: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        var copy = self
        guard (try? copy.expect(index: index, type: 0x4)) != nil, let packed = try? copy.u32() else {
            return nil
        }
        self = copy
        return (
            UInt8((packed >> 16) & 0xFF),
            UInt8((packed >> 8) & 0xFF),
            UInt8(packed & 0xFF),
            UInt8((packed >> 24) & 0xFF)
        )
    }
}
