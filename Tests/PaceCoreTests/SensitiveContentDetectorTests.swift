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

    func testAPIKeysAndTokensAreSensitive() {
        // Synthetic values in each vendor's shape; none are real credentials.
        let alnum40 = String(repeating: "aB3dE5gH7j", count: 4)
        let hex64 = String(repeating: "0123456789abcdef", count: 4)
        let secrets = [
            "sk-ant-api03-\(alnum40)-\(alnum40)AA",
            "sk-ant-admin01-\(alnum40)",
            "sk-or-v1-\(hex64)",
            "sk-proj-\(alnum40)_\(alnum40)",
            "sk-svcacct-\(alnum40)",
            "sk-\(alnum40)",
            "gsk_\(alnum40)12",
            "hf_\(alnum40)",
            "xai-\(alnum40)\(alnum40)",
            "sk_live_\(alnum40)",
            "rk_test_\(alnum40)",
            "sk-live-\(alnum40)",
            "ghp_\(alnum40)",
            "github_pat_11ABCDEFG0\(alnum40)",
            "glpat-\(alnum40)",
            "npm_\(alnum40.prefix(36))",
            "AKIAIOSFODNN7EXAMPLE",
            "ASIAIOSFODNN7EXAMPLE",
            "AIzaSyA-\(alnum40.prefix(31))",
            "xoxb-1234567890-0987654321-\(alnum40)",
            "https://hooks.slack.com/services/T0000000/B0000000/\(alnum40)",
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.\(alnum40)",
            "OPENAI_API_KEY=\(alnum40)",
            "export DATABASE_PASSWORD='hunter2hunter2'",
            "  client_secret: 9f8e7d6c5b4a3f2e1d0c"
        ]
        for secret in secrets {
            XCTAssertTrue(
                detector.isSensitive(typeIdentifiers: [], text: "notes\n\(secret)\nmore notes"),
                "Expected sensitive: \(secret)"
            )
        }
    }

    func testLookalikesAreRetained() {
        let ordinary = [
            "git checkout sk-learn-upgrade-for-the-new-pipeline-work",
            "https://github.com/danielcorin/Pace/pull/42",
            "API_KEY = os.environ[\"API_KEY\"]",
            "GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}",
            "PASSWORD=changeme",
            "api_key: your-api-key-here",
            "const token = await fetchToken()",
            "550e8400-e29b-41d4-a716-446655440000",
            "commit 0123456789abcdef0123456789abcdef01234567",
            "The skeleton key opens every door."
        ]
        for text in ordinary {
            XCTAssertFalse(
                detector.isSensitive(typeIdentifiers: ["public.utf8-plain-text"], text: text),
                "Expected retained: \(text)"
            )
        }
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
