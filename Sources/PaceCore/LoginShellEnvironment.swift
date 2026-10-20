import Foundation

/// The environment a terminal would give the user's commands. Apps opened
/// from Finder or at login inherit launchd's minimal PATH, so tools installed
/// with Homebrew, mise, or into ~/.local/bin (claude, llm, ical) would not be
/// found. Pace asks the login shell once and reuses the answer.
public enum LoginShellEnvironment {
    private static let marker = "__PACE_ENVIRONMENT__"

    /// Runs `$SHELL -l -i -c env` and parses its output. Returns nil when
    /// the shell fails or takes longer than `timeout` (an rc file waiting on
    /// a prompt, say).
    public static func capture(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: TimeInterval = 8
    ) -> [String: String]? {
        let shellURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh")
        let process = ActionProcess(
            executable: shellURL,
            arguments: ["-l", "-i", "-c", "printf '\(marker)'; /usr/bin/env -0"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: timeout
        )
        let finished = DispatchSemaphore(value: 0)
        let collected = Collected()
        process.start { event in
            switch event {
            case .stdout(let text): collected.append(text)
            case .stderr: break
            case .exit(let termination):
                collected.setTermination(termination)
                finished.signal()
            }
        }
        finished.wait()
        guard collected.termination?.succeeded == true else { return nil }
        return parse(collected.output)
    }

    static func parse(_ output: String) -> [String: String]? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        var environment: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            guard !key.isEmpty, !key.contains("\n") else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }
        return environment["PATH"] == nil ? nil : environment
    }

    /// The process environment with the usual tool folders added to PATH,
    /// for when the login shell can't be read.
    public static func fallback(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        let home = homeDirectory.path
        let extra = [
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin"
        ]
        let existing = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (extra.filter { !existing.contains($0) } + existing).joined(separator: ":")
        return environment
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var exit: ActionTermination?

        func append(_ chunk: String) { lock.withLock { text += chunk } }
        func setTermination(_ value: ActionTermination) { lock.withLock { exit = value } }
        var output: String { lock.withLock { text } }
        var termination: ActionTermination? { lock.withLock { exit } }
    }
}
