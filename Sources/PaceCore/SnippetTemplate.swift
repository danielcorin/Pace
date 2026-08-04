import Foundation

public struct SnippetRenderingContext: Sendable {
    public var now: Date
    public var localeIdentifier: String
    public var timeZoneIdentifier: String
    public var clipboardItems: [String]
    public var snippetTemplates: [String: String]

    public init(
        now: Date = Date(),
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        clipboardItems: [String] = [],
        snippetTemplates: [String: String] = [:]
    ) {
        self.now = now
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
        self.clipboardItems = clipboardItems
        self.snippetTemplates = snippetTemplates
    }
}

public struct RenderedSnippet: Codable, Equatable, Sendable {
    public var text: String
    /// A grapheme-cluster offset from the beginning of `text`.
    public var cursorOffset: Int?

    public init(text: String, cursorOffset: Int? = nil) {
        self.text = text
        self.cursorOffset = cursorOffset
    }

    public var cursorMovementFromEnd: Int {
        guard let cursorOffset else { return 0 }
        return max(0, text.count - cursorOffset)
    }
}

public enum SnippetTemplateRenderer {
    private static let knownPlaceholders: Set<String> = [
        "clipboard", "cursor", "date", "datetime", "day", "snippet", "time", "uuid"
    ]

    public static func render(
        _ template: String,
        context: SnippetRenderingContext = SnippetRenderingContext()
    ) throws -> RenderedSnippet {
        try render(template, context: context, visitedSnippetNames: [])
    }

