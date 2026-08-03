import Foundation

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var template: String
    public var keyword: String?
    public var tags: [String]
    public var isPinned: Bool
    public var isExpansionEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var sourceRecordID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        template: String,
        keyword: String? = nil,
        tags: [String] = [],
        isPinned: Bool = false,
        isExpansionEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        sourceRecordID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.keyword = keyword
        self.tags = tags
        self.isPinned = isPinned
        self.isExpansionEnabled = isExpansionEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.sourceRecordID = sourceRecordID
    }
}

public enum SnippetValidation {
    public static func normalized(_ snippet: Snippet, now: Date = Date()) throws -> Snippet {
        var normalized = snippet
        normalized.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.name.isEmpty else {
            throw PaceError.invalidArgument("A snippet name is required.")
        }
        guard !snippet.template.isEmpty else {
            throw PaceError.invalidArgument("Snippet text cannot be empty.")
        }

        if let keyword = snippet.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
           !keyword.isEmpty {
            guard !keyword.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw PaceError.invalidArgument("Snippet keywords cannot contain spaces or line breaks.")
            }
            normalized.keyword = keyword
        } else {
            normalized.keyword = nil
            normalized.isExpansionEnabled = false
        }

        var seenTags = Set<String>()
        normalized.tags = snippet.tags.compactMap { rawTag in
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seenTags.insert(key).inserted else { return nil }
            return tag
        }
        normalized.updatedAt = now
        return normalized
    }
}

public enum SnippetSearchEngine {
    public static func search(
        _ snippets: [Snippet],
        query: String,
        limit: Int = 100
    ) -> [Snippet] {
        let needle = SearchEngine.normalize(query)
        let ranked = snippets.compactMap { snippet -> (Snippet, Int)? in
            guard !needle.isEmpty else { return (snippet, 0) }
            let name = SearchEngine.normalize(snippet.name)
            let keyword = SearchEngine.normalize(snippet.keyword ?? "")
            let tags = SearchEngine.normalize(snippet.tags.joined(separator: " "))
            let template = SearchEngine.normalize(snippet.template)
            let tier: Int
            if keyword == needle { tier = 8 }
            else if name == needle { tier = 7 }
            else if keyword.hasPrefix(needle) { tier = 6 }
            else if name.hasPrefix(needle) { tier = 5 }
            else if name.contains(needle) { tier = 4 }
            else if keyword.contains(needle) { tier = 3 }
            else if tags.contains(needle) { tier = 2 }
            else if template.contains(needle) { tier = 1 }
            else { return nil }
            return (snippet, tier)
        }

        return ranked.sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            return browseOrder(left.0, right.0)
        }
        .prefix(max(0, limit))
        .map(\.0)
    }

    private static func browseOrder(_ left: Snippet, _ right: Snippet) -> Bool {
        if left.isPinned != right.isPinned { return left.isPinned }
        switch (left.lastUsedAt, right.lastUsedAt) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate > rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let comparison = left.name.localizedStandardCompare(right.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return left.createdAt < right.createdAt
        }
    }
}
