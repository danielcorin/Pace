import AppKit
import Combine
import ImageIO
import PaceCore
import SwiftUI
import UniformTypeIdentifiers

/// What the Actions panel will hand to an action: the clipboard when the
/// panel opened, or a history item passed over with ⌘K.
struct PanelActionInput {
    enum Origin: Equatable {
        case clipboard
        case history(UUID)
    }

    let id = UUID()
    let input: ActionInput
    let summary: ActionInputSummary
    let origin: Origin
    let thumbnail: NSImage?
    /// The image's real dimensions; the thumbnail is downsampled.
    let pixelSize: CGSize?
    let textPreview: String?
    let isSensitive: Bool

    var label: String {
        switch summary.primaryKind {
        case .files?:
            let names = summary.fileNames
            return names.count == 1 ? names[0] : "\(names.count) files"
        case .image?:
            if let pixelSize, pixelSize.width > 0 {
                return "Image \(Int(pixelSize.width))×\(Int(pixelSize.height))"
            }
            return "Image"
        case .url?:
            return input.url?.host ?? "Link"
        case .text?:
            let count = summary.textLength
            return count == 1 ? "Text · 1 character" : "Text · \(count.formatted()) characters"
        case nil:
            return "Empty clipboard"
        }
    }

    var originTitle: String {
        switch origin {
        case .clipboard: return "Clipboard"
        case .history: return "History item"
        }
    }
}

enum ActionsSelection: Hashable {
    case run(UUID)
    case action(String)

    var runID: UUID? {
        if case .run(let id) = self { return id }
        return nil
    }
}

/// One use of an action. Runs are independent processes: several can be in
/// flight at once, and each survives the panel closing.
@MainActor
final class ActionRun: ObservableObject, Identifiable {
    struct Segment: Identifiable {
        let id = UUID()
        let step: ActionStep
        var output = ""
    }

    enum Phase: Equatable {
        case running(ActionStep)
        case finished(ActionStepResult)
    }

    nonisolated let id: UUID
    let action: PaceAction
    let session: ActionRunSession
    let argument: String
    let inputLabel: String
    let startedAt = Date()
    let target: NSRunningApplication?

    @Published private(set) var phase: Phase = .running(.run)
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var log = ""
    @Published private(set) var statusLine: String?
    @Published private(set) var stepStartedAt = Date()
    @Published private(set) var finishedAt: Date?

    /// Output is buffered and published at most this often, so a chatty
    /// script re-renders the panel a few times a second, not per chunk.
    private static let flushInterval: TimeInterval = 0.1
    private var pendingOutput = ""
    private var pendingLog = ""
    private var flushScheduled = false

