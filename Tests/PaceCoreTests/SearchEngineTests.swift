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

    func testEqualMatchQualityPromotesRecentlyFrequentItem() {
        let now = Date()
        var frequent = record(preview: "project notes", searchable: "project notes", kind: .text,
                              date: now.addingTimeInterval(-24 * 60 * 60))
        frequent.copyCount = 8
        let oneOff = record(preview: "project summary", searchable: "project summary", kind: .text,
                            date: now)

        let results = SearchEngine.search([oneOff, frequent], query: "project", now: now)

        XCTAssertEqual(results.map(\.id), [frequent.id, oneOff.id])
    }

    func testEqualMatchQualityPromotesItemRecentlyUsedInPace() {
        let now = Date()
        var used = record(preview: "project notes", searchable: "project notes", kind: .text,
                          date: now.addingTimeInterval(-14 * 24 * 60 * 60))
        used.lastUsedAt = now
        used.useCount = 1
        let justCopied = record(preview: "project summary", searchable: "project summary", kind: .text,
                                date: now)

        let results = SearchEngine.search([justCopied, used], query: "project", now: now)

        XCTAssertEqual(results.map(\.id), [used.id, justCopied.id])
    }

    func testRecentPaceUsageCanOvertakeOneMatchTier() {
        let now = Date()
        var prefixMatch = record(
            preview: "tomo.wvlen.llc",
            searchable: "tomo.wvlen.llc",
            kind: .text,
            date: now.addingTimeInterval(-26 * 24 * 60 * 60)
        )
        prefixMatch.lastUsedAt = now
        prefixMatch.useCount = 2
        var usedContainsMatch = record(
            preview: "https://github.com/danielcorin/Tomo",
            searchable: "https://github.com/danielcorin/Tomo",
            kind: .text,
            date: now.addingTimeInterval(-5 * 60 * 60)
        )
        usedContainsMatch.lastUsedAt = now
        usedContainsMatch.useCount = 4

        let results = SearchEngine.search(
            [prefixMatch, usedContainsMatch],
            query: "tomo",
            now: now
        )

        XCTAssertEqual(results.map(\.id), [usedContainsMatch.id, prefixMatch.id])
    }

    func testFrecencyCannotOvertakeMatchTwoTiersBetter() {
        let now = Date()
        let exactMatch = record(
            preview: "Tomo",
            searchable: "Tomo",
            kind: .text,
            date: now.addingTimeInterval(-14 * 24 * 60 * 60)
        )
        var heavilyUsedContainsMatch = record(
            preview: "https://github.com/danielcorin/Tomo",
            searchable: "https://github.com/danielcorin/Tomo",
            kind: .text,
            date: now
        )
        heavilyUsedContainsMatch.lastUsedAt = now
        heavilyUsedContainsMatch.useCount = 10_000

        let results = SearchEngine.search(
            [heavilyUsedContainsMatch, exactMatch],
            query: "tomo",
            now: now
        )

        XCTAssertEqual(results.map(\.id), [exactMatch.id, heavilyUsedContainsMatch.id])
    }

    func testFrequencyFadesAsItemGetsOlder() {
        let now = Date()
        var staleFrequent = record(preview: "project notes", searchable: "project notes", kind: .text,
                                   date: now.addingTimeInterval(-21 * 24 * 60 * 60))
        staleFrequent.copyCount = 64
        let recent = record(preview: "project summary", searchable: "project summary", kind: .text,
                            date: now)

        let results = SearchEngine.search([staleFrequent, recent], query: "project", now: now)

        XCTAssertEqual(results.map(\.id), [recent.id, staleFrequent.id])
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