    private static func render(
        _ template: String,
        context: SnippetRenderingContext,
        visitedSnippetNames: Set<String>
    ) throws -> RenderedSnippet {
        let escapedOpenBrace = "\u{F0000}"
        let escapedCloseBrace = "\u{F0001}"
        let source = template
            .replacingOccurrences(of: "{{", with: escapedOpenBrace)
            .replacingOccurrences(of: "}}", with: escapedCloseBrace)
        var output = ""
        var cursorOffset: Int?
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "{",
                  let close = source[index...].firstIndex(of: "}") else {
                output.append(source[index])
                index = source.index(after: index)
                continue
            }

            let rawBody = String(source[source.index(after: index)..<close])
            let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let placeholderName = firstIdentifier(in: body)
            guard knownPlaceholders.contains(placeholderName) else {
                output.append(contentsOf: source[index...close])
                index = source.index(after: close)
                continue
            }

            let expression = try parseExpression(body)
            if expression.name == "cursor" {
                guard cursorOffset == nil else {
                    throw PaceError.invalidArgument("A snippet can contain only one {cursor} placeholder.")
                }
                guard expression.attributes.isEmpty, expression.modifiers.isEmpty else {
                    throw PaceError.invalidArgument("The {cursor} placeholder does not accept options.")
                }
                cursorOffset = output.count
            } else if expression.name == "snippet" {
                guard let name = expression.attributes["name"], !name.isEmpty else {
                    throw PaceError.invalidArgument("A nested snippet needs a name, for example {snippet name=\"Email\"}.")
                }
                let identity = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard !visitedSnippetNames.contains(identity) else {
                    throw PaceError.invalidArgument("Nested snippets cannot contain a reference cycle.")
                }
                guard let nestedTemplate = context.snippetTemplates.first(where: {
                    $0.key.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                })?.value else {
                    throw PaceError.notFound("The nested snippet “\(name)” was not found.")
                }
                let nested = try render(
                    nestedTemplate,
                    context: context,
                    visitedSnippetNames: visitedSnippetNames.union([identity])
                )
                guard cursorOffset == nil || nested.cursorOffset == nil else {
                    throw PaceError.invalidArgument("A rendered snippet can contain only one cursor position.")
                }
                if let nestedCursor = nested.cursorOffset {
                    guard expression.modifiers.isEmpty else {
                        throw PaceError.invalidArgument(
                            "A nested snippet containing {cursor} cannot use text modifiers."
                        )
                    }
                    cursorOffset = output.count + nestedCursor
                }
                output += try apply(expression.modifiers, to: nested.text)
            } else {
                let value = try resolvedValue(for: expression, context: context)
                output += try apply(expression.modifiers, to: value)
            }
            index = source.index(after: close)
        }
        return RenderedSnippet(
            text: output
                .replacingOccurrences(of: escapedOpenBrace, with: "{")
                .replacingOccurrences(of: escapedCloseBrace, with: "}"),
            cursorOffset: cursorOffset
        )
    }

    private struct Expression {
        var name: String
        var attributes: [String: String]
        var modifiers: [String]
    }

    private static func parseExpression(_ body: String) throws -> Expression {
        let parts = splitPipes(body)
        guard let head = parts.first else {
            throw PaceError.invalidArgument("An empty snippet placeholder is not valid.")
        }
        let name = firstIdentifier(in: head)
        var cursor = head.index(head.startIndex, offsetBy: name.count)
        var attributes: [String: String] = [:]
        while cursor < head.endIndex {
            skipWhitespace(in: head, cursor: &cursor)
            guard cursor < head.endIndex else { break }
            let key = readIdentifier(in: head, cursor: &cursor)
            guard !key.isEmpty else {
                throw PaceError.invalidArgument("Could not parse options in {\(body)}.")
            }
            skipWhitespace(in: head, cursor: &cursor)
            guard cursor < head.endIndex, head[cursor] == "=" else {
                throw PaceError.invalidArgument("Expected = after \(key) in {\(body)}.")
            }
            cursor = head.index(after: cursor)
            skipWhitespace(in: head, cursor: &cursor)
            attributes[key] = try readValue(in: head, cursor: &cursor, body: body)
        }
        let modifiers = parts.dropFirst().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        return Expression(name: name, attributes: attributes, modifiers: modifiers)
    }

    private static func resolvedValue(
        for expression: Expression,
        context: SnippetRenderingContext
    ) throws -> String {
        switch expression.name {
        case "clipboard":
            let offset: Int
            if let rawOffset = expression.attributes["offset"] {
                guard let parsed = Int(rawOffset), parsed >= 0 else {
                    throw PaceError.invalidArgument("Clipboard offsets must be zero or greater.")
                }
                offset = parsed
            } else {
                offset = 0
            }
            guard context.clipboardItems.indices.contains(offset) else {
                throw PaceError.notFound("Clipboard text at offset \(offset) is not available.")
            }
            return context.clipboardItems[offset]
        case "date", "time", "datetime", "day":
            let date = try adjustedDate(
                context.now,
                offset: expression.attributes["offset"],
                context: context
            )
            return formattedDate(date, expression: expression, context: context)
        case "uuid":
            return UUID().uuidString
        default:
            throw PaceError.invalidArgument("Unknown snippet placeholder {\(expression.name)}.")
        }
    }

    private static func adjustedDate(
        _ date: Date,
        offset: String?,
        context: SnippetRenderingContext
    ) throws -> Date {
        guard let offset, !offset.isEmpty else { return date }
        var adjusted = date
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: context.localeIdentifier)
        calendar.timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? .current
        for component in offset.split(whereSeparator: \ .isWhitespace) {
            let token = String(component)
            guard token.count >= 3,
                  token.first == "+" || token.first == "-",
                  let unit = token.last,
                  let magnitude = Int(token.dropFirst().dropLast()) else {
                throw PaceError.invalidArgument("Invalid date offset “\(token)”.")
            }
            let value = token.first == "-" ? -magnitude : magnitude
            let calendarComponent: Calendar.Component
            switch unit {
            case "s": calendarComponent = .second
            case "m": calendarComponent = .minute
            case "h": calendarComponent = .hour
            case "d": calendarComponent = .day
            case "M": calendarComponent = .month
            case "y": calendarComponent = .year
            default: throw PaceError.invalidArgument("Unknown date-offset unit “\(unit)”.")
            }
            guard let result = calendar.date(byAdding: calendarComponent, value: value, to: adjusted) else {
                throw PaceError.invalidArgument("The date offset could not be calculated.")
            }
            adjusted = result
        }
        return adjusted
    }

    private static func formattedDate(
        _ date: Date,
        expression: Expression,
        context: SnippetRenderingContext
    ) -> String {
        let timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? .current
        if let format = expression.attributes["format"]?.lowercased(),
           format == "iso8601" || format == "iso-8601" {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = timeZone
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(
            identifier: expression.attributes["locale"] ?? context.localeIdentifier
        )
        formatter.timeZone = timeZone
        if let format = expression.attributes["format"], !format.isEmpty {
            formatter.dateFormat = format
        } else {
            switch expression.name {
            case "date": formatter.dateStyle = .medium
            case "time": formatter.timeStyle = .short
            case "datetime":
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
            case "day": formatter.dateFormat = "EEEE"
            default: break
            }
        }
        return formatter.string(from: date)
    }

    private static func apply(_ modifiers: [String], to initialValue: String) throws -> String {
        try modifiers.reduce(initialValue) { value, modifier in
            switch modifier {
            case "raw": return value
            case "trim": return value.trimmingCharacters(in: .whitespacesAndNewlines)
            case "uppercase": return value.uppercased()
            case "lowercase": return value.lowercased()
            case "titlecase", "capitalcase": return value.capitalized
            case "single-line", "singleline":
                return value
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode", "percentencode":
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            case "json-stringify", "jsonstringify":
                let data = try JSONEncoder().encode(value)
                return String(decoding: data, as: UTF8.self)
            default:
                throw PaceError.invalidArgument("Unknown snippet modifier “\(modifier)”.")
            }
        }
    }

    private static func firstIdentifier(in value: String) -> String {
        var cursor = value.startIndex
        skipWhitespace(in: value, cursor: &cursor)
        return readIdentifier(in: value, cursor: &cursor)
    }

    private static func readIdentifier(in value: String, cursor: inout String.Index) -> String {
        let start = cursor
        while cursor < value.endIndex {
            let character = value[cursor]
            guard character.isLetter || character.isNumber || character == "-" || character == "_" else {
                break
            }
            cursor = value.index(after: cursor)
        }
        return String(value[start..<cursor]).lowercased()
    }

    private static func skipWhitespace(in value: String, cursor: inout String.Index) {
        while cursor < value.endIndex, value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
    }

    private static func readValue(
        in value: String,
        cursor: inout String.Index,
        body: String
    ) throws -> String {
        guard cursor < value.endIndex else {
            throw PaceError.invalidArgument("A value is missing in {\(body)}.")
        }
        if value[cursor] == "\"" {
            cursor = value.index(after: cursor)
            var result = ""
            var escaped = false
            while cursor < value.endIndex {
                let character = value[cursor]
                cursor = value.index(after: cursor)
                if escaped {
                    result.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return result
                } else {
                    result.append(character)
                }
            }
            throw PaceError.invalidArgument("A quoted value is not closed in {\(body)}.")
        }
        let start = cursor
        while cursor < value.endIndex, !value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
        return String(value[start..<cursor])
    }

    private static func splitPipes(_ value: String) -> [String] {
        var parts: [String] = []
        var start = value.startIndex
        var cursor = value.startIndex
        var quoted = false
        var escaped = false
        while cursor < value.endIndex {
            let character = value[cursor]
            if escaped {
                escaped = false
            } else if character == "\\", quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "|", !quoted {
                parts.append(String(value[start..<cursor]))
                start = value.index(after: cursor)
            }
            cursor = value.index(after: cursor)
        }
        parts.append(String(value[start..<value.endIndex]))
        return parts
    }
}