    init(session: ActionRunSession, inputLabel: String, target: NSRunningApplication?) {
        id = session.id
        action = session.action
        self.session = session
        argument = session.argument
        self.inputLabel = inputLabel
        self.target = target
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var result: ActionStepResult? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    /// The latest step's output, which paste and copy use.
    var resultText: String {
        (segments.last?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap checks for views that re-render often: neither walks the
    /// whole output.
    var hasResultText: Bool {
        segments.last?.output.contains { !$0.isWhitespace } ?? false
    }

    var firstResultLine: String? {
        guard let output = segments.last?.output else { return nil }
        return output.prefix(4_000)
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    var attachments: [ActionAttachment] { result?.attachments ?? [] }

    /// Follow-up steps are offered only by a step that succeeded.
    var confirmTitle: String? {
        guard let result, result.termination.succeeded else { return nil }
        return result.confirmTitle
    }

    var undoTitle: String? {
        guard let result, result.termination.succeeded else { return nil }
        return result.undoTitle
    }

    func begin(_ step: ActionStep) {
        phase = .running(step)
        segments.append(Segment(step: step))
        statusLine = nil
        stepStartedAt = Date()
        finishedAt = nil
    }

    func apply(_ event: ActionRunEvent) {
        switch event {
        case .stdout(let text):
            pendingOutput += text
            scheduleFlush()
        case .stderr(let text):
            pendingLog += text
            scheduleFlush()
        case .finished(let result):
            flush()
            phase = .finished(result)
            finishedAt = Date()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        if !pendingOutput.isEmpty, var segment = segments.popLast() {
            segment.output += pendingOutput
            segments.append(segment)
        }
        if !pendingLog.isEmpty {
            log += pendingLog
            if let line = pendingLog.suffix(2_000).split(whereSeparator: \.isNewline).last?
                .trimmingCharacters(in: .whitespaces), !line.isEmpty {
                statusLine = String(line.prefix(200))
            }
        }
        pendingOutput = ""
        pendingLog = ""
    }
}

@MainActor
final class ActionCenter: ObservableObject {
    @Published private(set) var actions: [PaceAction] = []
    @Published private(set) var runs: [ActionRun] = []
    @Published private(set) var input: PanelActionInput?
    @Published var selection: ActionsSelection?
    @Published var query = ""
    /// Set when the user approved running actions on input that looks
    /// sensitive; cleared whenever the input changes.
    @Published var sensitiveInputApproved = false

    let catalog = PaceActionCatalog()
    private let model: AppModel
    private let detector = SensitiveContentDetector()
    private var environmentTask: Task<[String: String], Never>?
    private var catalogStamp: Date?
    private var keepsInputOnNextOpen = false
    /// Honored by the next preparePanel instead of the default selection,
    /// so "Show" on a notice lands on its run.
    var pendingSelection: ActionsSelection?
    private var vaultObservation: AnyCancellable?

    /// Wired by the panel coordinator.
    var targetApplication: NSRunningApplication?
    var isPanelShowingActions: () -> Bool = { false }
    var hidePanel: () -> Void = {}
    var showRun: (UUID) -> Void = { _ in }

    /// Finished runs kept for review; older ones are discarded.
    private static let retainedRunLimit = 30

    init(model: AppModel) {
        self.model = model
        // A handed-over history item is decrypted vault content; like the
        // rest of the panel's data it must not outlive a lock. Runs release
        // their staged copy when they finish, unless a confirm or undo step
        // is still on offer.
        vaultObservation = model.$vaultState.sink { [weak self] state in
            guard state != .unlocked, let self else { return }
            MainActor.assumeIsolated {
                self.input = nil
                self.keepsInputOnNextOpen = false
            }
        }
    }

    func start() {
        // Leftovers from a previous launch (a crash, say) may hold input.
        try? FileManager.default.removeItem(at: ActionRunSession.defaultRoot)
        DispatchQueue.global(qos: .background).async { ActionFileStore.pruneOldCopies() }
        environmentTask = Task.detached(priority: .utility) {
            LoginShellEnvironment.capture() ?? LoginShellEnvironment.fallback()
        }
        reloadActions(force: true)
    }

    /// Stops every run and deletes its files; called at quit, so it waits
    /// briefly and force-kills anything that ignores SIGTERM.
    func discardAll() {
        for run in runs { run.session.discard(waitingUpTo: 0.5) }
        runs.removeAll()
    }

    // MARK: Catalog and input

    func reloadActions(force: Bool = false) {
        let stamp = catalog.modificationDate()
        guard force || stamp != catalogStamp || actions.isEmpty else { return }
        catalogStamp = stamp
        actions = catalog.load()
    }

    var visibleActions: [PaceAction] {
        actions.filter { $0.matches(query: query) }
    }

    var visibleRuns: [ActionRun] {
        guard !query.isEmpty else { return runs }
        return runs.filter { $0.action.matches(query: query) }
    }

    /// Rows in display order, for arrow-key movement.
    var orderedSelections: [ActionsSelection] {
        visibleRuns.map { .run($0.id) } + visibleActions.map { .action($0.id) }
    }

    func action(id: String) -> PaceAction? { actions.first { $0.id == id } }
    func run(id: UUID) -> ActionRun? { runs.first { $0.id == id } }

    var summary: ActionInputSummary { input?.summary ?? ActionInputSummary() }

    /// Called whenever the panel shows Actions: reloads edited scripts and
    /// reads the clipboard, unless a history item was just handed over or
    /// the panel was already open on Actions.
    func preparePanel(refreshingInput: Bool = true) {
        reloadActions(force: true)
        if keepsInputOnNextOpen || !refreshingInput {
            keepsInputOnNextOpen = false
        } else {
            setInput(Self.clipboardInput(), origin: .clipboard)
        }
        if let pending = pendingSelection, pending.runID.map({ run(id: $0) != nil }) ?? true {
            pendingSelection = nil
            query = ""
            selection = pending
        } else {
            pendingSelection = nil
            selectDefault()
        }
    }

    func useHistoryItem(_ item: ClipboardItem) {
        let input = ActionInput(representations: item.representations, source: item.source)
        setInput(input, origin: .history(item.id))
        keepsInputOnNextOpen = true
        selectDefault()
    }

    private func setInput(_ actionInput: ActionInput?, origin: PanelActionInput.Origin) {
        sensitiveInputApproved = false
        guard let actionInput else {
            input = nil
            return
        }
        let summary = actionInput.summary
        let types = actionInput.representations.map(\.typeIdentifier)
        let thumbnail = Self.thumbnail(for: actionInput)
        input = PanelActionInput(
            input: actionInput,
            summary: summary,
            origin: origin,
            thumbnail: thumbnail?.image,
            pixelSize: thumbnail?.pixelSize,
            textPreview: actionInput.text.map { String($0.prefix(2_000)) },
            isSensitive: detector.isSensitive(typeIdentifiers: types, text: actionInput.text)
        )
    }

    /// The newest run when it still needs attention, else the first action
    /// that fits the input.
    func selectDefault() {
        if let latest = runs.first, latest.isRunning || latest.finishedAt.map({ Date().timeIntervalSince($0) < 60 }) == true {
            selection = .run(latest.id)
            return
        }
        selectFirstMatch()
    }

    func selectFirstMatch() {
        let summary = summary
        let candidates = visibleActions
        if let fitting = candidates.first(where: { $0.isRunnable && $0.accepts(summary) }) ?? candidates.first {
            selection = .action(fitting.id)
        } else {
            selection = visibleRuns.first.map { .run($0.id) }
        }
    }

    func moveSelection(_ delta: Int) {
        let rows = orderedSelections
        guard !rows.isEmpty else { return }
        let current = selection.flatMap { rows.firstIndex(of: $0) } ?? -1
        selection = rows[min(max(current + delta, 0), rows.count - 1)]
    }

    func selectEdge(last: Bool) {
        selection = last ? orderedSelections.last : orderedSelections.first
    }

    // MARK: Running

    /// Why `action` can't run on the current input, or nil when it can.
    func blockingReason(for action: PaceAction) -> String? {
        if let issue = action.issues.first { return issue }
        return action.unmetRequirementDescription(for: summary)
    }

    func run(_ action: PaceAction, argument: String) {
        guard blockingReason(for: action) == nil else { return }
        let input = input?.input ?? .empty
        let inputLabel = self.input?.label ?? "No input"
        let target = targetApplication
        let trimmedArgument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentTask = environmentTask
        if action.output != .panel {
            hidePanel()
            model.notify("Running \(action.title)…", style: .info, symbol: action.icon)
        }
        Task {
            let environment = await environmentTask?.value ?? LoginShellEnvironment.fallback()
            let session: ActionRunSession
            do {
                session = try await Task.detached(priority: .userInitiated) {
                    try ActionRunSession(
                        action: action,
                        input: input,
                        argument: trimmedArgument,
                        baseEnvironment: environment
                    )
                }.value
            } catch {
                model.notify("Couldn't run \(action.title). \(error.localizedDescription)", style: .error)
                return
            }
            let run = ActionRun(session: session, inputLabel: inputLabel, target: target)
            runs.insert(run, at: 0)
            trimRetainedRuns()
            if action.output == .panel { selection = .run(run.id) }
            start(run, step: .run)
        }
    }

    func confirm(_ run: ActionRun) {
        guard !run.isRunning, run.confirmTitle != nil, isListed(run) else { return }
        start(run, step: .confirm)
    }

    func undo(_ run: ActionRun) {
        guard !run.isRunning, run.undoTitle != nil, isListed(run) else { return }
        start(run, step: .undo)
    }

    /// A notice's button can outlive its run; say so instead of failing
    /// silently in a deleted run folder.
    private func isListed(_ run: ActionRun) -> Bool {
        guard runs.contains(where: { $0.id == run.id }) else {
            model.notify("That \(run.action.title) run was dismissed", style: .warning)
            return false
        }
        return true
    }

    func cancel(_ run: ActionRun) {
        run.session.cancel()
    }

    func dismiss(_ run: ActionRun) {
        let rows = orderedSelections
        if selection == .run(run.id), let index = rows.firstIndex(of: .run(run.id)) {
            let remaining = rows.filter { $0 != .run(run.id) }
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
        run.session.discard()
        runs.removeAll { $0.id == run.id }
    }

    private func start(_ run: ActionRun, step: ActionStep) {
        let stream = run.session.start(step)
        run.begin(step)
        Task {
            for await event in stream { run.apply(event) }
            finished(run)
        }
    }

    private func trimRetainedRuns() {
        let finished = runs.filter { !$0.isRunning }
        guard runs.count > Self.retainedRunLimit, !finished.isEmpty else { return }
        for run in finished.suffix(runs.count - Self.retainedRunLimit) {
            run.session.discard()
            runs.removeAll { $0.id == run.id }
        }
    }

    private func finished(_ run: ActionRun) {
        guard let result = run.result, runs.contains(where: { $0.id == run.id }) else { return }
        if run.confirmTitle == nil, run.undoTitle == nil { run.session.releaseInput() }
        let title = run.action.title
        let showsInPanel = isPanelShowingActions() && selection == .run(run.id)

        switch result.termination {
        case .cancelled:
            return
        case .exited(0):
            break
        default:
            guard !showsInPanel else { return }
            model.notify(
                "\(title) \(Self.failureSummary(result.termination))",
                style: .error,
                action: FeedbackAction(title: "Show") { [weak self] in self?.showRun(run.id) }
            )
            return
        }

        // Output modes apply to the first step; confirm and undo always
        // report back here.
        if result.step == .run, run.action.output != .panel {
            deliver(run)
            // A pending step still needs a way back to the run.
            guard run.confirmTitle != nil || run.undoTitle != nil else { return }
        }
        guard !showsInPanel else { return }
        if let undoTitle = run.undoTitle {
            model.notify(
                run.firstResultLine ?? "\(title) finished",
                symbol: run.action.icon,
                action: FeedbackAction(title: undoTitle) { [weak self] in self?.undo(run) }
            )
        } else if let confirmTitle = run.confirmTitle {
            model.notify(
                "\(title): \(confirmTitle)?",
                style: .info,
                symbol: run.action.icon,
                action: FeedbackAction(title: "Review") { [weak self] in self?.showRun(run.id) }
            )
        } else {
            model.notify(
                "\(title) finished",
                symbol: run.action.icon,
                action: FeedbackAction(title: "Show") { [weak self] in self?.showRun(run.id) }
            )
        }
    }

    /// Paste, copy, or silent actions finish without opening the panel. The
    /// run stays listed only when it left something to look at.
    private func deliver(_ run: ActionRun) {
        let text = run.resultText
        switch run.action.output {
        case .panel:
            return
        case .paste:
            guard !text.isEmpty else {
                model.notify("\(run.action.title) returned no text", style: .warning)
                return
            }
            Task { await model.pasteActionText(text, into: run.target) }
        case .copy:
            guard !text.isEmpty else {
                model.notify("\(run.action.title) returned no text", style: .warning)
                return
            }
            model.copyActionText(text, actionTitle: run.action.title)
        case .silent:
            model.notify(run.firstResultLine ?? "\(run.action.title) finished", symbol: run.action.icon)
        }
        if run.attachments.isEmpty, run.confirmTitle == nil, run.undoTitle == nil {
            dismiss(run)
        }
    }

    static func failureSummary(_ termination: ActionTermination) -> String {
        switch termination {
        case .exited(let status): return status == 0 ? "finished" : "failed (exit \(status))"
        case .signaled(let signal): return "was stopped (signal \(signal))"
        case .cancelled: return "was cancelled"
        case .timedOut: return "timed out"
        case .failedToLaunch(let message): return "couldn't start. \(message)"
        }
    }

    // MARK: Results

    func pasteResult(of run: ActionRun) {
        let text = run.resultText
        guard !text.isEmpty else { return }
        let target = targetApplication
        hidePanel()
        Task { await model.pasteActionText(text, into: target) }
    }

    func copyResult(of run: ActionRun) {
        let text = run.resultText
        if !text.isEmpty {
            hidePanel()
            model.copyActionText(text, actionTitle: run.action.title)
        } else if !run.attachments.isEmpty {
            copyAttachments(run.attachments, from: run)
        }
    }

    func copyAttachments(_ attachments: [ActionAttachment], from run: ActionRun) {
        hidePanel()
        model.copyActionFiles(attachments.map(\.url), actionTitle: run.action.title)
    }

    /// ⏎ on a finished run: confirm when offered, else paste the text, else
    /// open the first attachment.
    func performPrimary(on run: ActionRun) {
        guard !run.isRunning else { return }
        if run.confirmTitle != nil {
            confirm(run)
        } else if run.hasResultText {
            pasteResult(of: run)
        } else if let first = run.attachments.first {
            NSWorkspace.shared.open(first.url)
        }
    }

    func openActionsFolder() {
        try? catalog.createDirectoryIfNeeded()
        NSWorkspace.shared.open(catalog.directoryURL)
    }

    /// Opens the script in $VISUAL / $EDITOR, falling back to its default
    /// app (never a terminal, which would run it) when neither is set.
    func edit(_ action: PaceAction) {
        let environmentTask = environmentTask
        hidePanel()
        Task {
            let environment = await environmentTask?.value ?? LoginShellEnvironment.fallback()
            do {
                if try EditorLauncher.open(action.fileURL, environment: environment) { return }
            } catch {
                model.notify("Couldn't open $EDITOR. \(error.localizedDescription)", style: .error)
                return
            }
            openInDefaultEditor(action.fileURL)
        }
    }

    private func openInDefaultEditor(_ file: URL) {
        let terminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty"
        ]
        let editor = NSWorkspace.shared.urlForApplication(toOpen: file).flatMap { url in
            Bundle(url: url)?.bundleIdentifier.map(terminals.contains) == true ? nil : url
        }
        if editor == nil,
           let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            // Scripts usually open in Terminal, which would run them.
            NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    // MARK: Helpers

    private static func clipboardInput() -> ActionInput? {
        guard let snapshot = PasteboardSnapshot.capture() else { return nil }
        return ActionInput(representations: snapshot.representations, source: snapshot.source)
    }

    private static func thumbnail(for input: ActionInput) -> (image: NSImage, pixelSize: CGSize?)? {
        if let image = input.image {
            return downsampled(image.data, maxPixelSize: 600)
        }
        if let file = input.fileURLs.first {
            if UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
               let data = try? Data(contentsOf: file, options: .mappedIfSafe),
               let thumbnail = downsampled(data, maxPixelSize: 600) {
                return thumbnail
            }
            return (NSWorkspace.shared.icon(forFile: file.path), nil)
        }
        return nil
    }

    static func downsampled(_ data: Data, maxPixelSize: Int) -> (image: NSImage, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return (thumbnail, CGSize(width: width, height: height))
    }
}

/// Copies of action attachments that were put on the clipboard, kept in
/// Application Support so the clipboard and history entries keep working
/// after the run folder is gone. Old copies are pruned at launch.
enum ActionFileStore {
    static var directory: URL {
        PacePaths.applicationSupportDirectory.appendingPathComponent("Action Files", isDirectory: true)
    }

    static let retention: TimeInterval = 30 * 24 * 60 * 60

    static func keep(_ urls: [URL]) throws -> [URL] {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try urls.map { url in
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }
    }

    static func pruneOldCopies(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if now.timeIntervalSince(created) > retention { try? fileManager.removeItem(at: folder) }
        }
    }
}
