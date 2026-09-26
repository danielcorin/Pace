import Darwin
import Foundation
import TOML

/// Plain-text settings that scripts and dotfiles can manage, read from
/// `~/.config/pace/config.toml` (or `$XDG_CONFIG_HOME/pace/config.toml`).
/// Missing keys fall back to defaults; unknown keys are rejected so typos
/// surface instead of being silently ignored.
public struct PaceConfiguration: Equatable, Sendable {
    public static let defaults = PaceConfiguration()

    /// Bundle identifiers whose copies Pace never records.
    public var excludedApps: [String]

    public init(excludedApps: [String] = []) {
        self.excludedApps = excludedApps
    }

    public func excludesCapture(fromBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return excludedApps.contains {
            $0.compare(bundleIdentifier, options: .caseInsensitive) == .orderedSame
        }
    }
}

public enum PaceConfigurationKey: String, CaseIterable, Sendable {
    case excludedApps = "excluded-apps"

    public var documentation: String {
        switch self {
        case .excludedApps:
            return "Bundle identifiers whose copies Pace never records, such as com.apple.Terminal."
        }
    }
}

public struct PaceConfigurationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let root = environment["XDG_CONFIG_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
        return root.appendingPathComponent("pace/config.toml")
    }

    /// The file's modification date, or nil when it does not exist. Callers
    /// use it to reload only after the file changes.
    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    public func load() throws -> PaceConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .defaults }
        let contents: FileContents
        do {
            contents = try TOMLDecoder().decode(FileContents.self, from: Data(contentsOf: fileURL))
        } catch {
            throw invalid(error.localizedDescription)
        }
        var configuration = PaceConfiguration.defaults
        if let apps = contents.excludedApps {
            configuration.excludedApps = try Self.normalizedBundleIdentifiers(apps, invalid: invalid)
        }
        return configuration
    }

    @discardableResult
    public func update(_ change: (inout PaceConfiguration) throws -> Void) throws -> PaceConfiguration {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = directory.appendingPathComponent(".config.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw invalid("Could not open the configuration lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw invalid("Could not lock the configuration.") }
        defer { flock(descriptor, LOCK_UN) }

        var configuration = try load()
        try change(&configuration)
        configuration.excludedApps = try Self.normalizedBundleIdentifiers(
            configuration.excludedApps,
            invalid: invalid
        )

        let contents = FileContents(
            excludedApps: configuration.excludedApps.isEmpty ? nil : configuration.excludedApps
        )
        if contents.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            let encoder = TOMLEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let body = try encoder.encodeToString(contents)
            let text = "# Pace configuration. Run `pace config show` to list every key.\n\n" + body
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return configuration
    }

    private func invalid(_ reason: String) -> PaceError {
        .invalidArgument("Invalid configuration at \(fileURL.path): \(reason)")
    }

    private static func normalizedBundleIdentifiers(
        _ values: [String],
        invalid: (String) -> PaceError
    ) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else {
                throw invalid("“\(value)” is not a bundle identifier.")
            }
            if seen.insert(trimmed.lowercased()).inserted { result.append(trimmed) }
        }
        return result.sorted { $0.lowercased() < $1.lowercased() }
    }
}

private struct FileContents: Codable {
    var excludedApps: [String]?

    var isEmpty: Bool { excludedApps == nil }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case excludedApps = "excluded-apps"
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(excludedApps: [String]?) {
        self.excludedApps = excludedApps
    }

    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = all.allKeys.map(\.stringValue).sorted().first(where: { !known.contains($0) }) {
            let keys = CodingKeys.allCases.map(\.rawValue).joined(separator: ", ")
            throw PaceError.invalidArgument("Unknown configuration key “\(unknown)”. Known keys: \(keys).")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        excludedApps = try values.decodeIfPresent([String].self, forKey: .excludedApps)
    }
}
