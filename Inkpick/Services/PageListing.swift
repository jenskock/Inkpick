import Foundation

struct ListedPage: Sendable {
    var ink: InkPage
    var stamp: PageStamp?
}

enum PageListing {
    /// Earliest timestamp recorded on each page. The notebook stores this as `author:unix-milliseconds`.
    static func addedDates(in content: Data) -> [String: Date] {
        guard let object = try? JSONSerialization.jsonObject(with: content) as? [String: Any] else {
            return [:]
        }
        var dates: [String: Date] = [:]
        for entry in pageEntries(in: object) {
            guard let identifier = identifier(of: entry), let date = earliestTimestamp(in: entry) else { continue }
            dates[identifier] = date
        }
        return dates
    }

    static func pages(in files: [String: ZipFile]) -> [ListedPage] {
        let content = files.first { $0.key.lowercased().hasSuffix(".content") }?.value.data
        let added = content.map { addedDates(in: $0) } ?? [:]
        let lineFiles = files.filter { name, _ in
            let lower = name.lowercased()
            return lower.hasSuffix(".rm") && !lower.contains("__macosx")
        }
        let fileTimesDiffer = modificationTimesDiffer(lineFiles.values.compactMap(\.modified))
        let ordered = orderedPages(content: content, lineFiles: lineFiles)

        return ordered.map { page in
            let file = page.fileName.flatMap { lineFiles[$0] }
            let ink = file.map { RemarkableLines.page(from: $0.data) } ?? .empty
            let stamp: PageStamp?
            if let identifier = page.identifier, let date = added[identifier] {
                stamp = .added(date)
            } else if fileTimesDiffer, let modified = file?.modified {
                stamp = .edited(modified)
            } else {
                stamp = nil
            }
            return ListedPage(ink: ink, stamp: stamp)
        }
    }

    private struct PageRef {
        var identifier: String?
        var fileName: String?
    }

    private static func orderedPages(content: Data?, lineFiles: [String: ZipFile]) -> [PageRef] {
        let identifiers = content.map { pageIdentifiers(in: $0) } ?? []
        func match(_ identifier: String) -> String? {
            lineFiles.keys.first {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == identifier
            }
        }
        if !identifiers.isEmpty {
            return identifiers.map { PageRef(identifier: $0, fileName: match($0)) }
        }
        return lineFiles.keys.sorted().map { name in
            PageRef(
                identifier: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
                fileName: name
            )
        }
    }

    private static func pageIdentifiers(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return pageEntries(in: object).compactMap(identifier(of:))
    }

    private static func pageEntries(in object: [String: Any]) -> [Any] {
        if let pages = object["pages"] as? [String] {
            return pages
        }
        if let pages = object["pages"] as? [Any] {
            return pages
        }
        if let container = object["cPages"] as? [String: Any], let pages = container["pages"] as? [Any] {
            return pages
        }
        return []
    }

    private static func identifier(of entry: Any) -> String? {
        if let string = entry as? String {
            return string
        }
        guard let object = entry as? [String: Any] else { return nil }
        return object["id"] as? String ?? object["value"] as? String
    }

    private static func earliestTimestamp(in entry: Any) -> Date? {
        var dates: [Date] = []
        collectTimestamps(in: entry, into: &dates)
        return dates.min()
    }

    private static func collectTimestamps(in value: Any, into dates: inout [Date]) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key == "timestamp", let string = child as? String, let date = lwwDate(string) {
                    dates.append(date)
                } else {
                    collectTimestamps(in: child, into: &dates)
                }
            }
        } else if let list = value as? [Any] {
            for child in list {
                collectTimestamps(in: child, into: &dates)
            }
        }
    }

    /// `1:1700000000000` is device 1 and a unix time in milliseconds. `0:0` is an empty clock.
    static func lwwDate(_ string: String) -> Date? {
        let parts = string.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let millis = Double(parts[1]) else { return nil }
        guard millis >= 1_500_000_000_000, millis < 4_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private static func modificationTimesDiffer(_ dates: [Date]) -> Bool {
        guard let first = dates.first else { return false }
        return dates.contains { abs($0.timeIntervalSince(first)) > 2 }
    }
}
