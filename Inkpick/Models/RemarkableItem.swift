import Foundation

struct RemarkableItem: Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var parent: String
    var kind: Kind
    var visibleName: String
    var fileType: String?
    var modifiedClient: String?
    var currentPage: Int?
    var bookmarked: Bool

    enum Kind: String, Codable, Sendable {
        case document = "DocumentType"
        case collection = "CollectionType"
    }

    var isFolder: Bool { kind == .collection }
    var isDocument: Bool { kind == .document }

    var symbolName: String {
        if isFolder { return "folder" }
        switch fileType {
        case "pdf":
            return "doc.richtext"
        case "epub":
            return "book.closed"
        default:
            return "note.text"
        }
    }

    var subtitle: String {
        let label: String
        if isFolder {
            label = "Folder"
        } else {
            switch fileType {
            case "pdf":
                label = "PDF"
            case "epub":
                label = "EPUB"
            case "notebook":
                label = "Notebook"
            default:
                label = "Note"
            }
        }
        guard let modified = ModifiedDateDisplay.string(from: modifiedClient) else {
            return label
        }
        return "\(label) · \(modified)"
    }
}

extension RemarkableItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case parent = "Parent"
        case type = "Type"
        case visibleName = "VisibleName"
        case vissibleName = "VissibleName"
        case fileType
        case modifiedClient = "ModifiedClient"
        case currentPage = "CurrentPage"
        case bookmarked = "Bookmarked"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        parent = try container.decodeIfPresent(String.self, forKey: .parent) ?? ""
        kind = try container.decode(Kind.self, forKey: .type)

        let spelled = try container.decodeIfPresent(String.self, forKey: .visibleName)
        let misspelled = try container.decodeIfPresent(String.self, forKey: .vissibleName)
        let name = spelled ?? misspelled ?? "Untitled"
        visibleName = name.isEmpty ? "Untitled" : name

        fileType = try container.decodeIfPresent(String.self, forKey: .fileType)
        modifiedClient = try container.decodeIfPresent(String.self, forKey: .modifiedClient)
        currentPage = Self.decodeFlexibleInt(container, key: .currentPage)
        bookmarked = try container.decodeIfPresent(Bool.self, forKey: .bookmarked) ?? false
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

enum ModifiedDateDisplay {
    static func string(from raw: String?) -> String? {
        guard let raw, let date = parse(raw) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
