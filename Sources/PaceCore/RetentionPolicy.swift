import Foundation

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public static let defaults = RetentionPolicy(
        maximumAgeDays: 30,
        maximumItemCount: 10_000,
        maximumStorageBytes: 1_000_000_000,
        protectsPinnedItems: true
    )

    public var maximumAgeDays: Int?
    public var maximumItemCount: Int?
    public var maximumStorageBytes: Int64?
    public var protectsPinnedItems: Bool

    public init(
        maximumAgeDays: Int?,
        maximumItemCount: Int?,
        maximumStorageBytes: Int64?,
        protectsPinnedItems: Bool
    ) {
        self.maximumAgeDays = maximumAgeDays
        self.maximumItemCount = maximumItemCount
        self.maximumStorageBytes = maximumStorageBytes
        self.protectsPinnedItems = protectsPinnedItems
    }

    public func validated() throws -> RetentionPolicy {
        if let maximumAgeDays, maximumAgeDays < 1 {
            throw PaceError.invalidArgument("Retention days must be at least 1 or unlimited.")
        }
        if let maximumItemCount, maximumItemCount < 1 {
            throw PaceError.invalidArgument("Maximum item count must be at least 1 or unlimited.")
        }
        if let maximumStorageBytes, maximumStorageBytes < 1 {
            throw PaceError.invalidArgument("Maximum storage must be positive or unlimited.")
        }
        return self
    }
}

public struct RetentionReport: Codable, Equatable, Sendable {
    public var itemCount: Int
    public var byteCount: Int64
    public var itemIDs: [UUID]

    public init(itemCount: Int, byteCount: Int64, itemIDs: [UUID]) {
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.itemIDs = itemIDs
    }

    public static let empty = RetentionReport(itemCount: 0, byteCount: 0, itemIDs: [])
}

public enum RetentionPlanner {
    public static func report(
        records: [ClipboardRecord],
        policy: RetentionPolicy,
        now: Date = Date()
    ) -> RetentionReport {
        let oldestFirst = records.sorted { $0.lastCopiedAt < $1.lastCopiedAt }
        var removed = Set<UUID>()

        func protected(_ record: ClipboardRecord) -> Bool {
            policy.protectsPinnedItems && record.isPinned
        }

        if let days = policy.maximumAgeDays,
           let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) {
            for record in oldestFirst where record.lastCopiedAt < cutoff && !protected(record) {
                removed.insert(record.id)
            }
        }

        if let limit = policy.maximumItemCount {
            var retainedCount = records.count - removed.count
            for record in oldestFirst where retainedCount > limit {
                guard !removed.contains(record.id), !protected(record) else { continue }
                removed.insert(record.id)
                retainedCount -= 1
            }
        }

        if let limit = policy.maximumStorageBytes {
            var retainedBytes = records
                .filter { !removed.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.byteCount }
            for record in oldestFirst where retainedBytes > limit {
                guard !removed.contains(record.id), !protected(record) else { continue }
                removed.insert(record.id)
                retainedBytes -= record.byteCount
            }
        }

        let selected = oldestFirst.filter { removed.contains($0.id) }
        return RetentionReport(
            itemCount: selected.count,
            byteCount: selected.reduce(Int64(0)) { $0 + $1.byteCount },
            itemIDs: selected.map(\.id)
        )
    }
}
