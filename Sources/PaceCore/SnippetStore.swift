import CryptoKit
import Foundation

public actor SnippetStore {
    private struct Catalog: Codable {
        var version = 1
        var snippets: [Snippet]
    }

    private let catalogURL: URL
    private var key: SymmetricKey?
    private var snippets: [Snippet] = []

    public init(rootURL: URL = PacePaths.applicationSupportDirectory) {
        catalogURL = rootURL.appendingPathComponent("Snippets.pace")
    }

    public var isUnlocked: Bool { key != nil }

    public func unlock(with key: SymmetricKey) throws {
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.key = key
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let encrypted = try Data(contentsOf: catalogURL)
            let plaintext = try VaultCryptor.decrypt(encrypted, using: key)
            guard let catalog = try? JSONDecoder.pace.decode(Catalog.self, from: plaintext) else {
                self.key = nil
                throw PaceError.corruptStore
            }
            snippets = catalog.snippets
        } else {
            snippets = []
            try save()
        }
    }

    public func lock() {
        key = nil
        snippets.removeAll(keepingCapacity: false)
    }

    public func all(query: String = "", limit: Int = 250) throws -> [Snippet] {
        _ = try requireKey()
        return SnippetSearchEngine.search(snippets, query: query, limit: limit)
    }

    public func snippet(id: UUID) throws -> Snippet {
        _ = try requireKey()
        guard let snippet = snippets.first(where: { $0.id == id }) else {
            throw PaceError.notFound("Snippet \(id.uuidString) was not found.")
        }
        return snippet
    }

    @discardableResult
    public func upsert(_ incoming: Snippet, now: Date = Date()) throws -> Snippet {
        _ = try requireKey()
        var snippet = try SnippetValidation.normalized(incoming, now: now)
        if let existing = snippets.first(where: { $0.id == snippet.id }) {
            snippet.createdAt = existing.createdAt
            snippet.lastUsedAt = existing.lastUsedAt
            snippet.useCount = existing.useCount
        } else {
            snippet.createdAt = min(snippet.createdAt, now)
        }
        try validateUniqueness(of: snippet)
        snippets.removeAll { $0.id == snippet.id }
        snippets.append(snippet)
        try save()
        return snippet
    }

    public func delete(id: UUID) throws {
        _ = try requireKey()
        guard snippets.contains(where: { $0.id == id }) else {
            throw PaceError.notFound("Snippet \(id.uuidString) was not found.")
        }
        snippets.removeAll { $0.id == id }
        try save()
    }

    @discardableResult
    public func recordUse(id: UUID, at date: Date = Date()) throws -> Snippet {
        _ = try requireKey()
        guard let index = snippets.firstIndex(where: { $0.id == id }) else {
            throw PaceError.notFound("Snippet \(id.uuidString) was not found.")
        }
        snippets[index].lastUsedAt = date
        snippets[index].useCount += 1
        try save()
        return snippets[index]
    }

    public func expansionSnippets() throws -> [Snippet] {
        _ = try requireKey()
        return snippets.filter { $0.isExpansionEnabled && $0.keyword != nil }
    }

    private func validateUniqueness(of snippet: Snippet) throws {
        if snippets.contains(where: {
            $0.id != snippet.id
                && $0.name.compare(snippet.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            throw PaceError.invalidArgument("A snippet named “\(snippet.name)” already exists.")
        }
        if let keyword = snippet.keyword,
           snippets.contains(where: { $0.id != snippet.id && $0.keyword == keyword }) {
            throw PaceError.invalidArgument("The keyword “\(keyword)” is already used by another snippet.")
        }
    }

    private func save() throws {
        let key = try requireKey()
        let plaintext = try JSONEncoder.pace.encode(Catalog(snippets: snippets))
        let encrypted = try VaultCryptor.encrypt(plaintext, using: key)
        try encrypted.write(to: catalogURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: catalogURL.path
        )
    }

    private func requireKey() throws -> SymmetricKey {
        guard let key else { throw PaceError.vaultLocked }
        return key
    }
}
