import XCTest
@testable import Inkpick

final class ReadingOrderTests: XCTestCase {
    func testSortsTopToBottomThenLeftToRight() {
        let lines = [
            RecognizedLine(text: "bottom", minX: 0.1, midY: 0.2),
            RecognizedLine(text: "right", minX: 0.7, midY: 0.8),
            RecognizedLine(text: "left", minX: 0.1, midY: 0.8),
        ]
        XCTAssertEqual(ReadingOrder.sort(lines).map(\.text), ["left", "right", "bottom"])
    }

    func testTreatsNearbyBaselinesAsOneLine() {
        let lines = [
            RecognizedLine(text: "b", minX: 0.5, midY: 0.50),
            RecognizedLine(text: "a", minX: 0.1, midY: 0.51),
            RecognizedLine(text: "c", minX: 0.1, midY: 0.20),
        ]
        XCTAssertEqual(ReadingOrder.sort(lines).map(\.text), ["a", "b", "c"])
    }

    func testJoinInsertsNewlinesInReadingOrder() {
        let lines = [
            RecognizedLine(text: "two", minX: 0, midY: 0.1),
            RecognizedLine(text: "one", minX: 0, midY: 0.9),
        ]
        XCTAssertEqual(ReadingOrder.join(lines), "one\ntwo")
    }
}
