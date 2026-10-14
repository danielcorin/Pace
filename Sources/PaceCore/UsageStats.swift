import CryptoKit
import Foundation

/// An action Pace counts toward its usage stats. Only counts are kept — never
/// the content that was pasted or expanded.
public enum UsageEvent: String, Codable, CaseIterable, Sendable {
    /// A clipboard history item pasted into another app (panel or `pace paste`).
    case clipboardPaste
    /// A snippet inserted by typing its keyword.
    case snippetExpansion
}

public struct UsageCounts: Codable, Equatable, Sendable {
    public var clipboardPastes: Int
    public var snippetExpansions: Int

    public static let zero = UsageCounts(clipboardPastes: 0, snippetExpansions: 0)

    public init(clipboardPastes: Int = 0, snippetExpansions: Int = 0) {
        self.clipboardPastes = clipboardPastes
        self.snippetExpansions = snippetExpansions
    }

    public subscript(event: UsageEvent) -> Int {
        get {
            switch event {
            case .clipboardPaste: clipboardPastes
            case .snippetExpansion: snippetExpansions
            }
        }
        set {
            switch event {
            case .clipboardPaste: clipboardPastes = newValue
            case .snippetExpansion: snippetExpansions = newValue
            }
        }
    }

    public static func + (lhs: UsageCounts, rhs: UsageCounts) -> UsageCounts {
        UsageCounts(
            clipboardPastes: lhs.clipboardPastes + rhs.clipboardPastes,
            snippetExpansions: lhs.snippetExpansions + rhs.snippetExpansions
        )
    }
}

public enum UsageGranularity: String, Codable, Sendable {
    case day
    case week
    case month

    public var calendarComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

/// The windows the stats UI and CLI offer. Each ends with the bucket that
/// contains "now", so the current day/week/month is always the last bar.
public enum UsagePeriod: String, Codable, CaseIterable, Sendable {
    case last7Days = "7d"
    case last30Days = "30d"
    case last90Days = "90d"
    case last12Months = "12m"

    public var granularity: UsageGranularity {
        switch self {
        case .last7Days, .last30Days: .day
        case .last90Days: .week
        case .last12Months: .month
        }
    }

    public var bucketCount: Int {
        switch self {
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 13
        case .last12Months: 12
        }
    }

    public var title: String {
        switch self {
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .last12Months: "Last 12 months"
        }
    }
}

public struct UsageBucket: Codable, Equatable, Sendable, Identifiable {
    /// The local calendar day (`yyyy-MM-dd`) the bucket starts on.
    public var date: String
    public var clipboardPastes: Int
    public var snippetExpansions: Int

    public var id: String { date }
    public var counts: UsageCounts {
        UsageCounts(clipboardPastes: clipboardPastes, snippetExpansions: snippetExpansions)
    }

    public init(date: String, counts: UsageCounts) {
        self.date = date
        clipboardPastes = counts.clipboardPastes
        snippetExpansions = counts.snippetExpansions
    }
}

public struct UsageReport: Codable, Equatable, Sendable {
    public var period: UsagePeriod
    public var granularity: UsageGranularity
    /// Oldest first; the last bucket contains today.
    public var buckets: [UsageBucket]
    public var total: UsageCounts
    public var allTime: UsageCounts
    /// The first day anything was recorded, or nil before the first event.
    public var trackingSince: String?

    /// Groups per-day counts into the period's buckets.
    public static func make(
        days: [String: UsageCounts],
        period: UsagePeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageReport {
        let component = period.granularity.calendarComponent
        let current = calendar.dateInterval(of: component, for: now)?.start ?? calendar.startOfDay(for: now)
        let starts = (0..<period.bucketCount).reversed().compactMap {
            calendar.date(byAdding: component, value: -$0, to: current)
        }
        var bucketCounts = Dictionary(
            uniqueKeysWithValues: starts.map { (UsageDayKey.key(for: $0, calendar: calendar), UsageCounts.zero) }
        )
        var total = UsageCounts.zero
        var allTime = UsageCounts.zero
        for (key, counts) in days {
            allTime = allTime + counts
            guard let day = UsageDayKey.date(from: key, calendar: calendar),
                  let start = calendar.dateInterval(of: component, for: day)?.start else { continue }
            let bucketKey = UsageDayKey.key(for: start, calendar: calendar)
            guard let existing = bucketCounts[bucketKey] else { continue }
            bucketCounts[bucketKey] = existing + counts
            total = total + counts
        }
        return UsageReport(
            period: period,
            granularity: period.granularity,
            buckets: starts.map { start in
                let key = UsageDayKey.key(for: start, calendar: calendar)
                return UsageBucket(date: key, counts: bucketCounts[key] ?? .zero)
            },
            total: total,
            allTime: allTime,
            trackingSince: days.keys.min()
        )
    }
}

/// Usage is bucketed by local calendar day, keyed as `yyyy-MM-dd`.
public enum UsageDayKey {
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// Daily usage counters, encrypted with the vault key like the rest of the
/// store. Counters are independent of clipboard retention: clearing or
/// pruning history leaves the stats intact.
public actor UsageStatsStore {
    private struct Catalog: Codable {
        var version = 1
        var days: [String: UsageCounts]
    }

    private let catalogURL: URL
    private var key: SymmetricKey?
    private var days: [String: UsageCounts] = [:]

    public init(rootURL: URL = PacePaths.applicationSupportDirectory) {
        catalogURL = rootURL.appendingPathComponent("Usage.pace")
    }

    public func unlock(with key: SymmetricKey) throws {
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            let encrypted = try Data(contentsOf: catalogURL)
            let plaintext = try VaultCryptor.decrypt(encrypted, using: key)
            guard let catalog = try? JSONDecoder.pace.decode(Catalog.self, from: plaintext) else {
                throw PaceError.corruptStore
            }
            days = catalog.days
        } else {
            days = [:]
        }
        self.key = key
    }

    public func lock() {
        key = nil
        days.removeAll(keepingCapacity: false)
    }

    public func record(_ event: UsageEvent, at date: Date = Date(), calendar: Calendar = .current) throws {
        _ = try requireKey()
        let day = UsageDayKey.key(for: date, calendar: calendar)
        days[day, default: .zero][event] += 1
        try save()
    }

    public func report(
        period: UsagePeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> UsageReport {
        _ = try requireKey()
        return UsageReport.make(days: days, period: period, now: now, calendar: calendar)
    }

    private func save() throws {
        let key = try requireKey()
        let plaintext = try JSONEncoder.pace.encode(Catalog(days: days))
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
