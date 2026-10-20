import AppKit
import Darwin
import Foundation
import PaceCore

/// `pace actions …`: runs entirely in the CLI process, so output streams to
/// the terminal and the app doesn't need to be open (except for --item).
enum ActionsCommand {
    static let usage = """
    Usage: pace actions [list] [--json]
           pace actions path
           pace actions new <name> [--template blank|ask-claude|describe-image] [--force]
           pace actions run <name> [--arg TEXT] [--file PATH|--item ID] [--yes] [--json]
    """

    static func run(values: [String], options: [String: String], flags: Set<String>) throws {
        let catalog = PaceActionCatalog()
        let operation = values.first ?? "list"
        switch operation {
        case "list":
            try list(catalog, json: flags.contains("--json"))
        case "path":
            Swift.print(catalog.directoryURL.path)
        case "new":
            let name = values.dropFirst().joined(separator: " ")
            guard !name.isEmpty else { throw PaceError.invalidArgument(usage) }
            let templateName = options["--template"] ?? PaceActionTemplate.blank.rawValue
            guard let template = PaceActionTemplate(rawValue: templateName) else {
                let names = PaceActionTemplate.allCases.map(\.rawValue).joined(separator: ", ")
                throw PaceError.invalidArgument("Unknown template “\(templateName)”. Templates: \(names).")
            }
            let url = try catalog.create(named: name, template: template, overwrite: flags.contains("--force"))
            Swift.print(url.path)
        case "run":
            guard values.count >= 2 else { throw PaceError.invalidArgument(usage) }
            let name = values.dropFirst().joined(separator: " ")
            guard let action = catalog.action(named: name) else {
                throw PaceError.notFound("No action named “\(name)” in \(catalog.directoryURL.path).")
            }
            let code = try runAction(action, options: options, flags: flags)
            Darwin.exit(code)
        default:
            throw PaceError.invalidArgument(usage)
        }
    }

    // MARK: List

