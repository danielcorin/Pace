import Darwin
import Foundation
import PaceCore

struct PaceCLI {
    static func main() {
        do {
            let command = try Command(arguments: Array(CommandLine.arguments.dropFirst()))
            if command.printHelpIfRequested() { return }
            let response = try sendLaunchingPaceIfNeeded(command.request)
            guard response.success else {
                let message = response.message ?? "Pace command failed."
                FileHandle.standardError.write(Data(("pace: \(message)\n").utf8))
                Darwin.exit(response.errorCode == "vault_locked" ? 3 : 1)
            }
            try command.print(response)
        } catch {
            FileHandle.standardError.write(Data(("pace: \(error.localizedDescription)\n").utf8))
            Darwin.exit(error is PaceError ? 2 : 1)
        }
    }

    private static func sendLaunchingPaceIfNeeded(_ request: IPCRequest) throws -> IPCResponse {
        do {
            return try LocalSocketClient.send(request)
        } catch PaceError.unavailable {
            try launchPace()
            for _ in 0..<25 {
                Thread.sleep(forTimeInterval: 0.08)
                if let response = try? LocalSocketClient.send(request) { return response }
            }
            throw PaceError.unavailable("Pace could not be started. Open Pace and try again.")
        }
    }

    private static func launchPace() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let possibleApp = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        if possibleApp.pathExtension == "app" {
            let applicationExecutable = possibleApp
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent("Pace")
            try launchDetached(executable: applicationExecutable.path)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-a", "Pace"]
            try process.run()
            process.waitUntilExit()
        }
    }

    private static func launchDetached(executable: String) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw PaceError.unavailable("Could not prepare the Pace background process.")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let argument = Darwin.strdup(executable)
        defer { Darwin.free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var environment = ProcessInfo.processInfo.environment.map { key, value in
            Darwin.strdup("\(key)=\(value)")
        }
        defer { environment.compactMap { $0 }.forEach { Darwin.free($0) } }
        environment.append(nil)
        var processID: pid_t = 0
        let result = executable.withCString { path in
            arguments.withUnsafeMutableBufferPointer { argumentBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &processID,
                        path,
                        &actions,
                        &attributes,
                        argumentBuffer.baseAddress!,
                        environmentBuffer.baseAddress!
                    )
                }
            }
        }
        guard result == 0 else {
            throw PaceError.unavailable("Could not start Pace (error \(result)).")
        }
    }
}

PaceCLI.main()

private struct Command {
    let name: String
    let values: [String]
    let options: [String: String]
    let flags: Set<String>

