import Darwin
import Foundation
import UniformTypeIdentifiers

/// Which invocation of an action is running. A script offers the follow-up
/// steps by writing a button title to `$PACE_CONTROL_DIR/confirm` or
/// `$PACE_CONTROL_DIR/undo`; Pace then runs the same script again with
/// `PACE_STEP` set to that step, in the same run folder.
public enum ActionStep: String, Codable, Sendable {
    case run
    case confirm
    case undo
}

public enum ActionTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case cancelled
    case timedOut
    case failedToLaunch(String)

    public var succeeded: Bool { self == .exited(0) }
}

/// A file the script left in `$PACE_OUTPUT_DIR`.
public struct ActionAttachment: Equatable, Hashable, Sendable, Identifiable {
    public var url: URL
    public var typeIdentifier: String?
    public var byteCount: Int64

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var isImage: Bool {
        typeIdentifier.flatMap(UTType.init)?.conforms(to: .image) ?? false
    }

    public init(url: URL, typeIdentifier: String?, byteCount: Int64) {
        self.url = url
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
    }
}

public struct ActionStepResult: Equatable, Sendable {
    public var step: ActionStep
    public var termination: ActionTermination
    public var attachments: [ActionAttachment]
    /// Titles of the follow-up steps the script offered, if any.
    public var confirmTitle: String?
    public var undoTitle: String?

    public init(
        step: ActionStep,
        termination: ActionTermination,
        attachments: [ActionAttachment] = [],
        confirmTitle: String? = nil,
        undoTitle: String? = nil
    ) {
        self.step = step
        self.termination = termination
        self.attachments = attachments
        self.confirmTitle = confirmTitle
        self.undoTitle = undoTitle
    }
}

public enum ActionRunEvent: Sendable {
    case stdout(String)
    case stderr(String)
    case finished(ActionStepResult)
}

/// One use of an action on one input: the staged run folder plus the
/// environment every step shares. Steps run one at a time; separate runs
/// are fully independent processes.
public final class ActionRunSession: @unchecked Sendable {
    public let id: UUID
    public let action: PaceAction
    public let directory: ActionRunDirectory
    public let staged: StagedActionInput
    public let argument: String
    private let environment: [String: String]
    private let lock = NSLock()
    private var current: ActionProcess?

