import XCTest
@testable import PaceCore

final class SensitiveContentDetectorTests: XCTestCase {
    private let detector = SensitiveContentDetector()

    func testConcealedPasteboardTypeIsSensitive() {
        XCTAssertTrue(
            detector.isSensitive(
                typeIdentifiers: ["org.nspasteboard.ConcealedType"],
                text: "ordinary text"
            )
        )
    }

    func testPrivateKeyIsSensitive() {
        XCTAssertTrue(
            detector.isSensitive(
                typeIdentifiers: ["public.utf8-plain-text"],
                text: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret"
            )
        )
    }

    func testNormalTextIsRetained() {
        XCTAssertFalse(
            detector.isSensitive(
                typeIdentifiers: ["public.utf8-plain-text"],
                text: "A normal clipboard entry"
            )
        )
    }

    func testPaymentCardNumbersAreSensitive() {
        // Luhn-valid Visa and Amex test numbers, contiguous and grouped.
        XCTAssertTrue(detector.isSensitive(typeIdentifiers: [], text: "card 4111111111111111 exp 10/28"))
        XCTAssertTrue(detector.isSensitive(typeIdentifiers: [], text: "4111 1111 1111 1111"))
        XCTAssertTrue(detector.isSensitive(typeIdentifiers: [], text: "3782 822463 10005"))
    }

    func testCrashReportNumbersAreRetained() {
        // Long numeric IDs (mach times, register values) are not card
        // numbers: wrong prefixes, wrong lengths, or Luhn-invalid.
        let crashReport = """
        Process: Reco [64723]
        "procStartAbsTime" : 4529519528090,
        "procExitAbsTime" : 6276914386420,
        {"value":8236553681501290676},
        {"value":18446744073709551600}
        Time Awake Since Boot: 260000 seconds
        """
        XCTAssertFalse(detector.isSensitive(typeIdentifiers: ["public.utf8-plain-text"], text: crashReport))
    }
}
