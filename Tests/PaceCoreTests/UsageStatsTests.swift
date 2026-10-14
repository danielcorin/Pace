import CryptoKit
import Foundation
import XCTest
@testable import PaceCore

final class UsageStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        return calendar
    }()

    func testRecordsPersistEncryptedAcrossUnlocks() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let now = date("2026-10-13T15:00:00-04:00")

        let store = UsageStatsStore(rootURL: root)
        try await store.unlock(with: key)
        try await store.record(.clipboardPaste, at: now, calendar: calendar)
        try await store.record(.clipboardPaste, at: now, calendar: calendar)
        try await store.record(.snippetExpansion, at: now, calendar: calendar)
        await store.lock()

        let encrypted = try Data(contentsOf: root.appendingPathComponent("Usage.pace"))
        XCTAssertNil(encrypted.range(of: Data("clipboardPastes".utf8)))

        let reopened = UsageStatsStore(rootURL: root)
        try await reopened.unlock(with: key)
        let report = try await reopened.report(period: .last7Days, now: now, calendar: calendar)
        XCTAssertEqual(report.total, UsageCounts(clipboardPastes: 2, snippetExpansions: 1))
        XCTAssertEqual(report.buckets.last?.date, "2026-10-13")
        XCTAssertEqual(report.trackingSince, "2026-10-13")
    }

    func testLockedStoreRejectsRecording() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStatsStore(rootURL: root)
        do {
            try await store.record(.clipboardPaste)
            XCTFail("Expected a locked-vault error")
        } catch PaceError.vaultLocked {}
    }

    func testDailyReportZeroFillsAndExcludesOlderDays() {
        let days = [
            "2026-10-13": UsageCounts(clipboardPastes: 4),
            "2026-10-10": UsageCounts(clipboardPastes: 1, snippetExpansions: 2),
            "2026-10-06": UsageCounts(clipboardPastes: 9)
        ]
        let report = UsageReport.make(
            days: days,
            period: .last7Days,
            now: date("2026-10-13T23:30:00-04:00"),
            calendar: calendar
        )
        XCTAssertEqual(report.granularity, .day)
        XCTAssertEqual(report.buckets.map(\.date), [
            "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10",
            "2026-10-11", "2026-10-12", "2026-10-13"
        ])
        XCTAssertEqual(report.buckets.map(\.clipboardPastes), [0, 0, 0, 1, 0, 0, 4])
        XCTAssertEqual(report.total, UsageCounts(clipboardPastes: 5, snippetExpansions: 2))
        XCTAssertEqual(report.allTime, UsageCounts(clipboardPastes: 14, snippetExpansions: 2))
        XCTAssertEqual(report.trackingSince, "2026-10-06")
    }

    func testDaysAreKeyedInLocalTime() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStatsStore(rootURL: root)
        try await store.unlock(with: SymmetricKey(size: .bits256))
        // 01:30 UTC on Oct 14 is still Oct 13 in New York.
        let lateEvening = date("2026-10-14T01:30:00Z")
        try await store.record(.snippetExpansion, at: lateEvening, calendar: calendar)
        let report = try await store.report(period: .last7Days, now: lateEvening, calendar: calendar)
        XCTAssertEqual(report.buckets.last?.date, "2026-10-13")
        XCTAssertEqual(report.buckets.last?.snippetExpansions, 1)
    }

    func testWeeklyAndMonthlyBucketsAlignToCalendar() {
        let days = [
            "2026-10-13": UsageCounts(clipboardPastes: 1),
            "2026-10-11": UsageCounts(clipboardPastes: 2),
            "2026-10-10": UsageCounts(clipboardPastes: 4),
            "2025-11-30": UsageCounts(snippetExpansions: 3),
            "2025-10-31": UsageCounts(snippetExpansions: 8)
        ]
        let now = date("2026-10-13T12:00:00-04:00")

        let weekly = UsageReport.make(days: days, period: .last90Days, now: now, calendar: calendar)
        XCTAssertEqual(weekly.buckets.count, 13)
        // Weeks start on Sunday Oct 11, so Saturday Oct 10 is the prior week.
        XCTAssertEqual(weekly.buckets.last?.date, "2026-10-11")
        XCTAssertEqual(weekly.buckets.last?.clipboardPastes, 3)
        XCTAssertEqual(weekly.buckets.dropLast().last?.clipboardPastes, 4)

        let monthly = UsageReport.make(days: days, period: .last12Months, now: now, calendar: calendar)
        XCTAssertEqual(monthly.buckets.map(\.date).first, "2025-11-01")
        XCTAssertEqual(monthly.buckets.map(\.date).last, "2026-10-01")
        XCTAssertEqual(monthly.buckets.first?.snippetExpansions, 3)
        XCTAssertEqual(monthly.total, UsageCounts(clipboardPastes: 7, snippetExpansions: 3))
        XCTAssertEqual(monthly.allTime.snippetExpansions, 11)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PaceUsageStatsTests-\(UUID().uuidString)", isDirectory: true)
    }
}
