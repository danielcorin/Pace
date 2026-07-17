import XCTest
@testable import PaceCore

final class SearchEngineTests: XCTestCase {
    func testSearchRanksMatchQualityThenRecency() {
        let now = Date()
        // Exact preview match outranks a newer content-only match.
        let exactButOlder = record(
            preview: "Invoice 1042",
            searchable: "Invoice 1042",
            kind: .text,
            date: now.addingTimeInterval(-3_600)
        )
        var newerImage = record(
            preview: "Quarterly report",
            searchable: "Screenshot OCR invoice 1042",
            kind: .image,
            date: now
        )
        newerImage.hasOCR = true
        let nonMatch = record(preview: "grocery list", searchable: "grocery list", kind: .text, date: now)

        let results = SearchEngine.search([newerImage, nonMatch, exactButOlder], query: "invoice 1042", now: now)

        XCTAssertEqual(results.map(\.id), [exactButOlder.id, newerImage.id])
    }

    func testEqualMatchQualityOrdersByRecency() {
        let now = Date()
        let older = record(preview: "notes", searchable: "meeting notes budget", kind: .text,
                           date: now.addingTimeInterval(-600))
        let newer = record(preview: "summary", searchable: "budget summary draft", kind: .text, date: now)

        let results = SearchEngine.search([older, newer], query: "budget", now: now)

        XCTAssertEqual(results.map(\.id), [newer.id, older.id])
    }

    func testEmptyQueryOrdersNewestFirstDespiteScoreBonuses() {
        let now = Date()
        var frequent = record(preview: "old favorite", searchable: "old favorite", kind: .text,
                              date: now.addingTimeInterval(-7_200))
        frequent.copyCount = 40
        frequent.isPinned = true
        let middle = record(preview: "middle", searchable: "middle", kind: .text,
                            date: now.addingTimeInterval(-60))
        let newest = record(preview: "just copied", searchable: "just copied", kind: .text, date: now)

        let results = SearchEngine.search([frequent, middle, newest], query: "", now: now)

        XCTAssertEqual(results.map(\.id), [newest.id, middle.id, frequent.id])
    }

    func testStructuredFilters() {
        var image = record(preview: "Diagram", searchable: "launch plan", kind: .image)
        image.hasOCR = true
        image.isPinned = true
        let text = record(preview: "launch plan", searchable: "launch plan", kind: .text)

        let results = SearchEngine.search([text, image], query: "type:image is:pinned has:ocr launch")

        XCTAssertEqual(results.map(\.id), [image.id])
    }

    private func record(
        preview: String,
        searchable: String,
        kind: ClipboardContentKind,
        date: Date = Date()
    ) -> ClipboardRecord {
        ClipboardRecord(
            item: ClipboardItem(
                createdAt: date,
                lastCopiedAt: date,
                source: ClipboardSource(kind: .application, name: "Tests"),
                kind: kind,
                representations: [],
                preview: preview,
                searchableText: searchable,
                fingerprint: UUID().uuidString,
                byteCount: 10
            )
        )
    }
}
