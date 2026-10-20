import Foundation
import UniformTypeIdentifiers

/// The broad kinds of input an action can ask for. They are derived from the
/// pasteboard (or a history item), so one input often has several: a copied
/// web image can be both `image` and `url`.
public enum ActionInputKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case url
    case files

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .url: return "Link"
        case .files: return "Files"
        }
    }

    /// The noun used in "Needs …" hints.
    var article: String {
        switch self {
        case .text: return "text"
        case .image: return "an image"
        case .url: return "a link"
        case .files: return "files"
        }
    }
}

/// One entry of an action's `@pace.accepts` header.
public enum ActionRequirement: Hashable, Codable, Sendable {
    case any
    case kind(ActionInputKind)
    /// A Uniform Type Identifier such as `public.movie`; matches pasteboard
    /// types and copied files that conform to it.
    case type(String)

    public init?(token: String) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "any", "*": self = .any
        case "text", "string": self = .kind(.text)
        case "image", "images": self = .kind(.image)
        case "url", "link", "links": self = .kind(.url)
        case "file", "files": self = .kind(.files)
        default:
            guard value.contains("."), !value.contains(where: \.isWhitespace) else { return nil }
            self = .type(value)
        }
    }

    public var displayName: String {
        switch self {
        case .any: return "Anything"
        case .kind(let kind): return kind.displayName
        case .type(let identifier):
            return UTType(identifier)?.localizedDescription?.capitalizedFirstLetter ?? identifier
        }
    }

    var article: String {
        switch self {
        case .any: return "anything"
        case .kind(let kind): return kind.article
        case .type(let identifier):
            let name = UTType(identifier)?.localizedDescription ?? identifier
            return "a \(name.lowercased())"
        }
    }

    /// The token as written in a header, for listings and JSON.
    public var token: String {
        switch self {
        case .any: return "any"
        case .kind(let kind): return kind.rawValue
        case .type(let identifier): return identifier
        }
    }
}

/// What Pace does with a finished run's standard output.
public enum ActionOutputMode: String, Codable, CaseIterable, Sendable {
    /// Show the result in the Actions panel (the default).
    case panel
    /// Paste standard output into the app that was frontmost.
    case paste
    /// Copy standard output to the clipboard.
    case copy
    /// Show only a brief notice with the first line of output.
    case silent
}

