import CryptoKit
import Foundation
import XCTest
@testable import PaceCore

final class SnippetStoreTests: XCTestCase {
    func testPersistsEncryptedSnippetsAndSearchesKeywords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = SnippetStore(rootURL: root)
        try await store.unlock(with: key)
        let saved = try await store.upsert(
            Snippet(name: "Personal Email", template: "person@example.com", keyword: ";em")
        )
        await store.lock()

        let encrypted = try Data(contentsOf: root.appendingPathComponent("Snippets.pace"))
        XCTAssertFalse(encrypted.range(of: Data("person@example.com".utf8)) != nil)

        let reopened = SnippetStore(rootURL: root)
        try await reopened.unlock(with: key)
        let results = try await reopened.all(query: ";em")
        XCTAssertEqual(results.map(\.id), [saved.id])
        XCTAssertEqual(results.first?.template, "person@example.com")
    }

    func testRejectsDuplicateNamesAndKeywords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(rootURL: root)
        try await store.unlock(with: SymmetricKey(size: .bits256))
        _ = try await store.upsert(Snippet(name: "Email", template: "a", keyword: ";em"))

        do {
            _ = try await store.upsert(Snippet(name: "Other", template: "b", keyword: ";em"))
            XCTFail("Expected a duplicate-keyword error")
        } catch let error as PaceError {
            XCTAssertEqual(error.code, "invalid_argument")
        }

        do {
            _ = try await store.upsert(Snippet(name: "email", template: "b", keyword: ";other"))
            XCTFail("Expected a duplicate-name error")
        } catch let error as PaceError {
            XCTAssertEqual(error.code, "invalid_argument")
        }
    }

    func testRecordUseUpdatesUsageWithoutChangingModifiedDate() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SnippetStore(rootURL: root)
        try await store.unlock(with: SymmetricKey(size: .bits256))
        let modified = Date(timeIntervalSince1970: 100)
        let saved = try await store.upsert(
            Snippet(name: "Email", template: "a", updatedAt: modified),
            now: modified
        )
        let used = try await store.recordUse(id: saved.id, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(used.useCount, 1)
        XCTAssertEqual(used.updatedAt, modified)
        XCTAssertEqual(used.lastUsedAt, Date(timeIntervalSince1970: 200))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceSnippetStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
