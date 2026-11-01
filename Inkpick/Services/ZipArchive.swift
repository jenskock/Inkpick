import Foundation

enum ZipArchiveError: Error {
    case invalid
    case unsupported
}

struct ZipFile: Sendable {
    var data: Data
    var modified: Date?
}

enum ZipArchive {
    static func extract(_ data: Data) throws -> [String: ZipFile] {
        guard let directory = centralDirectory(in: data) else {
            throw ZipArchiveError.invalid
        }
        var files: [String: ZipFile] = [:]
        var cursor = directory.offset
        for _ in 0..<directory.count {
            let entry = try centralEntry(in: data, at: &cursor)
            let bytes = try inflate(entry, in: data)
            files[entry.name] = ZipFile(data: bytes, modified: entry.modified)
        }
        return files
    }

    private struct CentralDirectory {
        var count: Int
        var offset: Int
    }

    private struct Entry {
        var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
        var modified: Date?
    }

    private static func centralDirectory(in data: Data) -> CentralDirectory? {
        let signature: UInt32 = 0x06054b50
        let limit = min(data.count, 65_557)
        guard data.count >= 22 else { return nil }
        var position = data.count - 22
        let earliest = data.count - limit
        while position >= earliest {
            if readUInt32(data, position) == signature {
                let count = Int(readUInt16(data, position + 10))
                let offset = Int(readUInt32(data, position + 16))
                guard offset != 0xFFFF_FFFF, offset + 4 <= data.count else { return nil }
                return CentralDirectory(count: count, offset: offset)
            }
            if position == 0 { break }
            position -= 1
        }
        return nil
    }

    private static func centralEntry(in data: Data, at cursor: inout Int) throws -> Entry {
        guard readUInt32(data, cursor) == 0x02014b50 else {
            throw ZipArchiveError.invalid
        }
        let method = Int(readUInt16(data, cursor + 10))
        let modified = modifiedDate(time: readUInt16(data, cursor + 12), date: readUInt16(data, cursor + 14))
        let compressed = Int(readUInt32(data, cursor + 20))
        let uncompressed = Int(readUInt32(data, cursor + 24))
        let nameLength = Int(readUInt16(data, cursor + 28))
        let extraLength = Int(readUInt16(data, cursor + 30))
        let commentLength = Int(readUInt16(data, cursor + 32))
        let localOffset = Int(readUInt32(data, cursor + 42))
        let nameStart = cursor + 46
        let nameEnd = nameStart + nameLength
        guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, nameEnd <= data.count else {
            throw ZipArchiveError.unsupported
        }
        let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
        cursor = nameEnd + extraLength + commentLength
        guard cursor <= data.count else { throw ZipArchiveError.invalid }
        return Entry(
            name: name,
            method: method,
            compressedSize: compressed,
            uncompressedSize: uncompressed,
            localOffset: localOffset,
            modified: modified
        )
    }

    /// ZIP stores a calendar time with no timezone. Day or month zero means the stamp was left blank.
    private static func modifiedDate(time: UInt16, date: UInt16) -> Date? {
        let day = Int(date & 0x1F)
        let month = Int((date >> 5) & 0xF)
        let year = 1980 + Int(date >> 9)
        guard (1...31).contains(day), (1...12).contains(month), year >= 2010 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return components.date
    }

    private static func inflate(_ entry: Entry, in data: Data) throws -> Data {
        guard readUInt32(data, entry.localOffset) == 0x04034b50 else {
            throw ZipArchiveError.invalid
        }
        let nameLength = Int(readUInt16(data, entry.localOffset + 26))
        let extraLength = Int(readUInt16(data, entry.localOffset + 28))
        let start = entry.localOffset + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else { throw ZipArchiveError.invalid }
        let compressed = data[start..<end]
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else { throw ZipArchiveError.invalid }
            return Data(compressed)
        case 8:
            return try inflateRaw(compressed, uncompressedSize: entry.uncompressedSize)
        default:
            throw ZipArchiveError.unsupported
        }
    }

    private static func inflateRaw(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize >= 0 else { throw ZipArchiveError.invalid }
        if uncompressedSize == 0 { return Data() }
        var output = Data(count: uncompressedSize)
        let decoded = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source in
                var written: Int32 = 0
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                let status = inkpick_inflate_raw(
                    sourceBase,
                    Int32(data.count),
                    destinationBase,
                    Int32(uncompressedSize),
                    &written
                )
                return status == 0 ? Int(written) : -1
            }
        }
        guard decoded == uncompressedSize else { throw ZipArchiveError.invalid }
        return output
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

@_silgen_name("inkpick_inflate_raw")
private func inkpick_inflate_raw(
    _ source: UnsafePointer<UInt8>,
    _ sourceLength: Int32,
    _ destination: UnsafeMutablePointer<UInt8>,
    _ destinationCapacity: Int32,
    _ written: UnsafeMutablePointer<Int32>
) -> Int32