/// An executable in the actions folder, described by `@pace.*` comment lines
/// near the top of the file.
public struct PaceAction: Identifiable, Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 120
    public static let defaultIcon = "terminal"

    /// The file name, which is unique within the folder.
    public var id: String { fileURL.lastPathComponent }
    public var fileURL: URL
    public var title: String
    public var summary: String?
    public var icon: String
    /// Empty means the action takes anything (or nothing).
    public var accepts: [ActionRequirement]
    /// The placeholder for the instructions field; nil hides the field.
    public var argument: String?
    public var output: ActionOutputMode
    public var timeout: TimeInterval
    /// Problems that keep the action from running, such as a missing
    /// executable bit or a misspelled header key.
    public var issues: [String]

    public init(
        fileURL: URL,
        title: String,
        summary: String? = nil,
        icon: String = PaceAction.defaultIcon,
        accepts: [ActionRequirement] = [],
        argument: String? = nil,
        output: ActionOutputMode = .panel,
        timeout: TimeInterval = PaceAction.defaultTimeout,
        issues: [String] = []
    ) {
        self.fileURL = fileURL
        self.title = title
        self.summary = summary
        self.icon = icon
        self.accepts = accepts
        self.argument = argument
        self.output = output
        self.timeout = timeout
        self.issues = issues
    }

    public var isRunnable: Bool { issues.isEmpty }

    public var acceptsAnything: Bool { accepts.isEmpty || accepts.contains(.any) }

    /// The requirement the input satisfies first, in header order; nil when
    /// the input satisfies none of them. Actions that take anything report
    /// `.any`.
    public func matchedRequirement(for input: ActionInputSummary) -> ActionRequirement? {
        if acceptsAnything { return .any }
        return accepts.first { input.satisfies($0) }
    }

    public func accepts(_ input: ActionInputSummary) -> Bool {
        matchedRequirement(for: input) != nil
    }

    /// "Needs an image" or "Needs text or a link"; nil when the input fits.
    public func unmetRequirementDescription(for input: ActionInputSummary) -> String? {
        guard !accepts(input) else { return nil }
        let names = accepts.map(\.article)
        let joined: String
        switch names.count {
        case 0: return nil
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) or \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + ", or " + names[names.count - 1]
        }
        return "Needs \(joined)"
    }

    /// Case-insensitive match against the title, description, file name, and
    /// the kinds the action accepts, so typing "image" finds image actions.
    public func matches(query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = ([title, summary ?? "", id]
            + accepts.flatMap { [$0.token, $0.displayName] })
            .joined(separator: " ")
            .lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

public enum PaceActionHeader {
    public static let knownKeys = [
        "title", "description", "icon", "accepts", "argument", "output", "timeout"
    ]

    /// Header lines must appear within the first lines of the file so that
    /// large binaries or data files are never scanned.
    static let scanLineLimit = 64

    /// Parses the `@pace.*` lines of `contents`. Lines may use any common
    /// comment prefix (`#`, `//`, `--`, `;`), so actions can be written in
    /// any language.
    public static func parse(_ contents: String, fileURL: URL) -> PaceAction {
        var action = PaceAction(fileURL: fileURL, title: defaultTitle(for: fileURL))
        var issues: [String] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(scanLineLimit) {
            guard let (key, value) = headerField(in: String(rawLine)) else { continue }
            switch key {
            case "title":
                if !value.isEmpty { action.title = value }
            case "description":
                action.summary = value.isEmpty ? nil : value
            case "icon":
                if !value.isEmpty { action.icon = value }
            case "accepts":
                var requirements: [ActionRequirement] = []
                for token in value.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
                    if let requirement = ActionRequirement(token: String(token)) {
                        if !requirements.contains(requirement) { requirements.append(requirement) }
                    } else {
                        issues.append("@pace.accepts doesn't recognize “\(token)”. Use text, image, url, files, any, or a type such as public.movie.")
                    }
                }
                action.accepts = requirements
            case "argument":
                action.argument = value.isEmpty ? "Instructions" : value
            case "output":
                if let mode = ActionOutputMode(rawValue: value.lowercased()) {
                    action.output = mode
                } else {
                    issues.append("@pace.output must be panel, paste, copy, or silent.")
                }
            case "timeout":
                if let seconds = parseDuration(value), seconds > 0 {
                    action.timeout = seconds
                } else {
                    issues.append("@pace.timeout must be a number of seconds, such as 90 or 5m.")
                }
            default:
                let known = knownKeys.map { "@pace.\($0)" }.joined(separator: ", ")
                issues.append("Unknown header @pace.\(key). Known keys: \(known).")
            }
        }
        action.issues = issues
        return action
    }

    /// Whether the text declares any `@pace.` header line.
    static func hasHeader(_ contents: String) -> Bool {
        contents.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(scanLineLimit)
            .contains { headerField(in: String($0)) != nil }
    }

    private static let commentPrefixes = ["//", "--", "#", ";", "%", "*", "/*", "<!--", "'"]

    private static func headerField(in line: String) -> (String, String)? {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        guard text.contains("@pace.") else { return nil }
        for prefix in commentPrefixes.sorted(by: { $0.count > $1.count }) where text.hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
            break
        }
        text = Substring(text.trimmingCharacters(in: .whitespaces))
        guard text.hasPrefix("@pace.") else { return nil }
        text = text.dropFirst("@pace.".count)
        let key = text.prefix { !$0.isWhitespace && $0 != ":" }
        guard !key.isEmpty else { return nil }
        var value = text.dropFirst(key.count)
        if value.first == ":" { value = value.dropFirst() }
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        for suffix in ["*/", "-->"] where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return (key.lowercased(), trimmed)
    }

    static func defaultTitle(for fileURL: URL) -> String {
        let base = fileURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? fileURL.lastPathComponent : base.capitalizedFirstLetter
    }

    static func parseDuration(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        let multipliers: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        for (suffix, multiplier) in multipliers where trimmed.hasSuffix(suffix) {
            let number = trimmed.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            return Double(number).map { $0 * multiplier }
        }
        return Double(trimmed)
    }
}

/// The folder of actions: `~/.config/pace/actions` by default, next to
/// `config.toml`.
public struct PaceActionCatalog: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    public static func defaultDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        PaceConfigurationStore.defaultFileURL(environment: environment, homeDirectory: homeDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("actions", isDirectory: true)
    }

    /// The folder's modification date, or nil when it does not exist. Adding,
    /// removing, or renaming an action changes it; editing one in place does
    /// not, so callers also reload when the panel opens.
    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: directoryURL.path))?[.modificationDate] as? Date
    }

    public func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Every action in the folder, sorted by title. Hidden files, folders,
    /// and files that are neither executable nor carry a `@pace.` header
    /// (a README, say) are skipped. A header without the executable bit is
    /// listed with an issue so the mistake is visible.
    public func load() -> [PaceAction] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var actions: [PaceAction] = []
        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let isExecutable = fileManager.isExecutableFile(atPath: resolved.path)
            let contents = Self.headerText(of: resolved)
            let hasHeader = contents.map(PaceActionHeader.hasHeader) ?? false
            guard isExecutable || hasHeader else { continue }
            var action = PaceActionHeader.parse(contents ?? "", fileURL: url)
            if !isExecutable {
                action.issues.insert("Not executable. Run: chmod +x \(Self.shellQuoted(url.path))", at: 0)
            }
            actions.append(action)
        }
        return actions.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Finds an action by file name (with or without its extension) or by
    /// case-insensitive title.
    public func action(named name: String, in actions: [PaceAction]? = nil) -> PaceAction? {
        let all = actions ?? load()
        let lowered = name.lowercased()
        return all.first { $0.id == name }
            ?? all.first { $0.fileURL.deletingPathExtension().lastPathComponent == name }
            ?? all.first { $0.title.lowercased() == lowered }
            ?? all.first { $0.id.lowercased() == lowered }
    }

    /// The first 16 KB, which is plenty for a header and keeps binaries cheap.
    private static func headerText(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
