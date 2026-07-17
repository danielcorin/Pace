import XCTest
@testable import PaceCore

final class RetentionPolicyTests: XCTestCase {
    func testPlannerHonorsAgeCountStorageAndPinnedProtection() {
        let now = Date()
        var pinned = record(daysAgo: 90, bytes: 900)
        pinned.isPinned = true
        let old = record(daysAgo: 40, bytes: 300)
        let recent = record(daysAgo: 1, bytes: 300)
        let newest = record(daysAgo: 0, bytes: 300)
        let policy = RetentionPolicy(
            maximumAgeDays: 30,
            maximumItemCount: 3,
            maximumStorageBytes: 1_200,
            protectsPinnedItems: true
        )

        let report = RetentionPlanner.report(records: [pinned, old, recent, newest], policy: policy, now: now)

        XCTAssertTrue(report.itemIDs.contains(old.id))
        XCTAssertTrue(report.itemIDs.contains(recent.id))
        XCTAssertFalse(report.itemIDs.contains(pinned.id))
        XCTAssertEqual(report.itemCount, 2)
    }

    private func record(daysAgo: Int, bytes: Int64) -> ClipboardRecord {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return ClipboardRecord(
            item: ClipboardItem(
                createdAt: date,
                lastCopiedAt: date,
                source: ClipboardSource(kind: .application, name: "Tests"),
                kind: .text,
                representations: [],
                preview: "test",
                searchableText: "test",
                fingerprint: UUID().uuidString,
                byteCount: bytes
            )
        )
    }
}
