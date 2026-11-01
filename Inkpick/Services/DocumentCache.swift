import Foundation

struct DocumentCache: Sendable {
    var root: URL

    static func makeDefault() throws -> DocumentCache {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("Inkpick", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return DocumentCache(root: root)
    }

    func pdfURL(for item: RemarkableItem) -> URL {
        directory(for: item).appendingPathComponent("document.pdf")
    }

    func transcriptURL(for item: RemarkableItem) -> URL {
        directory(for: item).appendingPathComponent("transcript.json")
    }

    func pageStampsURL(for item: RemarkableItem) -> URL {
        directory(for: item).appendingPathComponent("pages.json")
    }

    func hasPageStamps(for item: RemarkableItem) -> Bool {
        FileManager.default.fileExists(atPath: pageStampsURL(for: item).path)
    }

    func loadPageStamps(for item: RemarkableItem) -> [PageStamp?] {
        let url = pageStampsURL(for: item)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder.pageStamps.decode([String: StoredPageStamp].self, from: data) else {
            return []
        }
        let indexed = stored.compactMap { key, value -> (Int, PageStamp)? in
            guard let index = Int(key), let stamp = value.stamp else { return nil }
            return (index, stamp)
        }
        guard let last = indexed.map(\.0).max() else { return [] }
        var pages = Array<PageStamp?>(repeating: nil, count: last + 1)
        for (index, stamp) in indexed {
            pages[index] = stamp
        }
        return pages
    }

    func savePageStamps(_ pages: [PageStamp?], for item: RemarkableItem) throws {
        let directory = directory(for: item)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored: [String: StoredPageStamp] = [:]
        for (index, stamp) in pages.enumerated() {
            guard let stamp else { continue }
            stored[String(index)] = StoredPageStamp(stamp)
        }
        let data = try JSONEncoder.pageStamps.encode(stored)
        try data.write(to: pageStampsURL(for: item), options: .atomic)
    }

    func loadTranscript(for item: RemarkableItem) -> [Int: String] {
        let url = transcriptURL(for: item)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        var pages: [Int: String] = [:]
        for (key, value) in stored {
            if let index = Int(key) {
                pages[index] = value
            }
        }
        return pages
    }

    func saveTranscript(_ pages: [Int: String], for item: RemarkableItem) throws {
        let directory = directory(for: item)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = Dictionary(uniqueKeysWithValues: pages.map { (String($0.key), $0.value) })
        let data = try JSONEncoder().encode(stored)
        try data.write(to: transcriptURL(for: item), options: .atomic)
    }

    private func directory(for item: RemarkableItem) -> URL {
        let stamp = (item.modifiedClient ?? "unknown")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return root
            .appendingPathComponent(item.id, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }
}

enum PageStamp: Equatable, Sendable {
    case added(Date)
    case edited(Date)

    var date: Date {
        switch self {
        case .added(let date), .edited(let date):
            return date
        }
    }

    var label: String {
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        switch self {
        case .added:
            return "Added \(formatted)"
        case .edited:
            return "Edited \(formatted)"
        }
    }
}

private struct StoredPageStamp: Codable {
    var kind: String
    var date: Date

    init(_ stamp: PageStamp) {
        switch stamp {
        case .added(let date):
            kind = "added"
            self.date = date
        case .edited(let date):
            kind = "edited"
            self.date = date
        }
    }

    var stamp: PageStamp? {
        switch kind {
        case "added":
            return .added(date)
        case "edited":
            return .edited(date)
        default:
            return nil
        }
    }
}

private extension JSONDecoder {
    static var pageStamps: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var pageStamps: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