    private static func list(_ catalog: PaceActionCatalog, json: Bool) throws {
        let actions = catalog.load()
        if json {
            let payload = actions.map { action -> [String: Any] in
                var entry: [String: Any] = [
                    "id": action.id,
                    "title": action.title,
                    "path": action.fileURL.path,
                    "icon": action.icon,
                    "accepts": action.acceptsAnything ? ["any"] : action.accepts.map(\.token),
                    "output": action.output.rawValue,
                    "timeout": action.timeout,
                    "runnable": action.isRunnable,
                    "issues": action.issues
                ]
                entry["description"] = action.summary
                entry["argument"] = action.argument
                return entry
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
        guard !actions.isEmpty else {
            Swift.print("No actions in \(catalog.directoryURL.path).")
            Swift.print("Create one with: pace actions new <name> [--template ask-claude]")
            return
        }
        for action in actions {
            let accepts = action.acceptsAnything ? "any" : action.accepts.map(\.token).joined(separator: ", ")
            var line = "\(action.title)  [\(action.id)]  accepts: \(accepts)"
            if action.argument != nil { line += "  · takes instructions" }
            if action.output != .panel { line += "  · output: \(action.output.rawValue)" }
            Swift.print(line)
            if let summary = action.summary { Swift.print("    \(summary)") }
            for issue in action.issues { Swift.print("    ! \(issue)") }
        }
    }

    // MARK: Run

    private static func runAction(_ action: PaceAction, options: [String: String], flags: Set<String>) throws -> Int32 {
        let json = flags.contains("--json")
        let input = try resolveInput(options: options)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pace-actions-cli", isDirectory: true)
        let session = try ActionRunSession(
            action: action,
            input: input,
            argument: options["--arg"] ?? "",
            baseEnvironment: ProcessInfo.processInfo.environment,
            root: root
        )

        // The script runs in its own process group, so Ctrl-C must be passed
        // on; between steps (at the confirm prompt) it quits.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            if session.isRunning {
                session.cancel()
            } else {
                session.discard()
                FileHandle.standardError.write(Data("\n".utf8))
                Darwin.exit(130)
            }
        }
        interrupt.resume()
        defer { interrupt.cancel() }

        var transcript = ""
        var result = execute(session, step: .run, streams: !json, transcript: &transcript)
        var steps = [result]

        if let confirmTitle = result.confirmTitle, result.termination.succeeded {
            if flags.contains("--yes") || (!json && askOnTerminal("\(confirmTitle)?")) {
                transcript = ""
                result = execute(session, step: .confirm, streams: !json, transcript: &transcript)
                steps.append(result)
            } else if !json {
                FileHandle.standardError.write(Data("Offered: \(confirmTitle). Re-run with --yes to confirm.\n".utf8))
            }
        }

        let attachments = result.attachments
        if json {
            var payload: [String: Any] = [
                "action": action.id,
                "steps": steps.map { $0.step.rawValue },
                "status": describe(result.termination),
                "output": transcript,
                "attachments": attachments.map(\.url.path)
            ]
            if case .exited(let code) = result.termination { payload["exit"] = code }
            payload["confirm"] = result.confirmTitle
            payload["undo"] = result.undoTitle
            FileHandle.standardOutput.write(try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            for attachment in attachments {
                FileHandle.standardError.write(Data("Attachment: \(attachment.url.path)\n".utf8))
            }
            if let undoTitle = result.undoTitle, result.termination.succeeded {
                FileHandle.standardError.write(Data("Undo offered (\(undoTitle)); undo is available in the Pace panel.\n".utf8))
            }
            if !result.termination.succeeded {
                FileHandle.standardError.write(Data("pace: \(action.title) \(describe(result.termination)).\n".utf8))
            }
        }
        // Attachments live in the run folder: keep only them, never the
        // staged input or state.
        if attachments.isEmpty {
            session.discard()
        } else {
            for url in [session.directory.inputURL, session.directory.stateURL, session.directory.controlURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        switch result.termination {
        case .exited(let code): return code
        case .signaled(let signal): return 128 + signal
        case .cancelled: return 130
        case .timedOut: return 124
        case .failedToLaunch: return 126
        }
    }

    private static func execute(
        _ session: ActionRunSession,
        step: ActionStep,
        streams: Bool,
        transcript: inout String
    ) -> ActionStepResult {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let stream = session.start(step)
        Task.detached {
            for await event in stream {
                switch event {
                case .stdout(let text):
                    box.append(text)
                    if streams { FileHandle.standardOutput.write(Data(text.utf8)) }
                case .stderr(let text):
                    if streams { FileHandle.standardError.write(Data(text.utf8)) }
                case .finished(let result):
                    box.result = result
                }
            }
            done.signal()
        }
        done.wait()
        transcript = box.output
        return box.result ?? ActionStepResult(step: step, termination: .cancelled, attachments: [])
    }

    private static func describe(_ termination: ActionTermination) -> String {
        switch termination {
        case .exited(0): return "succeeded"
        case .exited(let code): return "failed with exit status \(code)"
        case .signaled(let signal): return "was killed by signal \(signal)"
        case .cancelled: return "was cancelled"
        case .timedOut: return "timed out"
        case .failedToLaunch(let message): return "could not start: \(message)"
        }
    }

    /// Reads y/N from the terminal itself, since stdin may carry the input.
    private static func askOnTerminal(_ question: String) -> Bool {
        guard let tty = fopen("/dev/tty", "r+") else { return false }
        defer { fclose(tty) }
        fputs("\(question) [y/N] ", tty)
        fflush(tty)
        var buffer = [CChar](repeating: 0, count: 64)
        guard fgets(&buffer, Int32(buffer.count), tty) != nil else { return false }
        let answer = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    // MARK: Input

    /// --file, --item, piped stdin, or else the current clipboard.
    private static func resolveInput(options: [String: String]) throws -> ActionInput {
        let source = ClipboardSource(kind: .commandLine, name: "pace")
        if let path = options["--file"] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PaceError.notFound("No file at \(url.path).")
            }
            return ActionInput(
                representations: [ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data(url.absoluteString.utf8))],
                source: source
            )
        }
        if let id = options["--item"] {
            let response = try PaceCLI.sendLaunchingPaceIfNeeded(IPCRequest(command: .get, arguments: ["id": id]))
            guard response.success, let item = response.item else {
                throw PaceError.notFound(response.message ?? "No clipboard item \(id).")
            }
            return ActionInput(representations: item.representations, source: item.source)
        }
        // Only a pipe or a redirected file counts as input: agents, cron, and
        // launchd attach /dev/null or a terminal, which mean "use the clipboard".
        var info = stat()
        if fstat(STDIN_FILENO, &info) == 0,
           (info.st_mode & S_IFMT) == S_IFIFO || (info.st_mode & S_IFMT) == S_IFREG {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if !data.isEmpty {
                return ActionInput(text: String(decoding: data, as: UTF8.self), source: source)
            }
        }
        return clipboardInput()
    }

    private static func clipboardInput() -> ActionInput {
        var representations: [ClipboardRepresentation] = []
        for (index, item) in (NSPasteboard.general.pasteboardItems ?? []).enumerated() {
            for type in item.types {
                if type == .string, let string = item.string(forType: type) {
                    representations.append(ClipboardRepresentation(itemIndex: index, typeIdentifier: type.rawValue, data: Data(string.utf8)))
                } else if let data = item.data(forType: type) {
                    representations.append(ClipboardRepresentation(itemIndex: index, typeIdentifier: type.rawValue, data: data))
                }
            }
        }
        return ActionInput(representations: representations, source: ClipboardSource(kind: .commandLine, name: "Clipboard"))
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var stored: ActionStepResult?

        func append(_ chunk: String) { lock.withLock { text += chunk } }
        var output: String { lock.withLock { text } }
        var result: ActionStepResult? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