    /// Default parent of run folders: private to the user, cleared when the
    /// app launches.
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pace-actions", isDirectory: true)
    }

    public init(
        action: PaceAction,
        input: ActionInput,
        argument: String = "",
        baseEnvironment: [String: String],
        root: URL = ActionRunSession.defaultRoot,
        id: UUID = UUID()
    ) throws {
        guard action.isRunnable else {
            throw PaceError.invalidArgument(action.issues.first ?? "\(action.title) can't run.")
        }
        let summary = input.summary
        guard let requirement = action.matchedRequirement(for: summary) else {
            throw PaceError.invalidArgument(
                "\(action.title): \(action.unmetRequirementDescription(for: summary) ?? "The input doesn't fit").")
        }
        self.id = id
        self.action = action
        self.argument = argument
        directory = try ActionRunDirectory.create(in: root, id: id)
        do {
            staged = try ActionInputStager.stage(input, matched: requirement, in: directory)
        } catch {
            directory.remove()
            throw error
        }

        var environment = baseEnvironment
        for key in ["PWD", "OLDPWD", "SHLVL", "_"] { environment.removeValue(forKey: key) }
        let values: [String: String?] = [
            "PACE_ACTION": action.id,
            "PACE_ACTION_FILE": action.fileURL.path,
            "PACE_RUN_ID": id.uuidString,
            "PACE_RUN_DIR": directory.url.path,
            "PACE_INPUT_DIR": directory.inputURL.path,
            "PACE_INPUT_KIND": staged.kind?.rawValue ?? "",
            "PACE_INPUT_KINDS": staged.kinds.map(\.rawValue).joined(separator: ","),
            "PACE_INPUT_TEXT_FILE": staged.textFile?.path,
            "PACE_INPUT_IMAGE_FILE": staged.imageFile?.path,
            "PACE_INPUT_URL": staged.url?.absoluteString,
            "PACE_ARGUMENT": argument,
            "PACE_OUTPUT_DIR": directory.outputURL.path,
            "PACE_STATE_DIR": directory.stateURL.path,
            "PACE_CONTROL_DIR": directory.controlURL.path,
            "PACE_SOURCE_APP": input.source?.bundleIdentifier ?? "",
            "PACE_SOURCE_APP_NAME": input.source?.name ?? ""
        ]
        for case let (key, value?) in values { environment[key] = value }
        self.environment = environment
    }

    /// Runs one step. The stream ends after its `.finished` event.
    public func start(_ step: ActionStep) -> AsyncStream<ActionRunEvent> {
        clearControlFiles()
        var environment = environment
        environment["PACE_STEP"] = step.rawValue
        let process = ActionProcess(
            executable: action.fileURL,
            arguments: staged.arguments,
            environment: environment,
            workingDirectory: directory.outputURL,
            standardInput: staged.text.map { Data($0.utf8) },
            timeout: action.timeout
        )
        lock.withLock { current = process }
        let directory = directory
        return AsyncStream { continuation in
            process.start { event in
                switch event {
                case .stdout(let text): continuation.yield(.stdout(text))
                case .stderr(let text): continuation.yield(.stderr(text))
                case .exit(let termination):
                    let result = ActionStepResult(
                        step: step,
                        termination: termination,
                        attachments: Self.attachments(in: directory.outputURL),
                        confirmTitle: Self.controlTitle(directory, "confirm", fallback: "Confirm"),
                        undoTitle: Self.controlTitle(directory, "undo", fallback: "Undo")
                    )
                    continuation.yield(.finished(result))
                    continuation.finish()
                }
            }
        }
    }

    public func cancel() {
        lock.withLock { current }?.cancel()
    }

    public var isRunning: Bool {
        lock.withLock { current?.isRunning ?? false }
    }

    /// Stops anything still running, including children the script left
    /// in the background, and deletes the run folder. `waitingUpTo` blocks
    /// briefly so processes that ignore SIGTERM are killed before returning;
    /// use it at quit, when no later SIGKILL could fire.
    public func discard(waitingUpTo grace: TimeInterval? = nil) {
        let process = lock.withLock { current }
        if let grace { process?.terminateNow(grace: grace) } else { process?.cancel() }
        directory.remove()
    }

    /// Deletes the staged input and private state once no follow-up step
    /// can need them, so clipboard contents don't linger on disk while the
    /// run stays listed. Attachments are kept.
    public func releaseInput() {
        let fileManager = FileManager.default
        for url in [directory.inputURL, directory.stateURL] {
            try? fileManager.removeItem(at: url)
        }
    }

    private func clearControlFiles() {
        for name in ["confirm", "undo"] {
            try? FileManager.default.removeItem(at: directory.controlURL.appendingPathComponent(name))
        }
    }

    private static func controlTitle(_ directory: ActionRunDirectory, _ name: String, fallback: String) -> String? {
        let url = directory.controlURL.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let firstLine = String(decoding: data.prefix(4096), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? fallback : String(firstLine.prefix(120))
    }

    static func attachments(in folder: URL) -> [ActionAttachment] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentTypeKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url -> (ActionAttachment, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            let attachment = ActionAttachment(
                url: url,
                typeIdentifier: values.contentType?.identifier
                    ?? UTType(filenameExtension: url.pathExtension)?.identifier,
                byteCount: Int64(values.fileSize ?? 0)
            )
            return (attachment, values.creationDate ?? .distantPast)
        }
        .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
        .map(\.0)
    }
}

/// A child process in its own process group, so cancelling or timing out
/// also stops whatever it spawned (an agent's tool calls, say).
public final class ActionProcess: @unchecked Sendable {
    public enum Event: Sendable {
        case stdout(String)
        case stderr(String)
        case exit(ActionTermination)
    }

