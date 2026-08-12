import Foundation

public struct SearchQuery: Equatable, Sendable {
    public var text: String
    public var kind: ClipboardContentKind?
    public var source: String?
    public var pinnedOnly: Bool
    public var requiresOCR: Bool

    public init(_ rawValue: String) {
        var terms: [String] = []
        var parsedKind: ClipboardContentKind?
        var parsedSource: String?
        var pinned = false
        var ocr = false

        for component in rawValue.split(whereSeparator: \ .isWhitespace) {
            let token = String(component)
            if token.hasPrefix("type:") {
                switch String(token.dropFirst(5)).lowercased() {
                case "text": parsedKind = .text
                case "rich", "richtext": parsedKind = .richText
                case "url": parsedKind = .url
                case "image": parsedKind = .image
                case "file", "files": parsedKind = .files
                default: terms.append(token)
                }
            } else if token.hasPrefix("app:") {
                parsedSource = String(token.dropFirst(4))
            } else if token == "is:pinned" {
                pinned = true
            } else if token == "has:ocr" {
                ocr = true
            } else {
                terms.append(token)
            }
        }

        text = terms.joined(separator: " ")
        kind = parsedKind
        source = parsedSource
        pinnedOnly = pinned
        requiresOCR = ocr
    }
}

public enum SearchEngine {
    // A week is long enough for repeated clipboard use to matter, while still
    // letting an old favorite fade behind things copied more recently.
    private static let frecencyHalfLife: TimeInterval = 7 * 24 * 60 * 60
    private static let matchTierWeight = 2.75
    // Keep the maximum just below two relevance tiers so frecency can cross
    // one tier, but can never cross two regardless of activity volume.
    private static let maximumFrecencyBonus = 5.4

    public static func search(
        _ records: [ClipboardRecord],
        query: String,
        limit: Int = 100,
        now: Date = Date()
    ) -> [ClipboardRecord] {
        let parsed = SearchQuery(query)
        let needle = normalize(parsed.text)
        let sourceNeedle = parsed.source.map(normalize)

        // Every term must appear as a real substring somewhere in the item
        // (content, preview, OCR text, or source) — subsequence-style fuzzy
        // matching is far too permissive to act as a filter.
        let tiered = records.compactMap { record -> (record: ClipboardRecord, tier: Int)? in
            guard parsed.kind == nil || parsed.kind == record.kind else { return nil }
            guard !parsed.pinnedOnly || record.isPinned else { return nil }
            guard !parsed.requiresOCR || record.hasOCR else { return nil }
            if let sourceNeedle {
                let matchesName = normalize(record.source.name).contains(sourceNeedle)
                let matchesBundle = record.source.bundleIdentifier
                    .map { normalize($0).contains(sourceNeedle) } ?? false
                guard matchesName || matchesBundle else { return nil }
            }

            guard !needle.isEmpty else { return (record, 0) }
            let preview = normalize(record.preview)
            let haystack = normalize(record.searchableText)
            if preview == needle { return (record, 5) }
            if preview.hasPrefix(needle) { return (record, 4) }
            if preview.contains(needle) { return (record, 3) }
            if haystack.contains(needle) { return (record, 2) }
            if needle.split(separator: " ").allSatisfy({ haystack.contains($0) }) {
                return (record, 1)
            }
            return nil
        }

        // Browsing remains pure recency so opening the panel preserves
        // clipboard-history order.
        guard !needle.isEmpty else {
            return tiered
                .sorted { $0.record.lastCopiedAt > $1.record.lastCopiedAt }
                .prefix(max(0, limit))
                .map(\.record)
        }

        // Frecency can bridge one relevance tier, but its cap is lower than
        // the value of two tiers so substantially better matches stay ahead.
        let scored = tiered.map { candidate in
            let frecency = min(
                maximumFrecencyBonus,
                frecencyScore(for: candidate.record, now: now)
            )
            return (
                record: candidate.record,
                tier: candidate.tier,
                frecency: frecency,
                score: Double(candidate.tier) * matchTierWeight + frecency
            )
        }

        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.tier != $1.tier { return $0.tier > $1.tier }
                if $0.frecency != $1.frecency { return $0.frecency > $1.frecency }
                if $0.record.lastCopiedAt != $1.record.lastCopiedAt {
                    return $0.record.lastCopiedAt > $1.record.lastCopiedAt
                }
                if $0.record.copyCount != $1.record.copyCount {
                    return $0.record.copyCount > $1.record.copyCount
                }
                return $0.record.id.uuidString < $1.record.id.uuidString
            }
            .prefix(max(0, limit))
            .map(\.record)
    }

    public static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frecencyScore(for record: ClipboardRecord, now: Date) -> Double {
        let copyScore = activityScore(
            count: record.copyCount,
            date: record.lastCopiedAt,
            now: now
        )
        guard record.useCount > 0, let lastUsedAt = record.lastUsedAt else {
            return copyScore
        }
        // Direct choices are the strongest signal. Let the first few uses add
        // up quickly, then cap them so an item cannot become permanently
        // unbeatable. The whole signal still fades with time.
        let useAge = max(0, now.timeIntervalSince(lastUsedAt))
        let useRecency = pow(0.5, useAge / frecencyHalfLife)
        let useScore = min(4.5, Double(record.useCount)) * useRecency
        return copyScore + useScore
    }

    private static func activityScore(count: Int, date: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(date))
        let recency = pow(0.5, age / frecencyHalfLife)
        // Counts can grow without bound, so damp frequency logarithmically.
        let frequency = 1 + 0.5 * log2(Double(max(1, count)))
        return recency * frequency
    }

}
