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

    func testRecordUsePersistsWithoutChangingCopyMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(rootURL: root)
        try await store.unlock(with: key)
        let copiedAt = Date()
        let usedAt = copiedAt.addingTimeInterval(100)
        let added = try await store.add(
            ClipboardItem(
                createdAt: copiedAt,
                lastCopiedAt: copiedAt,
                source: ClipboardSource(kind: .application, name: "Tests"),
                kind: .text,
                representations: [],
                preview: "hello",
                searchableText: "hello",
                fingerprint: "used",
                byteCount: 5
            )
        )

        let used = try await store.recordUse(id: added.id, at: usedAt)
        XCTAssertEqual(used.useCount, 1)
        XCTAssertEqual(used.lastUsedAt, usedAt)
        XCTAssertEqual(used.copyCount, 1)
        XCTAssertEqual(used.lastCopiedAt.timeIntervalSince(copiedAt), 0, accuracy: 0.005)
        await store.lock()

        let reopened = HistoryStore(rootURL: root)
        try await reopened.unlock(with: key)
        let persisted = try await reopened.item(id: added.id)
        XCTAssertEqual(persisted.useCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(persisted.lastUsedAt).timeIntervalSince(usedAt),
            0,
            accuracy: 0.005
        )
        XCTAssertEqual(persisted.copyCount, 1)
        XCTAssertEqual(persisted.lastCopiedAt.timeIntervalSince(copiedAt), 0, accuracy: 0.005)
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

    func testClipboardUsageDefaultsWhenDecodingLegacyData() throws {
        let item = ClipboardItem(
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .text,
            representations: [],
            preview: "legacy",
            searchableText: "legacy",
            fingerprint: "legacy",
            byteCount: 6
        )
        var itemJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.pace.encode(item)) as? [String: Any]
        )
        itemJSON.removeValue(forKey: "lastUsedAt")
        itemJSON.removeValue(forKey: "useCount")
        let decodedItem = try JSONDecoder.pace.decode(
            ClipboardItem.self,
            from: JSONSerialization.data(withJSONObject: itemJSON)
        )
        XCTAssertEqual(decodedItem.useCount, 0)
        XCTAssertNil(decodedItem.lastUsedAt)

        var recordJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder.pace.encode(ClipboardRecord(item: item))
            ) as? [String: Any]
        )
        recordJSON.removeValue(forKey: "lastUsedAt")
        recordJSON.removeValue(forKey: "useCount")
        let decodedRecord = try JSONDecoder.pace.decode(
            ClipboardRecord.self,
            from: JSONSerialization.data(withJSONObject: recordJSON)
        )
        XCTAssertEqual(decodedRecord.useCount, 0)
        XCTAssertNil(decodedRecord.lastUsedAt)
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

    func testTextHistoryUsesNewestTextAndOCRWhileSkippingOpaqueItems() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        try await store.unlock(with: SymmetricKey(size: .bits256))
        let now = Date()

        _ = try await store.add(ClipboardItem(
            lastCopiedAt: now.addingTimeInterval(-200),
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .text,
            representations: [
                ClipboardRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    data: Data("older text".utf8)
                )
            ],
            preview: "older text",
            searchableText: "older text",
            fingerprint: "text",
            byteCount: 10
        ))
        _ = try await store.add(ClipboardItem(
            lastCopiedAt: now.addingTimeInterval(-100),
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .files,
            representations: [],
            preview: "opaque file",
            searchableText: "opaque file",
            fingerprint: "file",
            byteCount: 1
        ))
        _ = try await store.add(ClipboardItem(
            lastCopiedAt: now,
            source: ClipboardSource(kind: .application, name: "Tests"),
            kind: .image,
            representations: [],
            preview: "Image",
            searchableText: "recognized text",
            fingerprint: "image-with-ocr",
            byteCount: 1,
            ocrObservations: [
                OCRObservation(text: "recognized text", confidence: 1, x: 0, y: 0, width: 1, height: 1)
            ]
        ))

        let allText = try await store.textHistory()
        let newestText = try await store.textHistory(limit: 1)
        XCTAssertEqual(allText, ["recognized text", "older text"])
        XCTAssertEqual(newestText, ["recognized text"])
    }
}
