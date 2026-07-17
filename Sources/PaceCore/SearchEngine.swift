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
    public static func search(
        _ records: [ClipboardRecord],
        query: String,
        limit: Int = 100,
        now: Date = Date()
    ) -> [ClipboardRecord] {
        let parsed = SearchQuery(query)
        let needle = normalize(parsed.text)
        let sourceNeedle = parsed.source.map(normalize)

        // Rank by match quality, newest first within a tier. Every term must
        // appear as a real substring somewhere in the item (content, preview,
        // OCR text, or source) — subsequence-style fuzzy matching is far too
        // permissive to act as a filter. Browsing (no text) is pure recency.
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

        return tiered
            .sorted {
                if $0.tier == $1.tier { return $0.record.lastCopiedAt > $1.record.lastCopiedAt }
                return $0.tier > $1.tier
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

}
