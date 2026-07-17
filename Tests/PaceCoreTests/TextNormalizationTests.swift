import XCTest
@testable import PaceCore

final class TextNormalizationTests: XCTestCase {
    func testTrimmedSingleLineTrimsAndCollapsesWhitespace() {
        let input = " \t First line \n\n Second\t\tline \r\n Third line\u{00A0} "

        XCTAssertEqual(input.trimmedSingleLine, "First line Second line Third line")
    }

    func testTrimmedSingleLinePreservesNonWhitespaceCharacters() {
        XCTAssertEqual("https://example.com/a?b=1&c=2".trimmedSingleLine, "https://example.com/a?b=1&c=2")
    }

    func testTrimmedSingleLineReturnsEmptyForWhitespaceOnlyInput() {
        XCTAssertEqual(" \n\t\r ".trimmedSingleLine, "")
    }
}
