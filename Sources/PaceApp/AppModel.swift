import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import Foundation
import ImageIO
import PaceCore
import ServiceManagement

final class CachedItemImage {
    let image: NSImage
    let pixelSize: CGSize
    let cost: Int

    init(image: NSImage, pixelSize: CGSize, cost: Int) {
        self.image = image
        self.pixelSize = pixelSize
        self.cost = cost
    }
}

enum VaultState: Equatable {
    case locked
    case unlocking
    case unlocked
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var vaultState: VaultState = .locked
    @Published private(set) var records: [ClipboardRecord] = []
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var retentionPolicy: RetentionPolicy = .defaults
    @Published private(set) var storageBytes: Int64 = 0
    @Published var panelScope: PacePanelScope = .clipboard
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            searchTask?.cancel()
            searchTask = Task { await refresh(updateStorageSummary: false) }
        }
    }
    @Published var snippetQuery = "" {
        didSet {
            guard snippetQuery != oldValue else { return }
            snippetSearchTask?.cancel()
            snippetSearchTask = Task { await refreshSnippets() }
        }
    }
    @Published var capturePaused = false {
        didSet {
            guard capturePaused != oldValue else { return }
            if !capturePaused { cancelScheduledResume() }
            updateCaptureState()
        }
    }
    @Published private(set) var capturePausedUntil: Date?
    @Published var statusMessage: String?
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var hasAccessibilityAccess = AXIsProcessTrusted()
    @Published private(set) var hasPromptedForAccessibility = false

    private let store: HistoryStore
    private let snippetStore: SnippetStore
    private let keyStore = VaultKeyStore()
    private let detector = SensitiveContentDetector()
    private let ocrService = OCRService()
    private var monitor: ClipboardMonitor!
    private var expansionMonitor: SnippetExpansionMonitor!
    private var searchTask: Task<Void, Never>?
    private var snippetSearchTask: Task<Void, Never>?
    private var snippetCatalog: [Snippet] = []
    private var captureResumeTask: Task<Void, Never>?
    private let itemImageCache: NSCache<NSString, CachedItemImage> = {
        let cache = NSCache<NSString, CachedItemImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
    private let itemTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 200
        return cache
    }()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var securityGeneration = 0

    init(rootURL: URL = PacePaths.applicationSupportDirectory) {
        store = HistoryStore(rootURL: rootURL)
        snippetStore = SnippetStore(rootURL: rootURL)
        monitor = ClipboardMonitor { [weak self] snapshot in
            self?.capture(snapshot)
        }
        expansionMonitor = SnippetExpansionMonitor { [weak self] match in
            self?.expandSnippet(match)
        }

        Task { retentionPolicy = await store.retentionPolicy() }
    }

    func start() {
        refreshPermissions()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.lock() }
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.lock()
                    await self?.unlock()
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateExpansionState() }
            }
        )

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.lock() }
            }
        )
        distributedObservers.append(
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.unlock() }
            }
        )
    }

    func unlock() async {
        guard vaultState != .unlocking, vaultState != .unlocked else { return }
        let generation = securityGeneration
        vaultState = .unlocking
        do {
            let key = try keyStore.unlock()
            guard generation == securityGeneration else {
                vaultState = .locked
                return
            }
            try await store.unlock(with: key)
            try await snippetStore.unlock(with: key)
            guard generation == securityGeneration else {
                await store.lock()
                await snippetStore.lock()
                vaultState = .locked
                return
            }
            retentionPolicy = await store.retentionPolicy()
            vaultState = .unlocked
            updateCaptureState()
            // Text expansion should become available as soon as the vault is
            // open. A large clipboard catalog can take noticeably longer to
            // refresh and must not delay the global expansion listener.
            updateExpansionState()
            await refreshSnippets()
            await refresh()
        } catch {
            await store.lock()
            await snippetStore.lock()
            vaultState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func lock() async {
        securityGeneration += 1
        monitor.stop()
        expansionMonitor.stop()
        await store.lock()
        await snippetStore.lock()
        records = []
        snippets = []
        snippetCatalog = []
        storageBytes = 0
        // Decrypted content must not outlive the vault lock.
        itemImageCache.removeAllObjects()
        itemTextCache.removeAllObjects()
        vaultState = .locked
    }

    func pauseCapture(forMinutes minutes: Int) {
        captureResumeTask?.cancel()
        capturePausedUntil = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        capturePaused = true
        captureResumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.resumeCapture()
        }
    }

    func resumeCapture() {
        capturePaused = false
        cancelScheduledResume()
    }

    private func cancelScheduledResume() {
        captureResumeTask?.cancel()
        captureResumeTask = nil
        capturePausedUntil = nil
    }

    func refresh(updateStorageSummary: Bool = true) async {
        guard vaultState == .unlocked else { return }
        let requestedQuery = query
        do {
            let found = try await store.allRecords(query: requestedQuery, limit: 250)
            // A newer search may have started while this one was in flight.
            guard requestedQuery == query else { return }
            records = found
            if updateStorageSummary {
                storageBytes = try await store.storageSummary().bytes
            }
        } catch {
            if requestedQuery == query { statusMessage = error.localizedDescription }
        }
    }

    func refreshSnippets() async {
        guard vaultState == .unlocked else { return }
        let requestedQuery = snippetQuery
        do {
            let catalog = try await snippetStore.all(limit: 10_000)
            let found = SnippetSearchEngine.search(catalog, query: requestedQuery, limit: 250)
            guard vaultState == .unlocked else { return }
            // Expansion uses the full catalog and must not depend on whether
            // a concurrent UI search changed while this read was in flight.
            snippetCatalog = catalog
            let expansionSnippets = catalog.filter {
                $0.isExpansionEnabled && $0.keyword != nil
            }
            expansionMonitor.update(snippets: expansionSnippets)
            guard requestedQuery == snippetQuery else { return }
            snippets = found
        } catch {
            if requestedQuery == snippetQuery { statusMessage = error.localizedDescription }
        }
    }

    func refreshSnippetExpansionSettings() {
        updateExpansionState()
        Task { await refreshSnippets() }
    }

    func copy(_ record: ClipboardRecord, mode: ClipboardRestoreMode = .original) async {
        do {
            let item = try await store.item(id: record.id)
            try item.restore(mode: mode)
            monitor.acknowledgeCurrentClipboard()
            _ = try await store.recordUse(id: record.id)
            await refresh(updateStorageSummary: false)
            statusMessage = "Copied"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func paste(
        _ record: ClipboardRecord,
        mode: ClipboardRestoreMode = .original,
        into target: NSRunningApplication?
    ) async {
        do {
            let item = try await store.item(id: record.id)
            try item.restore(mode: mode)
            monitor.acknowledgeCurrentClipboard()
            try await synthesizePaste(
                into: target,
                imageContent: mode == .original && record.kind == .image
            )
            _ = try await store.recordUse(id: record.id)
            await refresh(updateStorageSummary: false)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func togglePin(_ record: ClipboardRecord) async {
        do {
            try await store.setPinned(id: record.id, pinned: !record.isPinned)
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func delete(_ record: ClipboardRecord) async {
        do {
            try await store.delete(id: record.id)
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func snippetDerived(from record: ClipboardRecord) -> Snippet? {
        snippetCatalog.first { $0.sourceRecordID == record.id }
    }

    func snippetForPromotion(from record: ClipboardRecord) async -> Snippet? {
        guard vaultState == .unlocked,
              let item = try? await store.item(id: record.id),
              let text = item.plainText ?? item.ocrText,
              !text.isEmpty else {
            statusMessage = "This clipboard item does not contain text that can become a snippet."
            return nil
        }
        let baseName = suggestedSnippetName(for: text, record: record)
        let existingNames = Set(snippetCatalog.map { $0.name.lowercased() })
        var name = baseName
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        let prefix = SnippetExpansionPreferences.defaultPrefix
        return Snippet(
            name: name,
            template: text,
            keyword: prefix.isEmpty ? nil : prefix,
            isExpansionEnabled: true,
            sourceRecordID: record.id
        )
    }

    @discardableResult
    func saveSnippet(_ snippet: Snippet) async -> Snippet? {
        do {
            do {
                _ = try SnippetTemplateRenderer.render(
                    snippet.template,
                    context: try await snippetRenderingContext()
                )
            } catch PaceError.notFound {
                // Dynamic clipboard entries and a referenced snippet can be
                // unavailable while editing; preserve the valid template so
                // it can resolve later when the context exists.
            }
            let saved = try await snippetStore.upsert(snippet)
            await refreshSnippets()
            restartExpansionMonitor()
            statusMessage = saved.keyword.map { "Saved as \($0)" } ?? "Snippet saved"
            return saved
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func deleteSnippet(_ snippet: Snippet) async {
        do {
            try await snippetStore.delete(id: snippet.id)
            await refreshSnippets()
            restartExpansionMonitor()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func toggleSnippetPin(_ snippet: Snippet) async {
        var edited = snippet
        edited.isPinned.toggle()
        _ = await saveSnippet(edited)
    }

    func toggleSnippetExpansion(_ snippet: Snippet) async {
        var edited = snippet
        edited.isExpansionEnabled.toggle()
        _ = await saveSnippet(edited)
    }

    func renderSnippet(_ snippet: Snippet) async throws -> RenderedSnippet {
        try SnippetTemplateRenderer.render(
            snippet.template,
            context: try await snippetRenderingContext()
        )
    }

    func pasteSnippet(_ snippet: Snippet, into target: NSRunningApplication?) async {
        do {
            _ = try await performPasteSnippet(snippet, into: target)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func copySnippet(_ snippet: Snippet) async {
        do {
            _ = try await performCopySnippet(snippet)
            statusMessage = "Copied"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func performPasteSnippet(
        _ snippet: Snippet,
        into target: NSRunningApplication?
    ) async throws -> RenderedSnippet {
        let rendered = try await renderSnippet(snippet)
        try await pasteRenderedSnippet(
            rendered,
            into: target,
            restoresClipboard: SnippetExpansionPreferences.restoresClipboard
        )
        _ = try await snippetStore.recordUse(id: snippet.id)
        await refreshSnippets()
        return rendered
    }

    private func performCopySnippet(_ snippet: Snippet) async throws -> RenderedSnippet {
        let rendered = try await renderSnippet(snippet)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(rendered.text, forType: .string)
        monitor.acknowledgeCurrentClipboard()
        _ = try await store.add(snippetOutputItem(rendered.text, snippet: snippet))
        _ = try await snippetStore.recordUse(id: snippet.id)
        await refresh()
        await refreshSnippets()
        return rendered
    }

    func updateRetention(_ policy: RetentionPolicy, pruneImmediately: Bool) async -> RetentionReport? {
        do {
            let report = try await store.setRetentionPolicy(policy, pruneImmediately: pruneImmediately)
            retentionPolicy = policy
            await refresh()
            return report
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func retentionPreview() async -> RetentionReport? {
        do { return try await store.retentionPreview() }
        catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func itemImage(for record: ClipboardRecord, maxPixelSize: CGFloat) async -> CachedItemImage? {
        guard record.kind == .image else { return nil }
        let key = "\(Int(maxPixelSize)):\(record.id.uuidString)" as NSString
        if let cached = itemImageCache.object(forKey: key) { return cached }
        guard vaultState == .unlocked,
              let item = try? await store.item(id: record.id),
              let data = Self.imageData(in: item.representations) else { return nil }
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.downsampledImage(from: data, maxPixelSize: maxPixelSize)
        }.value
        guard let loaded else { return nil }
        itemImageCache.setObject(loaded, forKey: key, cost: loaded.cost)
        return loaded
    }

    func itemDetailText(for record: ClipboardRecord) async -> String {
        let key = record.id.uuidString as NSString
        if let cached = itemTextCache.object(forKey: key) { return cached as String }
        guard vaultState == .unlocked,
              let item = try? await store.item(id: record.id) else { return record.preview }
        let text = item.plainText ?? item.ocrText ?? record.preview
        itemTextCache.setObject(text as NSString, forKey: key)
        return text
    }

    nonisolated private static func imageData(in representations: [ClipboardRepresentation]) -> Data? {
        for type in ["public.png", "public.jpeg", "public.tiff"] {
            if let data = representations.first(where: { $0.typeIdentifier == type })?.data {
                return data
            }
        }
        return nil
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> CachedItemImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelSize = CGSize(
            width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0,
            height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return CachedItemImage(
            image: NSImage(cgImage: thumbnail, size: .zero),
            pixelSize: pixelSize,
            cost: thumbnail.width * thumbnail.height * 4
        )
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            statusMessage = error.localizedDescription
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func refreshPermissions() {
        // AXIsProcessTrusted always checks this process. The CG preflight
        // (CGPreflightPostEventAccess) rides the current event's provenance,
        // so a check triggered from a Karabiner-synthesized keystroke is
        // evaluated against Karabiner — and reports access Pace doesn't have.
        hasAccessibilityAccess = AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() {
        refreshPermissions()
        guard !hasAccessibilityAccess else { return }

        // The consent dialog registers Pace in the Accessibility list and has
        // its own "Open System Settings" button, so the first request lets
        // the dialog drive — opening the pane from here as well races the
        // dialog. macOS shows the dialog at most once per launch (and never
        // after a denial); repeat requests open the pane directly instead.
        guard !hasPromptedForAccessibility else {
            openAccessibilitySettings()
            return
        }
        hasPromptedForAccessibility = true

        // On older macOS the prompt also registers the app in the
        // Accessibility list; current releases refuse prompt-based
        // registration ("Service kTCCServiceAccessibility does not allow
        // prompting") and only show an informational dialog, so the pane's
        // add button is the real path and the menu explains it.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        // The grant lands while the user works the dialog and Settings pane;
        // poll so the menu reflects it without another click.
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.refreshPermissions()
                if self.hasAccessibilityAccess { return }
            }
        }
    }

    private func openAccessibilitySettings() {
        let anchor = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: anchor), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app")
        )
    }

    func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.command {
            case .status:
                let policy = await store.retentionPolicy()
                let summary = vaultState == .unlocked ? try await store.storageSummary() : nil
                let snippetCount = vaultState == .unlocked
                    ? try await snippetStore.all(limit: 10_000).count
                    : nil
                return IPCResponse(
                    id: request.id,
                    success: true,
                    status: PaceStatus(
                        isUnlocked: vaultState == .unlocked,
                        isCapturePaused: capturePaused,
                        itemCount: summary?.items,
                        storageBytes: summary?.bytes,
                        snippetCount: snippetCount,
                        isSnippetExpansionEnabled: SnippetExpansionPreferences.isEnabled,
                        retentionPolicy: policy
                    )
                )

            case .unlock:
                await unlock()
                guard vaultState == .unlocked else {
                    throw PaceError.authenticationFailed(statusMessage ?? "Pace remains locked.")
                }
                return IPCResponse(id: request.id, success: true, message: "Pace unlocked.")

            case .lock:
                await lock()
                return IPCResponse(id: request.id, success: true, message: "Pace locked.")

            case .list, .search:
                let query = request.command == .search ? request.arguments["query"] ?? "" : ""
                let limit = Int(request.arguments["limit"] ?? "100") ?? 100
                let found = try await store.allRecords(query: query, limit: limit)
                return IPCResponse(id: request.id, success: true, records: found)

            case .get:
                let id = try itemID(from: request)
                return IPCResponse(id: request.id, success: true, item: try await store.item(id: id))

            case .add:
                let item = try makeCommandLineItem(from: request)
                let record = try await store.add(item)
                await refresh()
                if item.kind == .image, !record.hasOCR, let imageData = request.input {
                    scheduleOCR(for: record.id, imageData: imageData)
                }
                return IPCResponse(id: request.id, success: true, records: [record])

            case .copy, .paste:
                let id = try itemID(from: request)
                let item = try await store.item(id: id)
                let mode: ClipboardRestoreMode
                switch request.arguments["mode"] {
                case "plainText": mode = .plainText
                case "singleLine": mode = .trimmedSingleLine
                case "ocrText": mode = .ocrText
                default: mode = .original
                }
                let target = NSWorkspace.shared.frontmostApplication
                try item.restore(mode: mode)
                monitor.acknowledgeCurrentClipboard()
                if request.command == .paste {
                    try await synthesizePaste(
                        into: target,
                        imageContent: mode == .original && item.kind == .image
                    )
                }
                _ = try await store.recordUse(id: id)
                await refresh(updateStorageSummary: false)
                return IPCResponse(id: request.id, success: true, message: request.command == .paste ? "Pasted." : "Copied.")

            case .delete:
                try await store.delete(id: itemID(from: request))
                await refresh()
                return IPCResponse(id: request.id, success: true, message: "Deleted.")

            case .clear:
                try await store.clear()
                await refresh()
                return IPCResponse(id: request.id, success: true, message: "Clipboard history cleared.")

            case .pin:
                let id = try itemID(from: request)
                let pinned = request.arguments["value"] != "false"
                try await store.setPinned(id: id, pinned: pinned)
                await refresh()
                return IPCResponse(id: request.id, success: true, message: pinned ? "Pinned." : "Unpinned.")

            case .retentionShow:
                return IPCResponse(
                    id: request.id,
                    success: true,
                    retentionPolicy: await store.retentionPolicy()
                )

            case .retentionSet:
                let current = await store.retentionPolicy()
                let policy = try retentionPolicy(from: request.arguments, current: current)
                let prune = request.arguments["prune"] == "true"
                let report = try await store.setRetentionPolicy(policy, pruneImmediately: prune)
                retentionPolicy = policy
                await refresh()
                return IPCResponse(
                    id: request.id,
                    success: true,
                    retentionPolicy: policy,
                    retentionReport: report
                )

            case .retentionPreview:
                return IPCResponse(
                    id: request.id,
                    success: true,
                    retentionReport: try await store.retentionPreview()
                )

            case .retentionPrune:
                let report = try await store.pruneNow()
                await refresh()
                return IPCResponse(id: request.id, success: true, retentionReport: report)

            case .snippetList, .snippetSearch:
                let query = request.command == .snippetSearch
                    ? request.arguments["query"] ?? ""
                    : ""
                let limit = Int(request.arguments["limit"] ?? "100") ?? 100
                let found = try await snippetStore.all(query: query, limit: limit)
                return IPCResponse(id: request.id, success: true, snippets: found)

            case .snippetGet:
                return IPCResponse(
                    id: request.id,
                    success: true,
                    snippet: try await resolvedSnippet(from: request)
                )

            case .snippetAdd:
                let saved = try await validateAndSaveSnippet(makeCommandLineSnippet(from: request))
                return IPCResponse(
                    id: request.id,
                    success: true,
                    message: "Snippet created.",
                    snippet: saved
                )

            case .snippetUpdate:
                let existing = try await resolvedSnippet(from: request)
                let saved = try await validateAndSaveSnippet(
                    applyingSnippetChanges(from: request, to: existing)
                )
                return IPCResponse(
                    id: request.id,
                    success: true,
                    message: "Snippet updated.",
                    snippet: saved
                )

            case .snippetDelete:
                let snippet = try await resolvedSnippet(from: request)
                try await snippetStore.delete(id: snippet.id)
                await refreshSnippets()
                restartExpansionMonitor()
                return IPCResponse(id: request.id, success: true, message: "Snippet deleted.")

            case .snippetCopy:
                let snippet = try await resolvedSnippet(from: request)
                let rendered = try await performCopySnippet(snippet)
                return IPCResponse(
                    id: request.id,
                    success: true,
                    message: "Snippet copied.",
                    snippet: try await snippetStore.snippet(id: snippet.id),
                    renderedSnippet: rendered
                )

            case .snippetPaste:
                let snippet = try await resolvedSnippet(from: request)
                let target = NSWorkspace.shared.frontmostApplication
                let rendered = try await performPasteSnippet(snippet, into: target)
                return IPCResponse(
                    id: request.id,
                    success: true,
                    message: "Snippet pasted.",
                    snippet: try await snippetStore.snippet(id: snippet.id),
                    renderedSnippet: rendered
                )

            case .snippetRender:
                let rendered: RenderedSnippet
                if let template = try commandLineSnippetTemplate(from: request, required: false) {
                    rendered = try SnippetTemplateRenderer.render(
                        template,
                        context: try await snippetRenderingContext()
                    )
                } else {
                    rendered = try await renderSnippet(try await resolvedSnippet(from: request))
                }
                return IPCResponse(id: request.id, success: true, renderedSnippet: rendered)

            case .snippetPromote:
                let saved = try await promoteClipboardItemToSnippet(from: request)
                return IPCResponse(
                    id: request.id,
                    success: true,
                    message: "Clipboard item promoted to a snippet.",
                    snippet: saved
                )

            case .show:
                let scope: PacePanelScope
                switch request.arguments["scope"]?.lowercased() {
                case nil, "", "clipboard": scope = .clipboard
                case "snippet", "snippets": scope = .snippets
                default: throw PaceError.invalidArgument("--mode must be clipboard or snippets.")
                }
                AppRuntime.shared.showPanel(scope: scope)
                return IPCResponse(
                    id: request.id,
                    success: true,
                    message: "Pace \(scope.title.lowercased()) opened."
                )
            }
        } catch {
            return IPCResponse.failure(id: request.id, error: error)
        }
    }

    private func capture(_ snapshot: PasteboardSnapshot) {
        guard vaultState == .unlocked, !capturePaused else { return }
        if detector.isSensitive(typeIdentifiers: snapshot.typeIdentifiers, text: snapshot.plainText) {
            statusMessage = "Sensitive clipboard item not saved"
            return
        }

        let item = snapshot.makeItem()
        Task {
            do {
                let record = try await store.add(item)
                await refresh()
                if !record.hasOCR, let imageData = snapshot.imageData {
                    scheduleOCR(for: record.id, imageData: imageData)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func scheduleOCR(for id: UUID, imageData: Data) {
        Task {
            do {
                let observations = try await ocrService.recognizeText(in: imageData)
                guard !observations.isEmpty else { return }
                let recognizedText = observations.map(\.text).joined(separator: "\n")
                if detector.isSensitive(typeIdentifiers: [], text: recognizedText) {
                    try await store.delete(id: id)
                    statusMessage = "Image containing sensitive text was not retained"
                    await refresh()
                    return
                }
                try await store.updateOCR(id: id, observations: observations)
                await refresh()
            } catch {
                // OCR is best effort and never blocks capture.
            }
        }
    }

    private func updateCaptureState() {
        if vaultState == .unlocked, !capturePaused { monitor.start() }
        else { monitor.stop() }
    }

    private func updateExpansionState() {
        if vaultState == .unlocked, SnippetExpansionPreferences.isEnabled {
            expansionMonitor.start()
        } else {
            expansionMonitor.stop()
        }
    }

    private func restartExpansionMonitor() {
        if vaultState == .unlocked, SnippetExpansionPreferences.isEnabled {
            expansionMonitor.restart()
        } else {
            expansionMonitor.stop()
        }
    }

    private func expandSnippet(_ match: SnippetExpansionMonitor.Match) {
        Task { [weak self] in
            guard let self else { return }
            defer { self.expansionMonitor.finishMatch() }
            do {
                var rendered = try await self.renderSnippet(match.snippet)
                if let delimiter = match.delimiter {
                    rendered.text += delimiter
                }
                try await Task.sleep(
                    nanoseconds: UInt64(SnippetExpansionPreferences.injectionDelay * 1_000_000_000)
                )
                try self.synthesizeDelete(characterCount: match.triggerCharacterCount)
                try await self.pasteRenderedSnippet(
                    rendered,
                    into: match.targetApplication,
                    restoresClipboard: SnippetExpansionPreferences.restoresClipboard
                )
                _ = try await self.snippetStore.recordUse(id: match.snippet.id)
                await self.refreshSnippets()
            } catch {
                self.statusMessage = error.localizedDescription
                NSSound.beep()
            }
        }
    }

    private func snippetRenderingContext() async throws -> SnippetRenderingContext {
        let clipboardItems = try await store.textHistory(limit: 50)
        let allSnippets = try await snippetStore.all(limit: 10_000)
        return SnippetRenderingContext(
            clipboardItems: clipboardItems,
            snippetTemplates: Dictionary(uniqueKeysWithValues: allSnippets.map { ($0.name, $0.template) })
        )
    }

    private func pasteRenderedSnippet(
        _ rendered: RenderedSnippet,
        into target: NSRunningApplication?,
        restoresClipboard: Bool
    ) async throws {
        let pasteboard = NSPasteboard.general
        let priorContents = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(rendered.text, forType: .string)
        let renderedChangeCount = pasteboard.changeCount
        monitor.acknowledgeCurrentClipboard()
        try await synthesizePaste(into: target)
        if rendered.cursorMovementFromEnd > 0 {
            try await Task.sleep(nanoseconds: 45_000_000)
            try synthesizeLeftArrow(count: rendered.cursorMovementFromEnd)
        }
        guard restoresClipboard else { return }
        try await Task.sleep(nanoseconds: 260_000_000)
        guard pasteboard.changeCount == renderedChangeCount else { return }
        if let priorContents { priorContents.restore(to: pasteboard) }
        else { pasteboard.clearContents() }
        monitor.acknowledgeCurrentClipboard()
    }

    private func synthesizeDelete(characterCount: Int) throws {
        try synthesizeKey(keyCode: UInt16(kVK_Delete), count: characterCount)
    }

    private func synthesizeLeftArrow(count: Int) throws {
        try synthesizeKey(keyCode: UInt16(kVK_LeftArrow), count: count)
    }

    private func synthesizeKey(keyCode: UInt16, count: Int) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw PaceError.unavailable("Could not synthesize the snippet expansion.")
        }
        for _ in 0..<max(0, count) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                throw PaceError.unavailable("Could not synthesize the snippet expansion.")
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func suggestedSnippetName(for text: String, record: ClipboardRecord) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@"), !trimmed.contains(where: \ .isWhitespace), trimmed.count <= 100 {
            return "Email"
        }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        if record.kind == .image { return "OCR Snippet" }
        let firstLine = trimmed.split(whereSeparator: \ .isNewline).first.map(String.init) ?? "New Snippet"
        return firstLine
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .prefixString(48)
    }

    private func snippetOutputItem(_ text: String, snippet: Snippet) -> ClipboardItem {
        let data = Data(text.utf8)
        let sourceName = "Pace Snippet: \(snippet.name)"
        var item = ClipboardItem(
            source: ClipboardSource(
                kind: .application,
                name: sourceName,
                bundleIdentifier: Bundle.main.bundleIdentifier
            ),
            kind: .text,
            representations: [ClipboardRepresentation(
                typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                data: data
            )],
            preview: text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefixString(240),
            searchableText: "\(sourceName)\n\(text)",
            fingerprint: "",
            byteCount: Int64(data.count)
        )
        item.fingerprint = item.contentFingerprint
        return item
    }

    // Terminals can only take text through ⌘V, but several terminal programs
    // (Claude Code among them) read images off the clipboard themselves when
    // they receive a Ctrl+V keystroke — so image pastes into terminals use
    // Ctrl+V to deliver the actual image instead of the OCR-text fallback.
    private static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper"
    ]

    private func synthesizePaste(
        into target: NSRunningApplication?,
        imageContent: Bool = false
    ) async throws {
        refreshPermissions()
        guard hasAccessibilityAccess else {
            throw PaceError.unavailable(
                "Grant Accessibility access from the Pace menu bar icon to paste directly. The item is still on your clipboard."
            )
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let resolvedTarget = target ?? NSWorkspace.shared.frontmostApplication
            .flatMap { $0.processIdentifier == ownPID ? nil : $0 }

        resolvedTarget?.activate(options: [.activateIgnoringOtherApps])
        // A fixed delay races cold activations (e.g. the first paste after
        // launch, when Pace itself is still the active app): wait until the
        // target is actually frontmost before synthesizing the keystroke.
        if let resolvedTarget {
            var waitedMilliseconds = 0
            while NSWorkspace.shared.frontmostApplication?.processIdentifier
                    != resolvedTarget.processIdentifier,
                  waitedMilliseconds < 1_000 {
                try await Task.sleep(nanoseconds: 20_000_000)
                waitedMilliseconds += 20
            }
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw PaceError.unavailable("Could not synthesize paste. The item is still on your clipboard.")
        }
        let useControlV = imageContent
            && Self.terminalBundleIDs.contains(resolvedTarget?.bundleIdentifier ?? "")
        let flags: CGEventFlags = useControlV ? .maskControl : .maskCommand
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func resolvedSnippet(from request: IPCRequest) async throws -> Snippet {
        guard let identifier = request.arguments["identifier"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            throw PaceError.invalidArgument("A snippet ID, name, or keyword is required.")
        }
        if let id = UUID(uuidString: identifier) {
            return try await snippetStore.snippet(id: id)
        }

        let allSnippets = try await snippetStore.all(limit: 10_000)
        let lowercaseIdentifier = identifier.lowercased()
        let prefixMatches = allSnippets.filter {
            $0.id.uuidString.lowercased().hasPrefix(lowercaseIdentifier)
        }
        if prefixMatches.count == 1, let match = prefixMatches.first { return match }
        if prefixMatches.count > 1 {
            throw PaceError.invalidArgument("The snippet ID prefix “\(identifier)” is ambiguous.")
        }
        if let match = allSnippets.first(where: { $0.keyword == identifier }) { return match }
        if let match = allSnippets.first(where: {
            $0.name.compare(
                identifier,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) {
            return match
        }
        throw PaceError.notFound("Snippet “\(identifier)” was not found.")
    }

    private func makeCommandLineSnippet(from request: IPCRequest) throws -> Snippet {
        guard let name = request.arguments["name"] else {
            throw PaceError.invalidArgument("A snippet name is required.")
        }
        let keyword = request.arguments["keyword"]
        return Snippet(
            name: name,
            template: try commandLineSnippetTemplate(from: request, required: true) ?? "",
            keyword: keyword,
            tags: snippetTags(from: request.arguments["tags"]),
            isPinned: try commandLineBoolean(
                request.arguments["isPinned"],
                default: false,
                name: "isPinned"
            ),
            isExpansionEnabled: try commandLineBoolean(
                request.arguments["isExpansionEnabled"],
                default: keyword != nil,
                name: "isExpansionEnabled"
            )
        )
    }

    private func applyingSnippetChanges(
        from request: IPCRequest,
        to existing: Snippet
    ) throws -> Snippet {
        var snippet = existing
        if let name = request.arguments["name"] { snippet.name = name }
        if let template = try commandLineSnippetTemplate(from: request, required: false) {
            snippet.template = template
        }
        if request.arguments["clearKeyword"] == "true" {
            snippet.keyword = nil
            snippet.isExpansionEnabled = false
        } else if let keyword = request.arguments["keyword"] {
            snippet.keyword = keyword
        }
        if request.arguments["clearTags"] == "true" {
            snippet.tags = []
        } else if let tags = request.arguments["tags"] {
            snippet.tags = snippetTags(from: tags)
        }
        if let pinned = request.arguments["isPinned"] {
            snippet.isPinned = try commandLineBoolean(pinned, default: snippet.isPinned, name: "isPinned")
        }
        if let expansion = request.arguments["isExpansionEnabled"] {
            snippet.isExpansionEnabled = try commandLineBoolean(
                expansion,
                default: snippet.isExpansionEnabled,
                name: "isExpansionEnabled"
            )
        }
        return snippet
    }

    private func commandLineSnippetTemplate(
        from request: IPCRequest,
        required: Bool
    ) throws -> String? {
        guard let input = request.input else {
            if required { throw PaceError.invalidArgument("Snippet template text is required.") }
            return nil
        }
        guard let template = String(data: input, encoding: .utf8) else {
            throw PaceError.invalidArgument("Snippet template text must be UTF-8.")
        }
        return template
    }

    private func snippetTags(from rawValue: String?) -> [String] {
        guard let rawValue else { return [] }
        return rawValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    private func commandLineBoolean(
        _ rawValue: String?,
        default defaultValue: Bool,
        name: String
    ) throws -> Bool {
        guard let rawValue else { return defaultValue }
        switch rawValue.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: throw PaceError.invalidArgument("Invalid boolean value for \(name): \(rawValue).")
        }
    }

    private func validateAndSaveSnippet(_ snippet: Snippet) async throws -> Snippet {
        do {
            _ = try SnippetTemplateRenderer.render(
                snippet.template,
                context: try await snippetRenderingContext()
            )
        } catch PaceError.notFound {
            // Clipboard offsets and nested references may become available
            // later; retain templates that are otherwise syntactically valid.
        }
        let saved = try await snippetStore.upsert(snippet)
        await refreshSnippets()
        restartExpansionMonitor()
        return saved
    }

    private func promoteClipboardItemToSnippet(from request: IPCRequest) async throws -> Snippet {
        guard let value = request.arguments["clipboardID"],
              let id = UUID(uuidString: value) else {
            throw PaceError.invalidArgument("A full clipboard item UUID is required.")
        }
        let allSnippets = try await snippetStore.all(limit: 10_000)
        if let existing = allSnippets.first(where: { $0.sourceRecordID == id }) {
            return try await validateAndSaveSnippet(
                applyingSnippetChanges(from: request, to: existing)
            )
        }

        let item = try await store.item(id: id)
        guard let text = item.plainText ?? item.ocrText, !text.isEmpty else {
            throw PaceError.invalidArgument(
                "This clipboard item does not contain text that can become a snippet."
            )
        }
        let record = ClipboardRecord(item: item)
        let baseName = suggestedSnippetName(for: text, record: record)
        let existingNames = Set(allSnippets.map { $0.name.lowercased() })
        var name = baseName
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        let proposed = Snippet(
            name: name,
            template: text,
            keyword: nil,
            isExpansionEnabled: false,
            sourceRecordID: id
        )
        return try await validateAndSaveSnippet(
            applyingSnippetChanges(from: request, to: proposed)
        )
    }

    private func itemID(from request: IPCRequest) throws -> UUID {
        guard let value = request.arguments["id"], let id = UUID(uuidString: value) else {
            throw PaceError.invalidArgument("A valid clipboard item ID is required.")
        }
        return id
    }

    private func makeCommandLineItem(from request: IPCRequest) throws -> ClipboardItem {
        guard let input = request.input else {
            throw PaceError.invalidArgument("No clipboard content was provided.")
        }
        let contentType = request.arguments["contentType"] ?? "public.utf8-plain-text"
        let imageTypes: Set<String> = ["public.png", "public.jpeg", "public.tiff", "public.image"]
        let kind: ClipboardContentKind = contentType.hasPrefix("image/") || imageTypes.contains(contentType)
            ? .image
            : .text
        let text = kind == .text ? String(data: input, encoding: .utf8) : nil
        if detector.isSensitive(typeIdentifiers: [contentType], text: text) {
            throw PaceError.invalidArgument("The content appears sensitive and was not stored.")
        }
        let sourceName = request.arguments["source"] ?? "Pace CLI"
        let session = request.arguments["session"]
        let preview = text?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefixString(240) ?? "Image"
        let sourceKind: ClipboardSource.Kind
        switch request.arguments["sourceKind"] {
        case "application": sourceKind = .application
        case "agent": sourceKind = .agent
        default: sourceKind = sourceName == "Pace CLI" ? .commandLine : .agent
        }
        let source = ClipboardSource(
            kind: sourceKind,
            name: sourceName,
            sessionIdentifier: session
        )
        var copiedAt = Date()
        if let rawTimestamp = request.arguments["timestamp"] {
            guard let epoch = Double(rawTimestamp) else {
                throw PaceError.invalidArgument("Invalid --timestamp; use Unix epoch seconds.")
            }
            copiedAt = Date(timeIntervalSince1970: epoch)
        }
        var item = ClipboardItem(
            createdAt: copiedAt,
            lastCopiedAt: copiedAt,
            source: source,
            kind: kind,
            representations: [ClipboardRepresentation(typeIdentifier: contentType, data: input)],
            preview: preview,
            searchableText: [preview, sourceName, text ?? ""].joined(separator: "\n"),
            fingerprint: "",
            byteCount: Int64(input.count)
        )
        item.fingerprint = item.contentFingerprint
        return item
    }

    private func retentionPolicy(
        from arguments: [String: String],
        current: RetentionPolicy
    ) throws -> RetentionPolicy {
        func intValue(_ key: String, current: Int?) throws -> Int? {
            guard let value = arguments[key] else { return current }
            if value == "unlimited" { return nil }
            guard let parsed = Int(value) else { throw PaceError.invalidArgument("Invalid value for \(key).") }
            return parsed
        }
        func int64Value(_ key: String, current: Int64?) throws -> Int64? {
            guard let value = arguments[key] else { return current }
            if value == "unlimited" { return nil }
            guard let parsed = Int64(value) else { throw PaceError.invalidArgument("Invalid value for \(key).") }
            return parsed
        }
        return try RetentionPolicy(
            maximumAgeDays: try intValue("days", current: current.maximumAgeDays),
            maximumItemCount: try intValue("items", current: current.maximumItemCount),
            maximumStorageBytes: try int64Value("bytes", current: current.maximumStorageBytes),
            protectsPinnedItems: arguments["protectPinned"].map { $0 != "false" } ?? current.protectsPinnedItems
        ).validated()
    }
}
