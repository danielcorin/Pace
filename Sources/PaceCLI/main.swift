import Darwin
import Foundation
import PaceCore

struct PaceCLI {
    static func main() {
        do {
            let command = try Command(arguments: Array(CommandLine.arguments.dropFirst()))
            if command.printHelpIfRequested() { return }
            if try command.runLocally() { return }
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
    private static let booleanOptions: Set<String> = [
        "--clear-keyword", "--clear-tags", "--encrypt", "--expand", "--force",
        "--include-pinned", "--json", "--no-expand", "--ocr-text", "--pin", "--pinned", "--plain",
        "--protect-pinned", "--prune", "--snippets", "--unpin"
    ]

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
                if Self.booleanOptions.contains(argument) {
                    flags.insert(argument)
                    index += 1
                } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
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
            case "show":
                let scope = flags.contains("--snippets") ? "snippets" : options["--mode"]
                return IPCRequest(command: .show, arguments: scope.map { ["scope": $0] } ?? [:])
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
            case "snippet", "snippets": return try snippetRequest()
            case "export": return try exportRequest()
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
            if let snippetCount = status.snippetCount { Swift.print("Snippets: \(snippetCount)") }
            if let enabled = status.isSnippetExpansionEnabled {
                Swift.print("Expansion: \(enabled ? "enabled" : "disabled")")
            }
            return
        }

        if let snippets = response.snippets {
            for snippet in snippets {
                let keyword = snippet.keyword ?? "-"
                let state = [
                    snippet.isPinned ? "pinned" : nil,
                    snippet.isExpansionEnabled ? "expands" : nil
                ].compactMap { $0 }.joined(separator: ",")
                let flags = state.isEmpty ? "-" : state
                let preview = snippet.template
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefixString(100)
                Swift.print("\(snippet.id.uuidString)\t\(keyword)\t\(flags)\t\(snippet.name)\t\(preview)")
            }
            return
        }

        let snippetOperation = (name == "snippet" || name == "snippets") ? values.first : nil
        if let rendered = response.renderedSnippet,
           snippetOperation == "render" || snippetOperation == "validate" {
            FileHandle.standardOutput.write(Data(rendered.text.utf8))
            if !rendered.text.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
            return
        }

        if let snippet = response.snippet {
            if snippetOperation == "copy" || snippetOperation == "paste" {
                if let message = response.message { Swift.print(message) }
                return
            }
            Swift.print("ID: \(snippet.id.uuidString)")
            Swift.print("Name: \(snippet.name)")
            Swift.print("Keyword: \(snippet.keyword ?? "none")")
            Swift.print("Tags: \(snippet.tags.isEmpty ? "none" : snippet.tags.joined(separator: ", "))")
            Swift.print("Pinned: \(snippet.isPinned ? "yes" : "no")")
            Swift.print("Expansion: \(snippet.isExpansionEnabled ? "enabled" : "disabled")")
            Swift.print("Uses: \(snippet.useCount)")
            Swift.print("Template:")
            FileHandle.standardOutput.write(Data(snippet.template.utf8))
            if !snippet.template.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
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

    private func snippetRequest() throws -> IPCRequest {
        guard let operation = values.first else {
            throw PaceError.invalidArgument(
                "Usage: pace snippets list|search|get|add|update|delete|render|validate|copy|paste|promote"
            )
        }
        switch operation {
        case "list":
            return IPCRequest(
                command: .snippetList,
                arguments: ["limit": options["--limit"] ?? "100"]
            )
        case "search":
            let query = values.dropFirst().joined(separator: " ")
            guard !query.isEmpty else {
                throw PaceError.invalidArgument("Usage: pace snippets search <query>")
            }
            return IPCRequest(
                command: .snippetSearch,
                arguments: ["query": query, "limit": options["--limit"] ?? "100"]
            )
        case "get", "delete", "copy", "paste", "render":
            let identifier = try requiredSnippetIdentifier(for: operation)
            let command: IPCCommand
            switch operation {
            case "get": command = .snippetGet
            case "delete": command = .snippetDelete
            case "copy": command = .snippetCopy
            case "paste": command = .snippetPaste
            default: command = .snippetRender
            }
            return IPCRequest(command: command, arguments: ["identifier": identifier])
        case "add":
            guard values.count >= 2 else {
                throw PaceError.invalidArgument("Usage: pace snippets add <name> --template <text>")
            }
            var arguments = try snippetMutationArguments()
            arguments["name"] = values[1]
            return IPCRequest(
                command: .snippetAdd,
                arguments: arguments,
                input: try snippetTemplateInput(positionalStart: 2, required: true)
            )
        case "update":
            guard values.count >= 2 else {
                throw PaceError.invalidArgument("Usage: pace snippets update <id|name|keyword> [options]")
            }
            var arguments = try snippetMutationArguments()
            arguments["identifier"] = values[1]
            return IPCRequest(
                command: .snippetUpdate,
                arguments: arguments,
                input: try snippetTemplateInput(positionalStart: 2, required: false)
            )
        case "validate":
            return IPCRequest(
                command: .snippetRender,
                input: try snippetTemplateInput(positionalStart: 1, required: true)
            )
        case "promote":
            guard values.count >= 2, UUID(uuidString: values[1]) != nil else {
                throw PaceError.invalidArgument("Usage: pace snippets promote <clipboard-item-id> [options]")
            }
            var arguments = try snippetMutationArguments()
            arguments["clipboardID"] = values[1]
            return IPCRequest(command: .snippetPromote, arguments: arguments)
        case "show":
            return IPCRequest(command: .show, arguments: ["scope": "snippets"])
        default:
            throw PaceError.invalidArgument("Unknown snippets operation '\(operation)'.")
        }
    }

    private func requiredSnippetIdentifier(for operation: String) throws -> String {
        let identifier = values.dropFirst().joined(separator: " ")
        guard !identifier.isEmpty else {
            throw PaceError.invalidArgument("Usage: pace snippets \(operation) <id|name|keyword>")
        }
        return identifier
    }

    private func snippetMutationArguments() throws -> [String: String] {
        var arguments: [String: String] = [:]
        arguments["name"] = options["--name"]
        arguments["keyword"] = options["--keyword"]
        arguments["tags"] = options["--tags"]
        if flags.contains("--clear-keyword") { arguments["clearKeyword"] = "true" }
        if flags.contains("--clear-tags") { arguments["clearTags"] = "true" }

        let wantsPin = flags.contains("--pin") || flags.contains("--pinned")
        let wantsUnpin = flags.contains("--unpin")
        guard !(wantsPin && wantsUnpin) else {
            throw PaceError.invalidArgument("Use either --pin or --unpin, not both.")
        }
        if wantsPin { arguments["isPinned"] = "true" }
        if wantsUnpin { arguments["isPinned"] = "false" }

        let wantsExpansion = flags.contains("--expand")
        let disablesExpansion = flags.contains("--no-expand")
        guard !(wantsExpansion && disablesExpansion) else {
            throw PaceError.invalidArgument("Use either --expand or --no-expand, not both.")
        }
        if wantsExpansion { arguments["isExpansionEnabled"] = "true" }
        if disablesExpansion { arguments["isExpansionEnabled"] = "false" }
        return arguments
    }

    private func snippetTemplateInput(positionalStart: Int, required: Bool) throws -> Data? {
        var sources: [Data] = []
        if let template = options["--template"] { sources.append(Data(template.utf8)) }
        if let path = options["--file"] {
            sources.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        if values.count > positionalStart {
            sources.append(Data(values.dropFirst(positionalStart).joined(separator: " ").utf8))
        }
        if sources.isEmpty, isatty(STDIN_FILENO) == 0 {
            let piped = FileHandle.standardInput.readDataToEndOfFile()
            if !piped.isEmpty { sources.append(piped) }
        }
        guard sources.count <= 1 else {
            throw PaceError.invalidArgument(
                "Provide snippet text once using a positional value, --template, --file, or stdin."
            )
        }
        if let source = sources.first { return source }
        if required {
            throw PaceError.invalidArgument(
                "Snippet template text is required; use --template, --file, a positional value, or stdin."
            )
        }
        return nil
    }

    /// Commands that never need the running app: config edits the TOML file
    /// directly, and decrypting an export only needs the passphrase.
    func runLocally() throws -> Bool {
        switch (name, values.first) {
        case ("config", _):
            try runConfig()
            return true
        case ("export", "decrypt"):
            try decryptExport()
            return true
        default:
            return false
        }
    }

    private func exportRequest() throws -> IPCRequest {
        guard values.isEmpty, let output = options["--output"] else {
            throw PaceError.invalidArgument(
                "Usage: pace export --output PATH [--encrypt] [--only clipboard|snippets] [--force]"
            )
        }
        var arguments = ["path": Self.absolutePath(output)]
        if let scope = options["--only"] { arguments["scope"] = scope }
        if flags.contains("--force") { arguments["overwrite"] = "true" }
        var input: Data?
        if flags.contains("--encrypt") {
            arguments["encrypt"] = "true"
            input = Data(try Self.readExportPassphrase(confirm: true).utf8)
        }
        return IPCRequest(command: .export, arguments: arguments, input: input)
    }

    private func decryptExport() throws {
        guard values.count == 2 else {
            throw PaceError.invalidArgument("Usage: pace export decrypt <file> [--output PATH] [--force]")
        }
        let encrypted = try Data(contentsOf: URL(fileURLWithPath: Self.absolutePath(values[1])))
        guard PaceExportCodec.isEncrypted(encrypted) else {
            throw PaceError.invalidArgument("\(values[1]) is not an encrypted Pace export.")
        }
        let plaintext = try PaceExportCodec.decrypt(
            encrypted,
            passphrase: Self.readExportPassphrase(confirm: false)
        )
        if let output = options["--output"] {
            let url = URL(fileURLWithPath: Self.absolutePath(output))
            try PaceExportCodec.write(plaintext, to: url, overwrite: flags.contains("--force"))
            FileHandle.standardError.write(Data("Decrypted export written to \(url.path).\n".utf8))
        } else {
            FileHandle.standardOutput.write(plaintext)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private func runConfig() throws {
        let store = PaceConfigurationStore()
        let operation = values.first ?? "show"
        switch operation {
        case "path":
            Swift.print(store.fileURL.path)
        case "show":
            let configuration = try store.load()
            if flags.contains("--json") {
                let payload: [String: Any] = [
                    "path": store.fileURL.path,
                    PaceConfigurationKey.excludedApps.rawValue: configuration.excludedApps
                ]
                FileHandle.standardOutput.write(try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                ))
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }
            Swift.print("# \(store.fileURL.path)")
            for key in PaceConfigurationKey.allCases {
                Swift.print("# \(key.documentation)")
                switch key {
                case .excludedApps:
                    let quoted = configuration.excludedApps.map { "\"\($0)\"" }
                    Swift.print("\(key.rawValue) = [\(quoted.joined(separator: ", "))]")
                }
            }
        case "exclude", "include":
            let identifiers = try values.dropFirst().map(Self.bundleIdentifier(for:))
            guard !identifiers.isEmpty else {
                throw PaceError.invalidArgument("Usage: pace config \(operation) <bundle-id|path/to/App.app>…")
            }
            try store.update { configuration in
                for identifier in identifiers {
                    configuration.excludedApps.removeAll {
                        $0.compare(identifier, options: .caseInsensitive) == .orderedSame
                    }
                    if operation == "exclude" { configuration.excludedApps.append(identifier) }
                }
            }
            for identifier in identifiers {
                Swift.print(operation == "exclude"
                    ? "Pace will not record copies from \(identifier)."
                    : "Pace records copies from \(identifier).")
            }
        default:
            throw PaceError.invalidArgument("Usage: pace config show|path|exclude|include")
        }
    }

    private static func bundleIdentifier(for argument: String) throws -> String {
        guard argument.hasSuffix(".app") || argument.hasSuffix(".app/") else { return argument }
        let url = URL(fileURLWithPath: absolutePath(argument))
        guard let identifier = Bundle(url: url)?.bundleIdentifier else {
            throw PaceError.invalidArgument("Could not read a bundle identifier from \(argument).")
        }
        return identifier
    }

    private static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Scripts can supply PACE_EXPORT_PASSPHRASE; otherwise the passphrase is
    /// read from the terminal without echo, never from argv where other
    /// processes could see it.
    private static func readExportPassphrase(confirm: Bool) throws -> String {
        if let value = ProcessInfo.processInfo.environment["PACE_EXPORT_PASSPHRASE"], !value.isEmpty {
            return value
        }
        guard let passphrase = promptSecret("Export passphrase: ") else {
            throw PaceError.invalidArgument(
                "A passphrase is required. Run in a terminal or set PACE_EXPORT_PASSPHRASE."
            )
        }
        if confirm {
            guard passphrase.count >= PaceExportCodec.minimumPassphraseLength else {
                throw PaceError.invalidArgument(
                    "The export passphrase must be at least \(PaceExportCodec.minimumPassphraseLength) characters."
                )
            }
            guard promptSecret("Confirm passphrase: ") == passphrase else {
                throw PaceError.invalidArgument("The passphrases don't match.")
            }
        }
        return passphrase
    }

    private static func promptSecret(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { _ = memset_s(&buffer, buffer.count, 0, buffer.count) }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
        return String(cString: buffer)
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
    Pace — encrypted clipboard and snippet manager

    Usage:
      pace status|unlock|lock
      pace show [--mode clipboard|snippets]
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
      pace export --output PATH [--encrypt] [--only clipboard|snippets] [--force]
      pace export decrypt <file> [--output PATH] [--force]
      pace config show|path [--json]
      pace config exclude|include <bundle-id|path/to/App.app>…

      pace snippets show
      pace snippets list [--limit N] [--json]
      pace snippets search <query> [--limit N] [--json]
      pace snippets get <id|name|keyword> [--json]
      pace snippets add <name> <template> [--keyword KEY] [--tags a,b]
                        [--pin] [--no-expand] [--json]
      pace snippets add <name> --template TEXT|--file PATH [options]
      command | pace snippets add <name> [options]
      pace snippets update <id|name|keyword> [--name NAME]
                           [--template TEXT|--file PATH] [--keyword KEY|--clear-keyword]
                           [--tags a,b|--clear-tags] [--pin|--unpin]
                           [--expand|--no-expand] [--json]
      pace snippets render <id|name|keyword> [--json]
      pace snippets validate <template>|--template TEXT|--file PATH [--json]
      pace snippets copy|paste|delete <id|name|keyword> [--json]
      pace snippets promote <clipboard-item-id> [--name NAME] [--keyword KEY]
                            [--tags a,b] [--pin] [--expand] [--json]

    Snippets can be addressed by full or unique-prefix UUID, exact keyword,
    or case-insensitive name. Template input may be positional, piped on stdin,
    or supplied with --template/--file.

    Exports are JSON. Plain exports are unencrypted; --encrypt prompts for a
    passphrase (or reads PACE_EXPORT_PASSPHRASE) and seals the file with
    AES-256-GCM. `pace config` edits ~/.config/pace/config.toml, which the
    app re-reads on the next copy.
    """
}