    /// Time a cancelled process gets to exit after SIGTERM before SIGKILL.
    static let terminationGrace: TimeInterval = 2
    /// After the script exits, how long to keep reading output that a
    /// lingering grandchild holds open.
    static let drainGrace: TimeInterval = 1
    /// Per-stream output cap. Beyond it, output is read and discarded so a
    /// runaway script can't flood memory or the UI.
    public static let outputLimit = 2_000_000

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL
    private let standardInput: Data?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var processID: pid_t = 0
    private var stopReason: ActionTermination?
    private var exited = false
    /// Whether the process group still has members. A group ID can't be
    /// reused while it does, so signalling it is safe even after the script
    /// itself exited.
    private var groupAlive = false

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectory: URL,
        standardInput: Data? = nil,
        timeout: TimeInterval = PaceAction.defaultTimeout
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
    }

    public var isRunning: Bool { lock.withLock { processID > 0 && !exited } }

    /// Launches the process and reports output as it arrives. `handler` is
    /// called from background queues; `.exit` is always the last event.
    public func start(_ handler: @escaping @Sendable (Event) -> Void) {
        let stdoutPipe = Self.makePipe()
        let stderrPipe = Self.makePipe()
        let stdinPipe = standardInput == nil ? nil : Self.makePipe()
        guard let stdoutPipe, let stderrPipe, standardInput == nil || stdinPipe != nil else {
            handler(.exit(.failedToLaunch("Could not create pipes.")))
            return
        }

        let spawned = spawn(stdin: stdinPipe, stdout: stdoutPipe.write, stderr: stderrPipe.write)
        close(stdoutPipe.write)
        close(stderrPipe.write)
        if let stdinPipe { close(stdinPipe.read) }

        guard case .success(let pid) = spawned else {
            close(stdoutPipe.read)
            close(stderrPipe.read)
            if let stdinPipe { close(stdinPipe.write) }
            if case .failure(let message) = spawned { handler(.exit(.failedToLaunch(message))) }
            return
        }
        lock.withLock {
            processID = pid
            groupAlive = true
        }

        if let stdinPipe, let standardInput {
            // Non-blocking, and abandoned once the script exits: a script that
            // never reads stdin (while a background child holds it open) must
            // not pin this thread, and one that exits early must not raise
            // SIGPIPE in Pace.
            _ = fcntl(stdinPipe.write, F_SETNOSIGPIPE, 1)
            _ = fcntl(stdinPipe.write, F_SETFL, fcntl(stdinPipe.write, F_GETFL) | O_NONBLOCK)
            DispatchQueue.global(qos: .utility).async { [self] in
                standardInput.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count, !lock.withLock({ exited }) {
                        var writable = pollfd(fd: stdinPipe.write, events: Int16(POLLOUT), revents: 0)
                        guard poll(&writable, 1, 100) > 0 else { continue }
                        let written = write(stdinPipe.write, buffer.baseAddress! + offset, buffer.count - offset)
                        if written < 0, errno == EAGAIN || errno == EINTR { continue }
                        if written <= 0 { break }
                        offset += written
                    }
                }
                close(stdinPipe.write)
            }
        }

        let group = DispatchGroup()
        let readers = [
            PipeReader(descriptor: stdoutPipe.read, limit: Self.outputLimit) { handler(.stdout($0)) },
            PipeReader(descriptor: stderrPipe.read, limit: Self.outputLimit) { handler(.stderr($0)) }
        ]
        for reader in readers { reader.start(in: group) }

        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
            guard let self, !self.lock.withLock({ self.exited }) else { return }
            self.stop(reason: .timedOut)
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            lock.withLock { exited = true }
            watchGroup(pid)
            // Output a backgrounded grandchild keeps open must not hold the
            // result forever.
            if group.wait(timeout: .now() + Self.drainGrace) == .timedOut {
                readers.forEach { $0.abandon() }
                group.wait()
            }
            let reason = lock.withLock { stopReason }
            let termination: ActionTermination
            if let reason {
                termination = reason
            } else if Self.didExit(status) {
                termination = .exited(Self.exitStatus(status))
            } else {
                termination = .signaled(Self.terminationSignal(status))
            }
            handler(.exit(termination))
        }
    }

    /// Stops the process group. After the script itself has exited this
    /// still reaches children it left running in the background.
    public func cancel() {
        stop(reason: .cancelled)
    }

    /// Polls until the last member of the group is gone.
    private func watchGroup(_ pid: pid_t) {
        if killpg(pid, 0) == 0 {
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.watchGroup(pid)
            }
        } else {
            lock.withLock { groupAlive = false }
        }
    }

    private func stop(reason: ActionTermination) {
        let pid: pid_t? = lock.withLock {
            guard processID > 0, groupAlive else { return nil }
            if !exited, stopReason == nil { stopReason = reason }
            return processID
        }
        guard let pid else { return }
        guard killpg(pid, SIGTERM) == 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            if let self, !self.lock.withLock({ self.groupAlive }) { return }
            killpg(pid, SIGKILL)
        }
    }

    /// SIGTERM, a short synchronous wait, then SIGKILL for anything left.
    /// For quitting, when a scheduled SIGKILL would never run.
    public func terminateNow(grace: TimeInterval) {
        let pid: pid_t? = lock.withLock {
            guard processID > 0, groupAlive else { return nil }
            if !exited, stopReason == nil { stopReason = .cancelled }
            return processID
        }
        guard let pid, killpg(pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if killpg(pid, 0) != 0 { return }
            usleep(20_000)
        }
        killpg(pid, SIGKILL)
    }

    private enum SpawnResult {
        case success(pid_t)
        case failure(String)
    }

    private func spawn(stdin: (read: Int32, write: Int32)?, stdout: Int32, stderr: Int32) -> SpawnResult {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            return .failure("Could not prepare the action process.")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin.read, STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        // A new process group (so the whole tree can be signalled), no
        // inherited descriptors beyond stdio, and default signal handling
        // even though Pace ignores SIGPIPE.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        let argv = ([executable.path] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var argvPointers = argv + [nil]
        var envpPointers = envp + [nil]
        var pid: pid_t = 0
        let result = argvPointers.withUnsafeMutableBufferPointer { argvBuffer in
            envpPointers.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(&pid, executable.path, &actions, &attributes, argvBuffer.baseAddress, envpBuffer.baseAddress)
            }
        }
        guard result == 0 else {
            switch result {
            case ENOEXEC:
                return .failure("\(executable.lastPathComponent) has no #! line, so macOS can't run it.")
            case EACCES:
                return .failure("\(executable.lastPathComponent) isn't executable. Run chmod +x on it.")
            default:
                return .failure("Could not start \(executable.lastPathComponent): \(String(cString: strerror(result))).")
            }
        }
        return .success(pid)
    }

    private static func makePipe() -> (read: Int32, write: Int32)? {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return nil }
        // Pace's ends must not leak into other children it launches.
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
        return (descriptors[0], descriptors[1])
    }

    private static func didExit(_ status: Int32) -> Bool { status & 0x7f == 0 }
    private static func exitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0xff }
    private static func terminationSignal(_ status: Int32) -> Int32 { status & 0x7f }
}

