import XCTest
@testable import Inkpick

final class DocumentDecodingTests: XCTestCase {
    func testFixtureDecodesNamesTypesAndFields() throws {
        let bundle = Bundle(for: DocumentDecodingTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "documents", withExtension: "json")
        )
        let items = try JSONDecoder().decode([RemarkableItem].self, from: Data(contentsOf: url))

        let notebook = try XCTUnwrap(items.first { $0.id == "bef8acd7-2e2a-458d-80bf-0cd0ffc7aedd" })
        XCTAssertEqual(notebook.visibleName, "My Notebook")
        XCTAssertEqual(notebook.kind, .document)
        XCTAssertTrue(notebook.isDocument)
        XCTAssertEqual(notebook.fileType, "notebook")
        XCTAssertEqual(notebook.currentPage, 1)
        XCTAssertFalse(notebook.bookmarked)
        XCTAssertEqual(notebook.parent, "")
        XCTAssertEqual(notebook.modifiedClient, "2023-08-05T12:51:55.584Z")

        let folder = try XCTUnwrap(items.first { $0.id == "5f3c91fe-d8bc-4927-a426-646cf5fdea54" })
        XCTAssertEqual(folder.visibleName, "My Folder")
        XCTAssertEqual(folder.kind, .collection)
        XCTAssertTrue(folder.isFolder)
        XCTAssertTrue(folder.bookmarked)
        XCTAssertNil(folder.currentPage)
        XCTAssertNil(folder.fileType)
    }

    func testMissingNameBecomesUntitled() throws {
        let data = Data(#"[{"ID":"x","Type":"DocumentType"}]"#.utf8)
        let items = try JSONDecoder().decode([RemarkableItem].self, from: data)
        XCTAssertEqual(items.first?.visibleName, "Untitled")
        XCTAssertEqual(items.first?.parent, "")
        XCTAssertFalse(items.first?.bookmarked ?? true)
    }

    func testClientDecodesEmptyAndNullLists() throws {
        XCTAssertEqual(try RemarkableClient.decodeItems(from: Data()), [])
        XCTAssertEqual(try RemarkableClient.decodeItems(from: Data("null".utf8)), [])
        XCTAssertEqual(try RemarkableClient.decodeItems(from: Data("[]".utf8)), [])
    }

    func testUSBHostIsFixed() {
        XCTAssertEqual(RemarkableClient.baseURL.scheme, "http")
        XCTAssertEqual(RemarkableClient.baseURL.host, "10.11.99.1")
        XCTAssertEqual(
            RemarkableClient.url(for: "documents/").absoluteString,
            "http://10.11.99.1/documents/"
        )
        XCTAssertEqual(
            RemarkableClient.url(for: "download/abc/pdf").absoluteString,
            "http://10.11.99.1/download/abc/pdf"
        )
        XCTAssertEqual(
            RemarkableClient.searchURL(keyword: "hello world").absoluteString,
            "http://10.11.99.1/search/hello%20world"
        )
    }
}
