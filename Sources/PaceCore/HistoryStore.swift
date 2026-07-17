import CryptoKit
import Foundation

public actor HistoryStore {
    // Version 2: fingerprints are content-based (ClipboardItem
    // .contentFingerprint) so identical content captured through different
    // paths dedupes; older catalogs are migrated and merged on unlock.
    private struct Catalog: Codable {
        var version = 2
        var records: [ClipboardRecord]
    }

    private let rootURL: URL
    private let entriesURL: URL
    private let catalogURL: URL
    private let retentionURL: URL
    private var key: SymmetricKey?
    private var records: [ClipboardRecord] = []
    private var policy: RetentionPolicy

    public init(rootURL: URL = PacePaths.applicationSupportDirectory) {
        self.rootURL = rootURL
        entriesURL = rootURL.appendingPathComponent("Entries", isDirectory: true)
        catalogURL = rootURL.appendingPathComponent("Catalog.pace")
        retentionURL = rootURL.appendingPathComponent("Retention.json")
        policy = (try? Self.readPolicy(at: retentionURL)) ?? .defaults
    }

    public var isUnlocked: Bool { key != nil }

    public func unlock(with key: SymmetricKey) throws {
        try prepareDirectories()
        self.key = key
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let encrypted = try Data(contentsOf: catalogURL)
            let data = try VaultCryptor.decrypt(encrypted, using: key)
            guard let catalog = try? JSONDecoder.pace.decode(Catalog.self, from: data) else {
                self.key = nil
                throw PaceError.corruptStore
            }
            records = catalog.records
            if catalog.version < 2 {
                try migrateToContentFingerprints()
            }
        } else {
            records = []
            try saveCatalog()
        }
    }

    public func lock() {
        key = nil
        records.removeAll(keepingCapacity: false)
    }

    public func allRecords(query: String = "", limit: Int = 100) throws -> [ClipboardRecord] {
        _ = try requireKey()
        return SearchEngine.search(records, query: query, limit: limit)
    }

    public func item(id: UUID) throws -> ClipboardItem {
        let key = try requireKey()
        guard records.contains(where: { $0.id == id }) else {
            throw PaceError.notFound("Clipboard item \(id.uuidString) was not found.")
        }
        let encrypted = try Data(contentsOf: entryURL(id: id))
        let data = try VaultCryptor.decrypt(encrypted, using: key)
        guard let item = try? JSONDecoder.pace.decode(ClipboardItem.self, from: data) else {
            throw PaceError.corruptStore
        }
        return item
    }

    @discardableResult
    public func add(_ incoming: ClipboardItem) throws -> ClipboardRecord {
        _ = try requireKey()
        var item = incoming

        if let existing = records.first(where: { $0.fingerprint == incoming.fingerprint }) {
            var original = try self.item(id: existing.id)
            // Imports can replay older copies of existing content; never let
            // them regress an item's recency or source.
            if incoming.lastCopiedAt >= original.lastCopiedAt {
                original.lastCopiedAt = incoming.lastCopiedAt
                original.source = incoming.source
            }
            original.copyCount += 1
            item = original
            records.removeAll { $0.id == existing.id }
        }

        try write(item)
        let record = ClipboardRecord(item: item)
        records.append(record)
        records.sort { $0.lastCopiedAt > $1.lastCopiedAt }
        try saveCatalog()
        _ = try prune(using: policy, apply: true)
        return record
    }

    public func updateOCR(id: UUID, observations: [OCRObservation]) throws {
        var item = try self.item(id: id)
        item.ocrObservations = observations
        let recognized = observations.map(\.text).joined(separator: "\n")
        if !recognized.isEmpty {
            item.searchableText += "\n" + recognized
            if item.preview == "Image" {
                item.preview = recognized
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefixString(180)
            }
        }
        try write(item)
        replaceRecord(for: item)
        try saveCatalog()
    }

    public func setPinned(id: UUID, pinned: Bool) throws {
        var item = try self.item(id: id)
        item.isPinned = pinned
        try write(item)
        replaceRecord(for: item)
        try saveCatalog()
    }

    public func delete(id: UUID) throws {
        _ = try requireKey()
        guard records.contains(where: { $0.id == id }) else {
            throw PaceError.notFound("Clipboard item \(id.uuidString) was not found.")
        }
        try? FileManager.default.removeItem(at: entryURL(id: id))
        records.removeAll { $0.id == id }
        try saveCatalog()
    }

    public func clear() throws {
        _ = try requireKey()
        for record in records {
            try? FileManager.default.removeItem(at: entryURL(id: record.id))
        }
        records = []
        try saveCatalog()
    }

    public func retentionPolicy() -> RetentionPolicy { policy }

    public func setRetentionPolicy(_ newPolicy: RetentionPolicy, pruneImmediately: Bool) throws -> RetentionReport {
        policy = try newPolicy.validated()
        try Self.writePolicy(policy, at: retentionURL)
        guard key != nil else {
            if pruneImmediately { throw PaceError.vaultLocked }
            return .empty
        }
        return try prune(using: policy, apply: pruneImmediately)
    }

    public func retentionPreview() throws -> RetentionReport {
        try prune(using: policy, apply: false)
    }

    public func pruneNow() throws -> RetentionReport {
        try prune(using: policy, apply: true)
    }

    public func storageSummary() throws -> (items: Int, bytes: Int64) {
        _ = try requireKey()
        return (records.count, records.reduce(Int64(0)) { $0 + $1.byteCount })
    }

    // One-time upgrade: recompute every item's fingerprint with the
    // content-based scheme and merge the duplicates that representation-based
    // fingerprints allowed (same text captured natively vs imported).
    private func migrateToContentFingerprints() throws {
        var items: [ClipboardItem] = []
        for record in records {
            guard var item = try? self.item(id: record.id) else { continue }
            item.fingerprint = item.contentFingerprint
            items.append(item)
        }

        var survivors: [String: ClipboardItem] = [:]
        var duplicateIDs: [UUID] = []
        for item in items.sorted(by: { $0.lastCopiedAt > $1.lastCopiedAt }) {
            if var survivor = survivors[item.fingerprint] {
                survivor.copyCount += item.copyCount
                survivor.isPinned = survivor.isPinned || item.isPinned
                survivor.createdAt = min(survivor.createdAt, item.createdAt)
                survivors[item.fingerprint] = survivor
                duplicateIDs.append(item.id)
            } else {
                survivors[item.fingerprint] = item
            }
        }

        for item in survivors.values { try write(item) }
        for id in duplicateIDs { try? FileManager.default.removeItem(at: entryURL(id: id)) }
        records = survivors.values.map(ClipboardRecord.init)
        records.sort { $0.lastCopiedAt > $1.lastCopiedAt }
        try saveCatalog()
    }

    private func prune(using policy: RetentionPolicy, apply: Bool) throws -> RetentionReport {
        _ = try requireKey()
        let report = RetentionPlanner.report(records: records, policy: policy)
        guard apply, !report.itemIDs.isEmpty else { return report }
        let ids = Set(report.itemIDs)
        for id in report.itemIDs {
            try? FileManager.default.removeItem(at: entryURL(id: id))
        }
        records.removeAll { ids.contains($0.id) }
        try saveCatalog()
        return report
    }

    private func replaceRecord(for item: ClipboardItem) {
        records.removeAll { $0.id == item.id }
        records.append(ClipboardRecord(item: item))
        records.sort { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    private func write(_ item: ClipboardItem) throws {
        let key = try requireKey()
        let data = try JSONEncoder.pace.encode(item)
        let encrypted = try VaultCryptor.encrypt(data, using: key)
        try encrypted.write(to: entryURL(id: item.id), options: .atomic)
        try setPermissions(0o600, on: entryURL(id: item.id))
    }

    private func saveCatalog() throws {
        let key = try requireKey()
        let data = try JSONEncoder.pace.encode(Catalog(records: records))
        let encrypted = try VaultCryptor.encrypt(data, using: key)
        try encrypted.write(to: catalogURL, options: .atomic)
        try setPermissions(0o600, on: catalogURL)
    }

    private func requireKey() throws -> SymmetricKey {
        guard let key else { throw PaceError.vaultLocked }
        return key
    }

    private func entryURL(id: UUID) -> URL {
        entriesURL.appendingPathComponent(id.uuidString).appendingPathExtension("pace")
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: entriesURL, withIntermediateDirectories: true)
        try setPermissions(0o700, on: rootURL)
        try setPermissions(0o700, on: entriesURL)
    }

    private func setPermissions(_ permissions: Int, on url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func readPolicy(at url: URL) throws -> RetentionPolicy {
        try JSONDecoder.pace.decode(RetentionPolicy.self, from: Data(contentsOf: url))
    }

    private static func writePolicy(_ policy: RetentionPolicy, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder.pace.encode(policy).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum PacePaths {
    public static var applicationSupportDirectory: URL {
#if DEBUG
        let relativePath = "Library/Application Support/Pace/Debug"
#else
        let relativePath = "Library/Application Support/Pace"
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    public static var socketURL: URL {
        applicationSupportDirectory.appendingPathComponent("pace.sock")
    }
}

// ISO8601DateFormatter is documented thread-safe.
private let isoFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoWholeSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

extension JSONEncoder {
    static var pace: JSONEncoder {
        let encoder = JSONEncoder()
        // Sub-second precision keeps rapid successive copies ordered; the
        // stock .iso8601 strategy truncates to whole seconds.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractionalSeconds.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var pace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            // Catalogs written before fractional seconds lack the fraction.
            guard let date = isoFractionalSeconds.date(from: value)
                ?? isoWholeSeconds.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ISO 8601 date: \(value)"
                )
            }
            return date
        }
        return decoder
    }
}

public extension String {
    func prefixString(_ length: Int) -> String {
        String(prefix(length))
    }
}
