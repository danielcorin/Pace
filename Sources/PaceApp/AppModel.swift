import AppKit
import ApplicationServices
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
    @Published private(set) var retentionPolicy: RetentionPolicy = .defaults
    @Published private(set) var storageBytes: Int64 = 0
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            searchTask?.cancel()
            searchTask = Task { await refresh(updateStorageSummary: false) }
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
    @Published var pasteTargetName: String?
    @Published var statusMessage: String?
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private let store: HistoryStore
    private let keyStore = VaultKeyStore()
    private let detector = SensitiveContentDetector()
    private let ocrService = OCRService()
    private var monitor: ClipboardMonitor!
    private var searchTask: Task<Void, Never>?
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
        monitor = ClipboardMonitor { [weak self] snapshot in
            self?.capture(snapshot)
        }

        Task { retentionPolicy = await store.retentionPolicy() }
    }

    func start() {
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
            guard generation == securityGeneration else {
                await store.lock()
                vaultState = .locked
                return
            }
            retentionPolicy = await store.retentionPolicy()
            vaultState = .unlocked
            updateCaptureState()
            await refresh()
        } catch {
            vaultState = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    func lock() async {
        securityGeneration += 1
        monitor.stop()
        await store.lock()
        records = []
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

    func copy(_ record: ClipboardRecord, mode: ClipboardRestoreMode = .original) async {
        do {
            let item = try await store.item(id: record.id)
            try item.restore(mode: mode)
            monitor.acknowledgeCurrentClipboard()
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

    func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.command {
            case .status:
                let policy = await store.retentionPolicy()
                let summary = vaultState == .unlocked ? try await store.storageSummary() : nil
                return IPCResponse(
                    id: request.id,
                    success: true,
                    status: PaceStatus(
                        isUnlocked: vaultState == .unlocked,
                        isCapturePaused: capturePaused,
                        itemCount: summary?.items,
                        storageBytes: summary?.bytes,
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

            case .show:
                AppRuntime.shared.showPanel()
                return IPCResponse(id: request.id, success: true, message: "Pace panel opened.")
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw PaceError.unavailable(
                "Enable Pace in System Settings → Privacy & Security → Accessibility to paste directly. The item is still on your clipboard."
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