/// Reads one pipe to EOF on a background queue, emitting UTF-8 text without
/// ever splitting a multi-byte character across chunks.
private final class PipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let limit: Int
    private let emit: @Sendable (String) -> Void
    private let lock = NSLock()
    private var abandoned = false

    init(descriptor: Int32, limit: Int, emit: @escaping @Sendable (String) -> Void) {
        self.descriptor = descriptor
        self.limit = limit
        self.emit = emit
    }

    func start(in group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                close(descriptor)
                group.leave()
            }
            var pending = Data()
            var emitted = 0
            var truncated = false
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                if lock.withLock({ abandoned }) { break }
                var readable = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&readable, 1, 100)
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue } else { break } }
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                // Past the cap, keep draining so the script never blocks on
                // a full pipe, but drop what it writes.
                if truncated { continue }
                pending.append(contentsOf: buffer[0..<min(count, limit - emitted)])
                let complete = Self.completeUTF8Prefix(pending)
                if complete > 0 {
                    emit(String(decoding: pending.prefix(complete), as: UTF8.self))
                    pending.removeFirst(complete)
                    emitted += complete
                }
                if emitted + pending.count >= limit {
                    truncated = true
                    pending.removeAll()
                    emit("\n[Output truncated by Pace]\n")
                }
            }
            if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
        }
    }

    func abandon() {
        lock.withLock { abandoned = true }
    }

    /// The length of the longest prefix that doesn't end mid-character.
    static func completeUTF8Prefix(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        let count = data.count
        for back in 1...min(4, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0b1000_0000 == 0 { return count }  // ASCII ends cleanly
            if byte & 0b1100_0000 == 0b1100_0000 {  // a lead byte
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                return back >= needed ? count : count - back
            }
        }
        return count
    }
}
