import Foundation
import XCTest
@testable import PaceCore

final class SnippetTemplateTests: XCTestCase {
    func testRendersClipboardDatesModifiersAndCursor() throws {
        let context = SnippetRenderingContext(
            now: Date(timeIntervalSince1970: 1_725_235_200),
            localeIdentifier: "en_US_POSIX",
            timeZoneIdentifier: "UTC",
            clipboardItems: ["  first value  ", "Second Value"]
        )
        let rendered = try SnippetTemplateRenderer.render(
            "{date format=\"yyyy-MM-dd\" offset=\"+1d\"}: {clipboard offset=1 | lowercase}{cursor}!",
            context: context
        )
        XCTAssertEqual(rendered.text, "2024-09-03: second value!")
        XCTAssertEqual(rendered.cursorMovementFromEnd, 1)
    }

    func testLeavesCodeBracesLiteralAndSupportsEscapedBraces() throws {
        let rendered = try SnippetTemplateRenderer.render("function x() { return {{ok}}; }")
        XCTAssertEqual(rendered.text, "function x() { return {ok}; }")
    }

    func testRendersTimezoneAwareISO8601DateTime() throws {
        let source = ISO8601DateFormatter().date(from: "2026-06-03T17:25:05Z")!
        let context = SnippetRenderingContext(
            now: source,
            localeIdentifier: "en_US_POSIX",
            timeZoneIdentifier: "America/New_York"
        )

        XCTAssertEqual(
            try SnippetTemplateRenderer.render(
                "{datetime format=iso8601}",
                context: context
            ).text,
            "2026-06-03T13:25:05-04:00"
        )
    }

    func testRendersNestedSnippetAndDetectsCycle() throws {
        var context = SnippetRenderingContext(snippetTemplates: [
            "Email": "person@example.com",
            "Signature": "Contact {snippet name=\"Email\"}"
        ])
        XCTAssertEqual(
            try SnippetTemplateRenderer.render("{snippet name=\"Signature\"}", context: context).text,
            "Contact person@example.com"
        )

        context.snippetTemplates["Email"] = "{snippet name=\"Signature\"}"
        XCTAssertThrowsError(
            try SnippetTemplateRenderer.render("{snippet name=\"Email\"}", context: context)
        )
    }

    func testRejectsMissingClipboardOffsetAndDuplicateCursor() throws {
        XCTAssertThrowsError(
            try SnippetTemplateRenderer.render(
                "{clipboard offset=2}",
                context: SnippetRenderingContext(clipboardItems: ["one"])
            )
        )
        XCTAssertThrowsError(try SnippetTemplateRenderer.render("{cursor}x{cursor}"))
    }
}
