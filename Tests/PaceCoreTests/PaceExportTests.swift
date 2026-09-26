import CryptoKit
import XCTest
@testable import PaceCore

final class PaceExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testArchiveRoundTripsItemsSnippetsAndText() async throws {
        let store = HistoryStore(rootURL: root.appendingPathComponent("Store"))
        try await store.unlock(with: SymmetricKey(size: .bits256))
        // Recent whole-second dates: older items would fall to the default
        // 30-day retention, and ISO 8601 keeps only millisecond precision.
        let older = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
        try await store.add(textItem("first", at: older))
        try await store.add(textItem("second", at: older.addingTimeInterval(60)))
        let items = try await store.allItems()
        XCTAssertEqual(items.map(\.plainText), ["second", "first"])

        let snippet = Snippet(
            name: "Sig",
            template: "Thanks,\n{cursor}",
            keyword: ";sig",
            createdAt: older,
            updatedAt: older
        )
        let data = try PaceExportCodec.encode(PaceExportArchive(clipboard: items, snippets: [snippet]))
        let decoded = try PaceExportCodec.decode(data)

        XCTAssertEqual(decoded.format, "pace-export")
        XCTAssertEqual(decoded.clipboard?.map(\.text), ["second", "first"])
        XCTAssertEqual(decoded.clipboard?.map(\.item), items)
        XCTAssertEqual(decoded.snippets, [snippet])
        XCTAssertFalse(PaceExportCodec.isEncrypted(data))
    }

    func testEncryptedExportRoundTripsAndHidesPlaintext() throws {
        let plaintext = Data("{\"format\":\"pace-export\",\"secret\":\"clipboard contents\"}".utf8)
        let encrypted = try PaceExportCodec.encrypt(plaintext, passphrase: "correct horse", iterations: 100_000)

        XCTAssertTrue(PaceExportCodec.isEncrypted(encrypted))
        XCTAssertNil(String(data: encrypted, encoding: .utf8)?.range(of: "clipboard contents"))
        XCTAssertEqual(try PaceExportCodec.decrypt(encrypted, passphrase: "correct horse"), plaintext)
        XCTAssertThrowsError(try PaceExportCodec.decrypt(encrypted, passphrase: "wrong horse")) { error in
            XCTAssertEqual((error as? PaceError)?.code, "authentication_failed")
        }
    }

    func testTamperedParametersFailAuthentication() throws {
        let encrypted = try PaceExportCodec.encrypt(Data("payload".utf8), passphrase: "correct horse", iterations: 100_000)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: encrypted) as? [String: Any])
        envelope["iterations"] = 100_001
        let tampered = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try PaceExportCodec.decrypt(tampered, passphrase: "correct horse"))
    }

    func testShortPassphrasesAreRejected() {
        XCTAssertThrowsError(try PaceExportCodec.encrypt(Data("x".utf8), passphrase: "short"))
    }

    func testWriteIsPrivateAndRefusesToOverwriteByDefault() throws {
        let url = root.appendingPathComponent("export.json")
        try PaceExportCodec.write(Data("one".utf8), to: url, overwrite: false)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        XCTAssertThrowsError(try PaceExportCodec.write(Data("two".utf8), to: url, overwrite: false))
        XCTAssertEqual(try Data(contentsOf: url), Data("one".utf8))

        try PaceExportCodec.write(Data("two".utf8), to: url, overwrite: true)
        XCTAssertEqual(try Data(contentsOf: url), Data("two".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    private func textItem(_ text: String, at date: Date) -> ClipboardItem {
        var item = ClipboardItem(
            createdAt: date,
            lastCopiedAt: date,
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .text,
            representations: [ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))],
            preview: text,
            searchableText: text,
            fingerprint: "",
            byteCount: Int64(text.utf8.count)
        )
        item.fingerprint = item.contentFingerprint
        return item
    }
}