    init(arguments: [String]) throws {
        guard let name = arguments.first else {
            self.name = "help"
            values = []
            options = [:]
            flags = []
            return
        }
        self.name = name
        var values: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options[argument] = arguments[index + 1]
                    index += 2
                } else {
                    flags.insert(argument)
                    index += 1
                }
            } else {
                values.append(argument)
                index += 1
            }
        }
        self.values = values
        self.options = options
        self.flags = flags
    }

    var request: IPCRequest {
        get throws {
            switch name {
            case "help", "--help", "-h":
                return IPCRequest(command: .status, arguments: ["help": "true"])
            case "status": return IPCRequest(command: .status)
            case "show": return IPCRequest(command: .show)
            case "unlock": return IPCRequest(command: .unlock)
            case "lock": return IPCRequest(command: .lock)
            case "list":
                return IPCRequest(command: .list, arguments: ["limit": options["--limit"] ?? "100"])
            case "search":
                guard !values.isEmpty else { throw PaceError.invalidArgument("Usage: pace search <query>") }
                return IPCRequest(
                    command: .search,
                    arguments: ["query": values.joined(separator: " "), "limit": options["--limit"] ?? "100"]
                )
            case "get": return IPCRequest(command: .get, arguments: ["id": try requiredID()])
            case "add":
                let (data, type) = try input()
                var arguments = [
                    "contentType": type,
                    "source": options["--source"] ?? "Pace CLI"
                ]
                arguments["session"] = options["--session"]
                arguments["timestamp"] = options["--timestamp"]
                arguments["sourceKind"] = options["--source-kind"]
                return IPCRequest(command: .add, arguments: arguments, input: data)
            case "copy", "paste":
                var arguments = ["id": try requiredID()]
                if flags.contains("--ocr-text") {
                    arguments["mode"] = "ocrText"
                } else if flags.contains("--plain") {
                    arguments["mode"] = "plainText"
                }
                return IPCRequest(command: name == "copy" ? .copy : .paste, arguments: arguments)
            case "delete": return IPCRequest(command: .delete, arguments: ["id": try requiredID()])
            case "clear": return IPCRequest(command: .clear)
            case "pin", "unpin":
                return IPCRequest(
                    command: .pin,
                    arguments: ["id": try requiredID(), "value": name == "pin" ? "true" : "false"]
                )
            case "retention": return try retentionRequest()
            default:
                throw PaceError.invalidArgument("Unknown command '\(name)'. Run `pace help` for usage.")
            }
        }
    }

    func printHelpIfRequested() -> Bool {
        guard name == "help" || name == "--help" || name == "-h" else { return false }
        Swift.print(Self.help)
        return true
    }

    func print(_ response: IPCResponse) throws {
        if name == "help" || name == "--help" || name == "-h" {
            Swift.print(Self.help)
            return
        }
        if flags.contains("--json") {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        if let status = response.status {
            Swift.print("Vault: \(status.isUnlocked ? "unlocked" : "locked")")
            let captureState = status.isUnlocked
                ? (status.isCapturePaused ? "paused" : "active")
                : "inactive while locked"
            Swift.print("Capture: \(captureState)")
            if let count = status.itemCount { Swift.print("Items: \(count)") }
            if let bytes = status.storageBytes {
                Swift.print("Storage: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            }
            return
        }

        if let records = response.records {
            for record in records {
                let id = record.id.uuidString
                let source = record.source.name
                let preview = record.preview.replacingOccurrences(of: "\n", with: " ")
                Swift.print("\(id)\t\(record.kind.rawValue)\t\(source)\t\(preview)")
            }
            return
        }

        if let item = response.item {
            if let output = options["--output"] {
                guard let representation = item.representations.first else {
                    throw PaceError.notFound("The item has no exportable representation.")
                }
                try representation.data.write(to: URL(fileURLWithPath: output), options: .atomic)
            } else if flags.contains("--ocr-text"), let text = item.ocrText {
                FileHandle.standardOutput.write(Data(text.utf8))
                if !text.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
            } else if let text = item.plainText {
                FileHandle.standardOutput.write(Data(text.utf8))
                if !text.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
            } else {
                Swift.print("Binary clipboard item. Use --output <path> or --json.")
            }
            return
        }

        if let policy = response.retentionPolicy {
            Swift.print("Days: \(policy.maximumAgeDays.map(String.init) ?? "unlimited")")
            Swift.print("Items: \(policy.maximumItemCount.map(String.init) ?? "unlimited")")
            Swift.print("Storage: \(policy.maximumStorageBytes.map(String.init) ?? "unlimited") bytes")
            Swift.print("Protect pinned: \(policy.protectsPinnedItems ? "yes" : "no")")
        }
        if let report = response.retentionReport {
            Swift.print("Cleanup: \(report.itemCount) items, \(ByteCountFormatter.string(fromByteCount: report.byteCount, countStyle: .file))")
        }
        if let message = response.message { Swift.print(message) }
    }

    private func requiredID() throws -> String {
        guard let id = values.first, UUID(uuidString: id) != nil else {
            throw PaceError.invalidArgument("A full clipboard item UUID is required.")
        }
        return id
    }

    private func input() throws -> (Data, String) {
        if let path = options["--file"] {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let type: String
            switch url.pathExtension.lowercased() {
            case "png": type = "public.png"
            case "jpg", "jpeg": type = "public.jpeg"
            case "tif", "tiff": type = "public.tiff"
            default: type = "public.data"
            }
            return (data, type)
        }
        if !values.isEmpty {
            return (Data(values.joined(separator: " ").utf8), "public.utf8-plain-text")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw PaceError.invalidArgument("Usage: pace add <text>, pace add --file <path>, or pipe content on stdin.")
        }
        return (data, options["--type"] ?? "public.utf8-plain-text")
    }

    private func retentionRequest() throws -> IPCRequest {
        guard let operation = values.first else {
            throw PaceError.invalidArgument("Usage: pace retention show|set|preview|prune")
        }
        switch operation {
        case "show": return IPCRequest(command: .retentionShow)
        case "preview": return IPCRequest(command: .retentionPreview)
        case "prune": return IPCRequest(command: .retentionPrune)
        case "set":
            var arguments: [String: String] = [:]
            arguments["days"] = options["--days"]
            arguments["items"] = options["--max-items"]
            if let storage = options["--max-storage"] {
                arguments["bytes"] = try parseByteCount(storage)
            }
            if flags.contains("--protect-pinned") { arguments["protectPinned"] = "true" }
            if flags.contains("--include-pinned") { arguments["protectPinned"] = "false" }
            if flags.contains("--prune") { arguments["prune"] = "true" }
            guard !arguments.isEmpty else {
                throw PaceError.invalidArgument("Provide at least one retention limit to change.")
            }
            return IPCRequest(command: .retentionSet, arguments: arguments)
        default:
            throw PaceError.invalidArgument("Unknown retention operation '\(operation)'.")
        }
    }

    private func parseByteCount(_ value: String) throws -> String {
        if value.lowercased() == "unlimited" { return "unlimited" }
        let lower = value.lowercased()
        let multipliers: [(String, Int64)] = [("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1_000)]
        for (suffix, multiplier) in multipliers where lower.hasSuffix(suffix) {
            let number = lower.dropLast(suffix.count)
            guard let amount = Double(number) else { break }
            return String(Int64(amount * Double(multiplier)))
        }
        guard let bytes = Int64(lower) else {
            throw PaceError.invalidArgument("Invalid storage size '\(value)'. Use values such as 500MB, 1GB, or unlimited.")
        }
        return String(bytes)
    }

    private static let help = """
    Pace — encrypted clipboard history

    Usage:
      pace status|unlock|lock
      pace show
      pace list [--limit N] [--json]
      pace search <query> [--limit N] [--json]
      pace get <id> [--ocr-text|--output PATH] [--json]
      pace add <text> [--source NAME] [--session ID]
      pace add --file PATH [--source NAME]
      command | pace add [--source NAME]
      pace add … [--timestamp UNIX_SECONDS] [--source-kind application|agent]
      pace copy|paste <id> [--plain|--ocr-text]
      pace pin|unpin|delete <id>
      pace clear
      pace retention show|preview|prune
      pace retention set [--days N|unlimited] [--max-items N|unlimited]
                         [--max-storage 1GB|unlimited] [--prune]
    """
}
