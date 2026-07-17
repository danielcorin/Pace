import CryptoKit
import XCTest
@testable import PaceCore

final class HistoryStoreTests: XCTestCase {
    func testEncryptedRoundTripAndDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let key = SymmetricKey(size: .bits256)
        try await store.unlock(with: key)

        let item = ClipboardItem(
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .text,
            representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("hello".utf8))
            ],
            preview: "hello",
            searchableText: "hello",
            fingerprint: "same",
            byteCount: 5
        )
        let first = try await store.add(item)
        _ = try await store.add(item)

        let records = try await store.allRecords()
        let restored = try await store.item(id: first.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(restored.copyCount, 2)
        XCTAssertEqual(restored.plainText, "hello")

        let catalog = try Data(contentsOf: root.appendingPathComponent("Catalog.pace"))
        XCTAssertNil(String(data: catalog, encoding: .utf8)?.range(of: "hello"))
    }

    func testSameContentFromDifferentCapturePathsDeduplicates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        try await store.unlock(with: SymmetricKey(size: .bits256))

        // Native capture: rich text plus plain text representations.
        var rich = ClipboardItem(
            source: ClipboardSource(kind: .application, name: "Safari"),
            kind: .richText,
            representations: [
                ClipboardRepresentation(typeIdentifier: "public.rtf", data: Data("{\\rtf hello}".utf8)),
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("hello world".utf8))
            ],
            preview: "hello world",
            searchableText: "hello world",
            fingerprint: "",
            byteCount: 23
        )
        rich.fingerprint = rich.contentFingerprint

        // Import path: a single plain-text representation of the same text.
        var plain = ClipboardItem(
            source: ClipboardSource(kind: .application, name: "Alfred"),
            kind: .text,
            representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("hello world".utf8))
            ],
            preview: "hello world",
            searchableText: "hello world",
            fingerprint: "",
            byteCount: 11
        )
        plain.fingerprint = plain.contentFingerprint

        _ = try await store.add(rich)
        _ = try await store.add(plain)

        let records = try await store.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].copyCount, 2)
    }

    func testDatesRoundTripWithSubSecondPrecision() throws {
        let precise = Date(timeIntervalSince1970: 1_752_750_000.123)
        let item = ClipboardItem(
            lastCopiedAt: precise,
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .text,
            representations: [],
            preview: "p",
            searchableText: "p",
            fingerprint: "f",
            byteCount: 1
        )

        let decoded = try JSONDecoder.pace.decode(
            ClipboardItem.self,
            from: JSONEncoder.pace.encode(item)
        )
        XCTAssertEqual(decoded.lastCopiedAt.timeIntervalSince(precise), 0, accuracy: 0.005)

        // Catalogs written before fractional seconds still decode.
        let legacy = Data(#"{"date": "2026-07-17T15:08:33Z"}"#.utf8)
        struct Wrapper: Codable { var date: Date }
        let parsed = try JSONDecoder.pace.decode(Wrapper.self, from: legacy)
        XCTAssertEqual(
            parsed.date,
            ISO8601DateFormatter().date(from: "2026-07-17T15:08:33Z")
        )
    }

    func testOCRTextPreservesReadingLines() {
        let item = ClipboardItem(
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .image,
            representations: [],
            preview: "Image",
            searchableText: "",
            fingerprint: "image",
            byteCount: 10,
            ocrObservations: [
                OCRObservation(text: "First line", confidence: 1, x: 0, y: 1, width: 1, height: 0.1),
                OCRObservation(text: "Second line", confidence: 1, x: 0, y: 0.8, width: 1, height: 0.1)
            ]
        )

        XCTAssertEqual(item.ocrText, "First line\nSecond line")
    }
}
