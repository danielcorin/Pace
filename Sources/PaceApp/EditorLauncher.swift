import AppKit
import PaceCore

/// Opens a file in the user's `$VISUAL` / `$EDITOR`, read from the login
/// shell environment (apps don't inherit it). Terminal editors such as nvim
/// get a new terminal window; GUI editors (code, zed, subl) launch directly.
@MainActor
enum EditorLauncher {
    private static let terminalEditors: Set<String> = [
        "vi", "vim", "nvim", "nano", "pico", "hx", "helix", "micro", "kak", "ne", "joe", "mg"
    ]

    private enum Terminal: CaseIterable {
        case ghostty, iTerm, terminal

        var bundleIdentifier: String {
            switch self {
            case .ghostty: return "com.mitchellh.ghostty"
            case .iTerm: return "com.googlecode.iterm2"
            case .terminal: return "com.apple.Terminal"
            }
        }

        var name: String {
            switch self {
            case .ghostty: return "Ghostty"
            case .iTerm: return "iTerm"
            case .terminal: return "Terminal"
            }
        }
    }

    /// Returns false when no editor is configured, so the caller can fall
    /// back to the file's default app.
    static func open(_ file: URL, environment: [String: String]) throws -> Bool {
        let configured = [environment["VISUAL"], environment["EDITOR"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let configured else { return false }
        var words = configured.split(whereSeparator: \.isWhitespace).map(String.init)
        let name = URL(fileURLWithPath: words[0]).lastPathComponent
        guard let executable = resolve(words[0], path: environment["PATH"]) else {
            throw PaceError.notFound("Couldn't find \(words[0]) from $EDITOR on your PATH.")
        }
        words[0] = executable

        let runsInTerminal = terminalEditors.contains(name)
            || (name == "emacs" && words.contains { $0 == "-nw" || $0 == "-t" || $0 == "--no-window-system" })
        if runsInTerminal {
            let command = (words + [file.path]).map(shellQuoted).joined(separator: " ")
            try openInTerminal(command: command, directory: file.deletingLastPathComponent().path)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(words.dropFirst()) + [file.path]
            process.environment = environment
            process.currentDirectoryURL = file.deletingLastPathComponent()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        return true
    }

    private static func openInTerminal(command: String, directory: String) throws {
        let terminal = preferredTerminal()
        let source: String
        switch terminal {
        case .ghostty:
            source = """
            tell application "Ghostty"
                activate
                new window with configuration {command:\(appleScriptString(command)), initial working directory:\(appleScriptString(directory))}
            end tell
            """
        case .iTerm:
            source = """
            tell application "iTerm"
                activate
                create window with default profile command \(appleScriptString("cd \(shellQuoted(directory)) && exec \(command)"))
            end tell
            """
        case .terminal:
            source = """
            tell application "Terminal"
                activate
                do script \(appleScriptString("cd \(shellQuoted(directory)) && exec \(command)"))
            end tell
            """
        }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed."
            if code == -1743 {
                throw PaceError.unavailable(
                    "Allow Pace to control \(terminal.name) in System Settings → Privacy & Security → Automation."
                )
            }
            throw PaceError.unavailable("\(terminal.name) couldn't open the editor: \(message)")
        }
    }

    /// The first supported terminal that's running, else the first installed.
    private static func preferredTerminal() -> Terminal {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let active = Terminal.allCases.first(where: { running.contains($0.bundleIdentifier) }) {
            return active
        }
        return Terminal.allCases.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        } ?? .terminal
    }

    private static func resolve(_ command: String, path: String?) -> String? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in (path ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
