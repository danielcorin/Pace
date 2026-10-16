import AppKit
import Combine
import PaceCore
import QuickLookUI
import SwiftUI

private final class PacePanel: NSPanel {
    weak var quickLookController: ImageQuickLookController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookController?.hasItem == true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        quickLookController?.configure(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        quickLookController?.relinquish(panel)
    }
}

extension Notification.Name {
    static let paceHistoryPanelDidShow = Notification.Name("PaceHistoryPanelDidShow")
    static let paceOpenSettings = Notification.Name("PaceOpenSettings")
    static let pacePanelEscapePressed = Notification.Name("PacePanelEscapePressed")
}

// Relays ⌘, from the panel's key monitor to the openSettings environment
// action, which is only reachable from inside a view.
@available(macOS 14.0, *)
private struct SettingsShortcutBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .paceOpenSettings)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }
}

private struct SnippetEditorDraft: Equatable {
    var snippet: Snippet
    var tagsText: String
    var isNew: Bool

    init(snippet: Snippet, isNew: Bool = false) {
        self.snippet = snippet
        tagsText = snippet.tags.joined(separator: ", ")
        self.isNew = isNew
    }

    var resolvedSnippet: Snippet {
        var resolved = snippet
        let keyword = snippet.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeholderPrefix = SnippetExpansionPreferences.defaultPrefix
        resolved.keyword = keyword.isEmpty || keyword == placeholderPrefix ? nil : keyword
        resolved.isExpansionEnabled = resolved.keyword != nil && snippet.isExpansionEnabled
        resolved.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return resolved
    }
}

private enum PanelMotion {
    static let showDuration: TimeInterval = 0.18
    static let hideDuration: TimeInterval = 0.1
    static let showScale: CGFloat = 0.97
}

private enum PanelMetrics {
    static let width: CGFloat = 760
    static let listWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 16
    static let searchHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 1
    static let listUnitHeight: CGFloat = 48
    static let pausedBannerHeight: CGFloat = 30
    static let minimumVisibleUnits = 5
    static let maximumVisibleUnits = 8

    static func visibleUnitCount(contentUnitCount: Int) -> Int {
        min(
            max(contentUnitCount, minimumVisibleUnits),
            maximumVisibleUnits
        )
    }

    // The paused banner adds its own height rather than taking a row's, so
    // the list keeps an exact grid of visible units for the ⌘-number slots.
    static func preferredHeight(contentUnitCount: Int, showsPausedBanner: Bool = false) -> CGFloat {
        let visibleUnits = visibleUnitCount(contentUnitCount: contentUnitCount)
        return searchHeight
            + dividerHeight
            + (showsPausedBanner ? pausedBannerHeight + dividerHeight : 0)
            + CGFloat(visibleUnits) * listUnitHeight
    }
}

@MainActor
final class HistoryPanelCoordinator {
    private let model: AppModel
    private let quickLookController = ImageQuickLookController()
    private var panel: PacePanel?
    private var targetApplication: NSRunningApplication?
    private var wantsVisible = false
    private var hideGeneration = 0
    private var keyObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        quickLookController.onDismiss = { [weak self] in
            self?.restoreFocusAfterQuickLook()
        }
        model.$vaultState
            .sink { [weak self] state in
                guard state != .unlocked else { return }
                self?.quickLookController.close()
            }
            .store(in: &cancellables)
    }

    // A panel fading out still reports isVisible to AppKit; it counts as
    // hidden here so the hotkey reopens it instead of hiding it twice.
    var isVisible: Bool { wantsVisible && panel?.isVisible == true }

    func toggle(scope: PacePanelScope) {
        if isVisible, model.panelScope == scope { hide(animated: true) }
        else { show(scope: scope) }
    }

    func show(scope: PacePanelScope = .clipboard) {
        // Reopening mid-fade completes the pending hide first, so the panel
        // comes back through the same fresh-open path.
        if !wantsVisible, panel?.isVisible == true { finishHiding() }
        wantsVisible = true
        model.panelScope = scope
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApplication = frontmost
        }
        // Unlocking needs no user interaction; never surface a locked panel.
        if model.vaultState == .locked {
            Task { await model.unlock() }
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let showsPausedBanner = scope == .clipboard && model.capturePaused && !model.records.isEmpty
        resizePanel(
            to: PanelMetrics.preferredHeight(
                contentUnitCount: scope == .clipboard ? model.records.count : model.snippets.count,
                showsPausedBanner: showsPausedBanner
            )
        )
        position(panel)
        let wasVisible = panel.isVisible
        if !wasVisible { panel.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible { animateIn(panel) }
        // Post on the next turn: on the very first show the SwiftUI view may
        // not have attached its onReceive subscriber yet, and a synchronous
        // post is missed — leaving the search field unfocused.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .paceHistoryPanelDidShow, object: nil)
        }
    }

    /// Paste and copy hide without animation so focus returns to the target
    /// app at once; dismissals fade out.
    func hide(animated: Bool = false) {
        wantsVisible = false
        quickLookController.close()
        hideGeneration &+= 1
        guard animated, let panel, panel.isVisible else {
            finishHiding()
            return
        }
        let generation = hideGeneration
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.hideDuration) { [weak self] in
            guard let self, self.hideGeneration == generation, !self.wantsVisible else { return }
            self.finishHiding()
        }
    }

    private func finishHiding() {
        hideGeneration &+= 1
        if let panel {
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        }
        model.query = ""
        model.snippetQuery = ""
    }

    // Purely visual: the panel is already key and taking input, so neither
    // the fade nor the scale delays typing or the paste flow.
    private func animateIn(_ panel: PacePanel) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.showDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        guard !reduceMotion, let layer = panel.contentView?.layer else { return }
        // Scale about the center regardless of where AppKit put the anchor.
        let bounds = layer.bounds
        let center = CGPoint(
            x: bounds.midX - layer.anchorPoint.x * bounds.width,
            y: bounds.midY - layer.anchorPoint.y * bounds.height
        )
        let scale = PanelMotion.showScale
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, scale, scale, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 420
        spring.damping = 36
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "paceShowScale")
    }

    private func makePanel() -> PacePanel {
        // Borderless: a titled window's frame kept re-inflating by the
        // title-bar height at display time, leaving a dead strip of window
        // background below the content. With no title bar, frame == content
        // rect always; the SwiftUI root draws its own rounded corners.
        let panel = PacePanel(
            contentRect: NSRect(
                origin: .zero,
                size: CGSize(
                    width: PanelMetrics.width,
                    height: PanelMetrics.preferredHeight(contentUnitCount: model.records.count)
                )
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.quickLookController = quickLookController

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelDidResignKey() }
        }

        // Escape must close the panel no matter what has focus; onExitCommand
        // only fires when the focused view routes the cancel action to it.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel?.isKeyWindow == true else { return event }
            NotificationCenter.default.post(name: .pacePanelEscapePressed, object: nil)
            return nil
        }

        let root = HistoryView(
            onPaste: { [weak self] record, mode in
                guard let self else { return }
                let target = self.targetApplication
                self.hide()
                Task { await self.model.paste(record, mode: mode, into: target) }
            },
            onCopy: { [weak self] record, mode in
                guard let self else { return }
                self.hide()
                Task { await self.model.copy(record, mode: mode) }
            },
            onQuickLook: { [weak self] record in
                guard let self else { return }
                self.quickLookController.toggle(record: record, model: self.model)
            },
            onPasteSnippet: { [weak self] snippet in
                guard let self else { return }
                let target = self.targetApplication
                self.hide()
                Task { await self.model.pasteSnippet(snippet, into: target) }
            },
            onCopySnippet: { [weak self] snippet in
                guard let self else { return }
                self.hide()
                Task { await self.model.copySnippet(snippet) }
            },
            onUnlock: { [weak self] in self?.unlockAndRestorePanel() },
            onClose: { [weak self] in self?.hide(animated: true) },
            onPreferredHeightChange: { [weak self] height in
                self?.resizePanel(to: height)
            }
        )
        .environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        // The root reports its preferred height explicitly; don't let the
        // hosting view install competing window-sizing constraints.
        hosting.sizingOptions = []
        // Layer-backed so the open animation can scale the content.
        hosting.wantsLayer = true
        panel.contentView = hosting
        return panel
    }

    private func panelDidResignKey() {
        guard wantsVisible else { return }
        // Quick Look is an auxiliary panel; keep the history visible behind it.
        guard !quickLookController.isVisible else { return }
        // Don't dismiss while an unlock is still settling.
        guard model.vaultState != .unlocking else { return }
        hide(animated: true)
    }

    private func restoreFocusAfterQuickLook() {
        guard wantsVisible, let panel, panel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func unlockAndRestorePanel() {
        Task { [weak self] in
            guard let self else { return }
            await model.unlock()
            guard wantsVisible, model.vaultState == .unlocked, let panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func resizePanel(to height: CGFloat) {
        guard let panel, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func position(_ panel: NSPanel) {
        let screen = targetApplication.flatMap { _ in NSScreen.main }
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let x = visibleFrame.midX - panel.frame.width / 2
        let y = visibleFrame.maxY - panel.frame.height - min(90, visibleFrame.height * 0.12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct HistoryView: View {
    private static let deletionAnimationDuration = 0.16

    private struct PendingDeletion {
        let deletedID: UUID
        let replacementID: UUID?
    }

    private struct PendingSnippetConfiguration {
        let snippet: Snippet
        let prefillKeyword: Bool
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var selection: UUID?
    @State private var lastFirstID: UUID?
    @State private var lastQuery = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionSelectionTransferScheduled = false
    @State private var shortcutKeyMonitor: Any?
    @State private var snippetSelection: UUID?
    @State private var lastSnippetFirstID: UUID?
    @State private var lastSnippetQuery = ""
    @State private var snippetEditorDraft: SnippetEditorDraft?
    @State private var snippetEditorError: String?
    @State private var pendingSnippetConfiguration: PendingSnippetConfiguration?
    @StateObject private var listScroll = ScrollViewHandle()
    @StateObject private var snippetListScroll = ScrollViewHandle()

    var onPaste: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onCopy: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onQuickLook: (ClipboardRecord) -> Void
    var onPasteSnippet: (Snippet) -> Void
    var onCopySnippet: (Snippet) -> Void
    var onUnlock: () -> Void
    var onClose: () -> Void
    var onPreferredHeightChange: (CGFloat) -> Void

    private var listContentUnitCount: Int {
        if snippetEditorDraft != nil { return PanelMetrics.maximumVisibleUnits }
        switch model.panelScope {
        case .clipboard: return model.records.count
        case .snippets: return model.snippets.count
        }
    }

    private var visibleListUnitCount: Int {
        PanelMetrics.visibleUnitCount(contentUnitCount: listContentUnitCount)
    }

    private var preferredPanelHeight: CGFloat {
        PanelMetrics.preferredHeight(
            contentUnitCount: listContentUnitCount,
            showsPausedBanner: showsPausedBanner
        )
    }

    // An empty history shows the paused state in place of the list instead.
    private var showsPausedBanner: Bool {
        model.panelScope == .clipboard && model.capturePaused && !model.records.isEmpty
    }

    // Terms the current search matched on, for row highlighting. Filter
    // tokens such as type: and app: are not part of the text.
    private var searchTerms: [String] {
        SearchQuery(model.query).text
            .split(separator: " ")
            .map(String.init)
    }

    var body: some View {
        Group {
            switch model.vaultState {
            case .locked, .unlocking:
                lockedView
            case .failed(let message):
                failedView(message)
            case .unlocked:
                unlockedView
            }
        }
        .frame(width: PanelMetrics.width, height: preferredPanelHeight)
        .background {
            ZStack {
                PanelBackdrop(cornerRadius: PanelMetrics.cornerRadius)
                // Mostly-opaque wash so a bright backdrop can't dilute the
                // panel; the sliver of vibrancy left keeps it feeling native.
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .ignoresSafeArea()
        .background {
            if #available(macOS 14.0, *) {
                SettingsShortcutBridge()
            }
        }
        .onExitCommand(perform: onClose)
        .onReceive(NotificationCenter.default.publisher(for: .pacePanelEscapePressed)) { _ in
            if snippetEditorDraft != nil {
                cancelSnippetEditor()
            } else {
                onClose()
            }
        }
        .onChange(of: model.panelScope) { scope in
            if scope == .snippets, pendingSnippetConfiguration != nil {
                presentPendingSnippetConfiguration()
            } else {
                cancelSnippetEditor()
            }
            DispatchQueue.main.async { searchFocused = snippetEditorDraft == nil }
        }
        .onAppear {
            onPreferredHeightChange(preferredPanelHeight)
        }
        .onChange(of: preferredPanelHeight) { height in
            onPreferredHeightChange(height)
        }
    }

    private var lockedView: some View {
        UnlockingView()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.lock.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Pace remains locked").font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again", action: onUnlock)
                .buttonStyle(.borderedProminent)
        }
    }

    private var selectedRecord: ClipboardRecord? {
        if let record = selection.flatMap({ id in model.records.first { $0.id == id } }) {
            return record
        }
        guard let pendingDeletion, selection == pendingDeletion.deletedID else { return nil }
        return pendingDeletion.replacementID.flatMap { replacementID in
            model.records.first { $0.id == replacementID }
        } ?? model.records.first
    }

    private var selectedSnippet: Snippet? {
        snippetSelection.flatMap { id in model.snippets.first { $0.id == id } }
            ?? model.snippets.first
    }

    private struct NumberedSlot {
        let number: Int
        let index: Int
        let record: ClipboardRecord
    }

    private struct NumberedSnippetSlot {
        let number: Int
        let index: Int
        let snippet: Snippet
    }

    // ⌘1…⌘9 belong to on-screen slots rather than to records: scrolling
    // hands each number to whichever row crosses its slot's center, making
    // the pick a purely visual one. Every row is one fixed-height unit, so
    // the list is an exact grid and any scroll offset maps back to the
    // record occupying each slot.
    private var numberedVisibleSlots: [NumberedSlot] {
        let records = model.records
        guard !records.isEmpty else { return [] }
        let unitHeight = PanelMetrics.listUnitHeight
        let offset = max(listScroll.scrollOffset, 0)
        // The row occupying the majority of the top slot.
        let baseIndex = Int(((offset + unitHeight / 2) / unitHeight).rounded(.down))
        var numbered: [NumberedSlot] = []
        for slot in 0..<visibleListUnitCount {
            let number = slot + 1
            guard number <= 9 else { break }
            let index = baseIndex + slot
            guard index >= 0, index < records.count else { break }
            numbered.append(NumberedSlot(number: number, index: index, record: records[index]))
        }
        return numbered
    }

    private var numberedVisibleSnippetSlots: [NumberedSnippetSlot] {
        let snippets = model.snippets
        guard !snippets.isEmpty else { return [] }
        let unitHeight = PanelMetrics.listUnitHeight
        let offset = max(snippetListScroll.scrollOffset, 0)
        let baseIndex = Int(((offset + unitHeight / 2) / unitHeight).rounded(.down))
        var numbered: [NumberedSnippetSlot] = []
        for slot in 0..<visibleListUnitCount {
            let number = slot + 1
            guard number <= 9 else { break }
            let index = baseIndex + slot
            guard index >= 0, index < snippets.count else { break }
            numbered.append(NumberedSnippetSlot(number: number, index: index, snippet: snippets[index]))
        }
        return numbered
    }

    @ViewBuilder
    private var unlockedView: some View {
        switch model.panelScope {
        case .clipboard: clipboardView
        case .snippets: snippetsView
        }
    }

    private var clipboardView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                scopePicker
                Divider().frame(height: 18)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    // The field's own placeholder is drawn by the cell when
                    // idle but by the field editor when focused, which sits
                    // one pixel higher at this font size. Drawing it here
                    // keeps it stable across focus changes.
                    if model.query.isEmpty {
                        Text("Search clipboard history")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onSubmit { performPaste(mode: .original) }
                        .accessibilityLabel("Search clipboard history")
                }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear Search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()
                .frame(height: PanelMetrics.dividerHeight)

            if showsPausedBanner {
                pausedBanner
                Divider()
                    .frame(height: PanelMetrics.dividerHeight)
            }

            if model.records.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    recordList
                        .frame(width: PanelMetrics.listWidth)
                    Divider()
                    DetailPane(
                        record: selectedRecord,
                        derivedSnippet: selectedRecord.flatMap(model.snippetDerived),
                        onQuickLook: onQuickLook,
                        onSaveAsSnippet: { beginPromotion($0) },
                        onOpenSnippet: openSnippet
                    )
                }
            }
        }
        .overlay {
            Button("") { moveSelection(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { moveSelection(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            ForEach(1...9, id: \.self) { number in
                Button("") { pasteNumbered(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            searchFocused = true
            selectFirstIfNeeded()
            installShortcutMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paceHistoryPanelDidShow)) { _ in
            searchFocused = true
            selectFirstIfNeeded()
        }
        .onChange(of: model.records) { _ in recordsDidChange() }
    }

    private var scopePicker: some View {
        Menu {
            ForEach(PacePanelScope.allCases) { scope in
                Button {
                    model.panelScope = scope
                } label: {
                    Label(scope.title, systemImage: scope.systemImage)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.panelScope.systemImage)
                Text(model.panelScope.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(snippetEditorDraft != nil)
    }

    private var snippetsView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                scopePicker
                Divider().frame(height: 18)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    if model.snippetQuery.isEmpty {
                        Text("Search snippets")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $model.snippetQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searchFocused)
                        .onSubmit { pasteSelectedSnippet() }
                        .accessibilityLabel("Search snippets")
                        .disabled(snippetEditorDraft != nil)
                }
                if !model.snippetQuery.isEmpty, snippetEditorDraft == nil {
                    Button { model.snippetQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear Search")
                    .accessibilityLabel("Clear search")
                }
                Button { beginNewSnippet() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Snippet (⌘N)")
                .disabled(snippetEditorDraft != nil)
            }
            .padding(.horizontal, 14)
            .frame(height: PanelMetrics.searchHeight)

            Divider().frame(height: PanelMetrics.dividerHeight)

            if model.snippets.isEmpty, snippetEditorDraft == nil {
                snippetEmptyState
            } else {
                HStack(spacing: 0) {
                    snippetList
                        .frame(width: PanelMetrics.listWidth)
                    Divider()
                    if snippetEditorDraft != nil {
                        snippetEditorPane
                    } else {
                        SnippetDetailPane(
                            snippet: selectedSnippet,
                            onEdit: beginEditingSnippet
                        )
                    }
                }
            }
        }
        .overlay {
            Button("") { moveSelection(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { moveSelection(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            ForEach(1...9, id: \.self) { number in
                Button("") { pasteNumberedSnippet(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            searchFocused = true
            selectFirstSnippetIfNeeded()
            installShortcutMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paceHistoryPanelDidShow)) { _ in
            searchFocused = snippetEditorDraft == nil
            selectFirstSnippetIfNeeded()
        }
        .onChange(of: model.snippets) { _ in snippetsDidChange() }
    }

    private var snippetEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.snippetQuery.isEmpty ? "text.quote" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.snippetQuery.isEmpty ? "No Snippets" : "No Results")
                .font(.headline)
            Text(model.snippetQuery.isEmpty
                ? "Save something useful from Clipboard, or create a snippet."
                : "Try a different search.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.snippetQuery.isEmpty {
                Button("New Snippet") { beginNewSnippet() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var snippetList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.snippets, id: \.id) { snippet in
                    snippetRow(snippet)
                }
            }
            .background(OverlayScrollerStyle(handle: snippetListScroll))
        }
        .animation(
            model.snippetQuery == lastSnippetQuery && lastSnippetFirstID != nil && !reduceMotion
                ? .spring(response: 0.3, dampingFraction: 0.86)
                : nil,
            value: model.snippets.map(\.id)
        )
        .overlay(alignment: .topTrailing) { snippetShortcutBadgeRail }
        .onChange(of: snippetSelection) { selected in
            guard let selected,
                  let index = model.snippets.firstIndex(where: { $0.id == selected }) else { return }
            snippetListScroll.scrollUnitIntoView(index, unitHeight: PanelMetrics.listUnitHeight)
        }
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        SnippetRow(snippet: snippet)
            .padding(.leading, 12)
            .padding(.trailing, 44)
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.listUnitHeight)
            .modifier(RowHighlight(isSelected: snippetSelection == snippet.id))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onPasteSnippet(snippet) }
            .simultaneousGesture(TapGesture().onEnded { snippetSelection = snippet.id })
            .contextMenu {
                Button("Paste") { onPasteSnippet(snippet) }
                    .keyboardShortcut(contextMenuHint(.paste))
                Button("Copy") { onCopySnippet(snippet) }
                    .keyboardShortcut(contextMenuHint(.copy))
                Divider()
                Button("Edit…") { beginEditingSnippet(snippet) }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Duplicate") { duplicateSnippet(snippet) }
                    .keyboardShortcut("d", modifiers: .command)
                Button(snippet.isExpansionEnabled ? "Disable Expansion" : "Enable Expansion") {
                    Task { await model.toggleSnippetExpansion(snippet) }
                }
                .disabled(snippet.keyword == nil)
                Button(snippet.isPinned ? "Unpin" : "Pin") {
                    Task { await model.toggleSnippetPin(snippet) }
                }
                Divider()
                Button("Delete", role: .destructive) { Task { await model.deleteSnippet(snippet) } }
                    .keyboardShortcut(contextMenuHint(.delete))
            }
    }

    private var snippetShortcutBadgeRail: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(numberedVisibleSnippetSlots, id: \.number) { numbered in
                Text("⌘\(numbered.number)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(height: PanelMetrics.listUnitHeight)
                    .offset(
                        y: CGFloat(numbered.index) * PanelMetrics.listUnitHeight
                            - snippetListScroll.scrollOffset
                    )
            }
        }
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var snippetEditorPane: some View {
        if let initialDraft = snippetEditorDraft {
            SnippetEditorPane(
                draft: Binding(
                    // AppKit can finish a text-field edit after SwiftUI has
                    // begun removing this editor. Keep the retiring view's
                    // binding readable without resurrecting stale state.
                    get: {
                        guard snippetEditorDraft?.snippet.id == initialDraft.snippet.id else {
                            return initialDraft
                        }
                        return snippetEditorDraft ?? initialDraft
                    },
                    set: { updatedDraft in
                        guard snippetEditorDraft?.snippet.id == initialDraft.snippet.id else {
                            return
                        }
                        snippetEditorDraft = updatedDraft
                    }
                ),
                errorMessage: snippetEditorError,
                onSave: saveSnippetEditor,
                onCancel: cancelSnippetEditor
            )
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text(pausedDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Resume") { model.resumeCapture() }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.pausedBannerHeight)
        .background(Color.orange.opacity(0.08))
    }

    private var pausedDescription: String {
        guard let until = model.capturePausedUntil else { return "Capture paused" }
        return "Capture paused until \(until.formatted(date: .omitted, time: .shortened))"
    }

    private var pausedEmptyMessage: String {
        guard let until = model.capturePausedUntil else { return "Resume to start saving what you copy." }
        return "Saving resumes at \(until.formatted(date: .omitted, time: .shortened))."
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.query.isEmpty, model.capturePaused {
            VStack(spacing: 10) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Capture Is Paused")
                    .font(.headline)
                Text(pausedEmptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Resume Capture") { model.resumeCapture() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: model.query.isEmpty ? "clipboard" : "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "No Clipboard History" : "No Results")
                    .font(.headline)
                Text(model.query.isEmpty ? "Copy something to begin." : "Try a different search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var recordList: some View {
        // Selection is tracked manually (arrow keys + clicks) so the row
        // highlight can be a translucent accent wash instead of the
        // system's solid selection color.
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.records, id: \.id) { record in
                    listRow(record)
                }
            }
            .background(OverlayScrollerStyle(handle: listScroll))
        }
        .animation(recordListAnimation, value: model.records.map(\.id))
        .overlay(alignment: .topTrailing) { shortcutBadgeRail }
        .onChange(of: selection) { selected in
            if let selected { revealSelection(selected) }
        }
        // Insertions shift rows under a preserved pixel offset, leaving
        // the viewport clipped mid-row; re-anchor it on the selection
        // after the new layout settles.
        .onChange(of: model.records) { _ in
            guard let selection else { return }
            DispatchQueue.main.async {
                revealSelection(selection)
            }
        }
    }

    // Evaluated as the new records render, before recordsDidChange catches
    // lastQuery and lastFirstID up: a differing query means the change is a
    // search result swap, which lands instantly. Pins, unpins, and new
    // captures glide.
    private var recordListAnimation: Animation? {
        if pendingDeletion != nil { return .easeOut(duration: Self.deletionAnimationDuration) }
        // Filling an empty list (after unlock) also lands instantly.
        guard model.query == lastQuery, lastFirstID != nil, !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.86)
    }

    // The ⌘-number badges live in an overlay on the viewport, not inside the
    // lazy rows, so a recycled lazy row can never show a stale or missing
    // number. Each badge sits at its row's actual position — riding along
    // mid-scroll — and hops to the next row when that row claims the slot.
    private var shortcutBadgeRail: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(numberedVisibleSlots, id: \.number) { numbered in
                Text("⌘\(numbered.number)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(height: PanelMetrics.listUnitHeight)
                    .offset(
                        y: CGFloat(numbered.index) * PanelMetrics.listUnitHeight
                            - listScroll.scrollOffset
                    )
            }
        }
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .clipped()
        .allowsHitTesting(false)
    }

    // Arrow-key movement scrolls the AppKit scroll view directly: the fixed
    // unit grid makes the target offset exact math, independent of which rows
    // LazyVStack has materialized, and avoids the down-then-up flicker of
    // scrollTo followed by a correction.
    private func revealSelection(_ id: UUID) {
        // A records update may have queued work for a selection that rapid
        // key repeat has already moved past.
        guard selection == id else { return }
        guard let index = model.records.firstIndex(where: { $0.id == id }) else { return }
        listScroll.scrollUnitIntoView(index, unitHeight: PanelMetrics.listUnitHeight)
    }

    private func listRow(_ record: ClipboardRecord) -> some View {
        ClipboardRow(record: record, highlightTerms: searchTerms)
            .padding(.leading, 12)
            .padding(.trailing, 44)
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.listUnitHeight)
            .modifier(RowHighlight(isSelected: selection == record.id))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onPaste(record, .original) }
            // A plain single-tap gesture would wait out the double-click
            // window before firing; a simultaneous gesture selects instantly.
            .simultaneousGesture(TapGesture().onEnded { selection = record.id })
            // Shortcuts on context-menu items are hints for the panel's key
            // monitor; see contextMenuHint for why bare keys are left off.
            .contextMenu {
                if record.kind == .image {
                    Button("Quick Look") { onQuickLook(record) }
                    Divider()
                }
                Button(record.kind == .image ? "Paste Image" : "Paste") {
                    onPaste(record, .original)
                }
                .keyboardShortcut(contextMenuHint(.paste))
                Button("Paste as Plain Text") { onPaste(record, .plainText) }
                    .keyboardShortcut(contextMenuHint(.pastePlainText))
                    .disabled(record.kind == .image || record.kind == .files)
                Button("Paste as Single Line") { onPaste(record, .trimmedSingleLine) }
                    .keyboardShortcut(contextMenuHint(.pasteSingleLine))
                    .disabled((record.kind == .image || record.kind == .files) && !record.hasOCR)
                Button("Paste OCR Text") { onPaste(record, .ocrText) }
                    .keyboardShortcut(contextMenuHint(.pasteOCRText))
                    .disabled(!record.hasOCR)
                Button("Copy") { onCopy(record, .original) }
                    .keyboardShortcut(contextMenuHint(.copy))
                Button("Copy OCR Text") { onCopy(record, .ocrText) }
                    .disabled(!record.hasOCR)
                Divider()
                Button(record.isPinned ? "Unpin" : "Pin") {
                    Task { await model.togglePin(record) }
                }
                if canPromote(record) {
                    Divider()
                    if let derived = model.snippetDerived(from: record) {
                        Button("Open Snippet “\(derived.name)”…") { openSnippet(derived) }
                    }
                    Button(record.kind == .image ? "Save OCR Text as Snippet…" : "Save as Snippet…") {
                        beginPromotion(record)
                    }
                    .keyboardShortcut(contextMenuHint(.saveAsSnippet))
                }
                Divider()
                Button("Delete", role: .destructive) { deleteRecord(record) }
                    .keyboardShortcut(contextMenuHint(.delete))
            }
    }

    private func pasteNumbered(_ number: Int) {
        guard let numbered = numberedVisibleSlots.first(where: { $0.number == number }) else {
            return
        }
        onPaste(numbered.record, .original)
    }

    private func pasteNumberedSnippet(_ number: Int) {
        guard let numbered = numberedVisibleSnippetSlots.first(where: { $0.number == number }) else {
            return
        }
        onPasteSnippet(numbered.snippet)
    }

    private func moveSelection(_ delta: Int) {
        guard snippetEditorDraft == nil else { return }
        switch model.panelScope {
        case .clipboard:
            guard !model.records.isEmpty else { return }
            let currentIndex = selection.flatMap { id in model.records.firstIndex { $0.id == id } } ?? -1
            let nextIndex = min(max(currentIndex + delta, 0), model.records.count - 1)
            selection = model.records[nextIndex].id
        case .snippets:
            guard !model.snippets.isEmpty else { return }
            let currentIndex = snippetSelection.flatMap { id in
                model.snippets.firstIndex { $0.id == id }
            } ?? -1
            let nextIndex = min(max(currentIndex + delta, 0), model.snippets.count - 1)
            snippetSelection = model.snippets[nextIndex].id
        }
    }

    // The search field's editor consumes some modified keys before hidden
    // shortcut buttons see them. Intercept panel-wide commands here so they
    // work consistently regardless of focus, matching the user-configured
    // shortcuts from Settings.
    private func installShortcutMonitor() {
        guard shortcutKeyMonitor == nil else { return }
        shortcutKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is PacePanel else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if event.keyCode == 43, modifiers == .command {  // ⌘,
                NotificationCenter.default.post(name: .paceOpenSettings, object: nil)
                return nil
            }
            if event.keyCode == 1, modifiers == .command {  // ⌘S
                if snippetEditorDraft != nil {
                    saveSnippetEditor()
                    return nil
                }
            }
            if snippetEditorDraft != nil { return event }
            if model.panelScope == .clipboard,
               event.keyCode == 49, modifiers.isEmpty,  // Space
               let record = selectedRecord, record.kind == .image {
                onQuickLook(record)
                return nil
            }
            if model.panelScope == .snippets,
               event.keyCode == 45, modifiers == .command {  // ⌘N
                beginNewSnippet()
                return nil
            }
            if model.panelScope == .snippets,
               event.keyCode == 14, modifiers == .command {  // ⌘E
                if let snippet = selectedSnippet { beginEditingSnippet(snippet) }
                return nil
            }
            if model.panelScope == .snippets,
               event.keyCode == 2, modifiers == .command {  // ⌘D
                if let snippet = selectedSnippet { duplicateSnippet(snippet) }
                return nil
            }
            if event.keyCode == 126, modifiers == .command {  // ⌘↑
                if model.panelScope == .clipboard { selection = model.records.first?.id }
                else { snippetSelection = model.snippets.first?.id }
                return nil
            }
            if event.keyCode == 125, modifiers == .command {  // ⌘↓
                if model.panelScope == .clipboard { selection = model.records.last?.id }
                else { snippetSelection = model.snippets.last?.id }
                return nil
            }
            guard let action = PanelShortcuts.action(matching: event) else { return event }
            if action == .saveAsSnippet, model.panelScope != .clipboard { return event }
            if action == .paste, modifiers.isEmpty,
               event.keyCode == 36 || event.keyCode == 76,
               let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               textView.isEditable {
                // When the search field's editor has focus, its onSubmit
                // handles Return. Anywhere else — including when focus never
                // landed — Return still pastes the selection.
                return event
            }
            if model.panelScope == .clipboard { perform(action) }
            else { performSnippetAction(action) }
            return nil
        }
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .paste: performPaste(mode: .original)
        case .pastePlainText: performPaste(mode: .plainText)
        case .pasteSingleLine: performPaste(mode: .trimmedSingleLine)
        case .pasteOCRText: performPaste(mode: .ocrText)
        case .copy: performCopy()
        case .saveAsSnippet:
            if let record = selectedRecord { beginPromotion(record) }
        case .delete: deleteSelected()
        }
    }

    private func performSnippetAction(_ action: PanelAction) {
        switch action {
        case .paste, .pastePlainText, .pasteSingleLine, .pasteOCRText:
            pasteSelectedSnippet()
        case .copy:
            if let snippet = selectedSnippet { onCopySnippet(snippet) }
        case .saveAsSnippet:
            break
        case .delete:
            if let snippet = selectedSnippet {
                Task { await model.deleteSnippet(snippet) }
            }
        }
    }

    private func performCopy() {
        if let record = selectedRecord ?? model.records.first {
            onCopy(record, .original)
        }
    }

    private func deleteSelected() {
        guard let record = selectedRecord else { return }
        deleteRecord(record)
    }

    private func deleteRecord(_ record: ClipboardRecord) {
        guard pendingDeletion == nil else { return }
        // Deleting another row leaves the selection where it is.
        guard record.id == selectedRecord?.id else {
            Task { await model.delete(record) }
            return
        }
        let index = model.records.firstIndex(where: { $0.id == record.id }) ?? 0
        let replacementID: UUID? = if index + 1 < model.records.count {
            model.records[index + 1].id
        } else if index > 0 {
            model.records[index - 1].id
        } else {
            nil
        }
        pendingDeletion = PendingDeletion(deletedID: record.id, replacementID: replacementID)

        Task {
            await model.delete(record)
            // recordsDidChange consumes successful deletions. If the record
            // remains, the delete failed and no selection transition is due.
            if model.records.contains(where: { $0.id == record.id }) {
                pendingDeletion = nil
            }
        }
    }

    private func performPaste(mode: ClipboardRestoreMode) {
        guard let record = selectedRecord ?? model.records.first else { return }
        switch mode {
        case .ocrText:
            guard record.hasOCR else { return }
        case .trimmedSingleLine:
            guard record.kind != .image && record.kind != .files || record.hasOCR else { return }
        case .original, .plainText:
            break
        }
        onPaste(record, mode)
    }

    private func pasteSelectedSnippet() {
        guard snippetEditorDraft == nil, let snippet = selectedSnippet else { return }
        onPasteSnippet(snippet)
    }

    private func canPromote(_ record: ClipboardRecord) -> Bool {
        switch record.kind {
        case .text, .richText, .url:
            return true
        case .image:
            return record.hasOCR
        case .files, .unknown:
            return false
        }
    }

    private func beginPromotion(_ record: ClipboardRecord) {
        guard canPromote(record) else { return }
        if let existing = model.snippetDerived(from: record) {
            openSnippetConfiguration(existing)
            return
        }
        Task {
            guard var snippet = await model.snippetForPromotion(from: record) else { return }
            // Create the permanent item first. The editor then configures the
            // optional expansion keyword; canceling leaves a useful snippet.
            snippet.keyword = nil
            snippet.isExpansionEnabled = false
            model.snippetQuery = ""
            guard let saved = await model.saveSnippet(snippet) else { return }
            openSnippetConfiguration(saved, prefillKeyword: true)
        }
    }

    private func openSnippetConfiguration(_ snippet: Snippet, prefillKeyword: Bool = false) {
        model.snippetQuery = ""
        snippetSelection = snippet.id
        pendingSnippetConfiguration = PendingSnippetConfiguration(
            snippet: snippet,
            prefillKeyword: prefillKeyword
        )
        if model.panelScope == .snippets {
            presentPendingSnippetConfiguration()
        } else {
            model.panelScope = .snippets
        }
    }

    private func presentPendingSnippetConfiguration() {
        guard let pending = pendingSnippetConfiguration else { return }
        var configurable = pending.snippet
        if pending.prefillKeyword {
            let prefix = SnippetExpansionPreferences.defaultPrefix
            configurable.keyword = prefix.isEmpty ? nil : prefix
            configurable.isExpansionEnabled = !prefix.isEmpty
        }
        pendingSnippetConfiguration = nil
        snippetEditorError = nil
        snippetEditorDraft = SnippetEditorDraft(snippet: configurable)
        searchFocused = false
    }

    private func beginNewSnippet() {
        let prefix = SnippetExpansionPreferences.defaultPrefix
        snippetEditorError = nil
        snippetEditorDraft = SnippetEditorDraft(
            snippet: Snippet(
                name: "",
                template: "",
                keyword: prefix.isEmpty ? nil : prefix,
                isExpansionEnabled: true
            ),
            isNew: true
        )
        searchFocused = false
    }

    private func beginEditingSnippet(_ snippet: Snippet) {
        snippetEditorError = nil
        snippetEditorDraft = SnippetEditorDraft(snippet: snippet)
        searchFocused = false
    }

    private func duplicateSnippet(_ snippet: Snippet) {
        var duplicate = snippet
        duplicate.id = UUID()
        duplicate.name += " Copy"
        duplicate.keyword = nil
        duplicate.isExpansionEnabled = false
        duplicate.isPinned = false
        duplicate.createdAt = Date()
        duplicate.updatedAt = Date()
        duplicate.lastUsedAt = nil
        duplicate.useCount = 0
        duplicate.sourceRecordID = nil
        snippetEditorError = nil
        snippetEditorDraft = SnippetEditorDraft(snippet: duplicate, isNew: true)
        searchFocused = false
    }

    private func saveSnippetEditor() {
        guard let draft = snippetEditorDraft else { return }
        Task {
            if let saved = await model.saveSnippet(draft.resolvedSnippet, reportsFailure: false) {
                snippetSelection = saved.id
                snippetEditorError = nil
                snippetEditorDraft = nil
                searchFocused = true
            } else {
                snippetEditorError = model.statusMessage ?? "The snippet could not be saved."
            }
        }
    }

    private func cancelSnippetEditor() {
        pendingSnippetConfiguration = nil
        snippetEditorDraft = nil
        snippetEditorError = nil
        searchFocused = true
    }

    private func openSnippet(_ snippet: Snippet) {
        cancelSnippetEditor()
        model.panelScope = .snippets
        snippetSelection = snippet.id
    }

    private func selectFirstSnippetIfNeeded() {
        if snippetSelection == nil || !model.snippets.contains(where: { $0.id == snippetSelection }) {
            snippetSelection = model.snippets.first?.id
        }
        lastSnippetFirstID = model.snippets.first?.id
        lastSnippetQuery = model.snippetQuery
    }

    private func snippetsDidChange() {
        let firstID = model.snippets.first?.id
        let queryChanged = model.snippetQuery != lastSnippetQuery
        lastSnippetQuery = model.snippetQuery
        if queryChanged {
            snippetSelection = firstID
        } else if snippetSelection == nil
                    || !model.snippets.contains(where: { $0.id == snippetSelection }) {
            snippetSelection = firstID
        }
        lastSnippetFirstID = firstID
    }

    private func selectFirstIfNeeded() {
        if selection == nil || !model.records.contains(where: { $0.id == selection }) {
            selection = model.records.first?.id
        }
        lastFirstID = model.records.first?.id
    }

    private func recordsDidChange() {
        let firstID = model.records.first?.id
        let queryChanged = model.query != lastQuery
        lastQuery = model.query

        if let pendingDeletion {
            let deletedRecordIsGone = !model.records.contains {
                $0.id == pendingDeletion.deletedID
            }
            if deletedRecordIsGone, !deletionSelectionTransferScheduled {
                deletionSelectionTransferScheduled = true
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.deletionAnimationDuration
                ) {
                    // Let the adjacent row finish sliding into the vacated
                    // position before giving it the selection highlight.
                    // If the user moved selection meanwhile, respect that.
                    if selection == pendingDeletion.deletedID {
                        selection = pendingDeletion.replacementID.flatMap { replacementID in
                            model.records.contains { $0.id == replacementID }
                                ? replacementID
                                : nil
                        } ?? model.records.first?.id
                    }
                    self.pendingDeletion = nil
                    deletionSelectionTransferScheduled = false
                }
            }
            lastFirstID = firstID
            return
        }

        // A different first row means a new capture only if the old one is
        // still listed; deleting the top row (e.g. from its context menu while
        // another row is selected) must leave the selection alone.
        let topWasRemoved = lastFirstID.map { id in
            !model.records.contains { $0.id == id }
        } ?? false
        if queryChanged || (firstID != lastFirstID && !topWasRemoved) {
            // The search narrowed, or a new/re-copied item landed on top:
            // the best (most recent) match becomes the selection, which also
            // snaps the scroll back into alignment.
            selection = firstID
        } else if selection == nil || !model.records.contains(where: { $0.id == selection }) {
            selection = firstID
        }
        lastFirstID = firstID
    }
}

// ScrollViewProxy can only target rows (with the list's top inset applied);
// unit-grid scrolling and the ⌘-number slot mapping need the NSScrollView
// itself. All offsets measure from the top of the content regardless of the
// document view's coordinate orientation.
@MainActor
private final class ScrollViewHandle: ObservableObject {
    // Drives the ⌘-number slot mapping; updated from clip-view bounds changes.
    @Published private(set) var scrollOffset: CGFloat = 0

    private(set) weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?

    func attach(_ scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: nil
        ) { [weak self] _ in
            // Deferred: bounds changes can land mid-layout, where publishing
            // would re-enter the SwiftUI update.
            DispatchQueue.main.async { self?.refreshScrollOffset() }
        }
        refreshScrollOffset()
    }

    func scrollUnitIntoView(_ unitIndex: Int, unitHeight: CGFloat) {
        guard let scrollView else { return }
        let viewportHeight = scrollView.documentVisibleRect.height
        let current = currentOffset()
        let rowTop = CGFloat(unitIndex) * unitHeight
        let rowBottom = rowTop + unitHeight
        if rowTop < current {
            scroll(toOffset: rowTop)
        } else if rowBottom > current + viewportHeight {
            scroll(toOffset: rowBottom - viewportHeight)
        }
    }

    private func currentOffset() -> CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let visible = scrollView.documentVisibleRect
        return document.isFlipped
            ? visible.minY
            : document.bounds.height - visible.maxY
    }

    private func scroll(toOffset offset: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let viewportHeight = scrollView.documentVisibleRect.height
        let clamped = min(max(offset, 0), max(0, document.bounds.height - viewportHeight))
        guard abs(clamped - currentOffset()) > 0.5 else { return }
        let y = document.isFlipped
            ? clamped
            : document.bounds.height - viewportHeight - clamped
        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshScrollOffset()
    }

    private func refreshScrollOffset() {
        guard scrollView != nil else { return }
        let offset = currentOffset()
        if abs(offset - scrollOffset) > 0.5 { scrollOffset = offset }
    }
}

// SwiftUI's Text lays out an entire large string eagerly on the main thread,
// which visibly stalls the panel for big clipboard items. NSTextView lays out
// lazily, so only the visible portion is ever measured.
private struct PlainTextPreview: NSViewRepresentable {
    let text: String

    final class Coordinator {
        var styleObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        context.coordinator.styleObservation = scroll.observe(\.scrollerStyle) { scrollView, _ in
            if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.scroll(.zero)
        }
    }
}

// There is no SwiftUI control over NSScrollView scroller style; this probe
// finds its enclosing scroll view and switches it to overlay scrollers that
// appear only while scrolling. The conversion happens in viewDidMoveToWindow
// — before first paint — so the legacy scroller (and the layout gutter it
// reserves, which would shift row content) never shows. It also hands the
// scroll view to `handle` for unit-grid scrolling and the ⌘-number slot
// mapping.
private struct OverlayScrollerStyle: NSViewRepresentable {
    var handle: ScrollViewHandle?

    func makeNSView(context: Context) -> ProbeView {
        let probe = ProbeView()
        probe.handle = handle
        return probe
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.handle = handle
        nsView.applyIfAttached()
    }

    final class ProbeView: NSView {
        var handle: ScrollViewHandle?
        private var styleObservation: NSKeyValueObservation?
        private weak var observedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfAttached()
        }

        func applyIfAttached() {
            var ancestor = superview
            while let current = ancestor, !(current is NSScrollView) { ancestor = current.superview }
            guard let scrollView = ancestor as? NSScrollView else { return }
            handle?.attach(scrollView)
            Self.enforceOverlay(on: scrollView)
            guard observedScrollView !== scrollView else { return }
            observedScrollView = scrollView
            // AppKit reverts scrollerStyle to the system preference (legacy,
            // with a gutter, when "always show scroll bars" is on) during
            // scroll-view setup; a one-shot conversion doesn't stick.
            styleObservation = scrollView.observe(\.scrollerStyle) { scrollView, _ in
                Self.enforceOverlay(on: scrollView)
            }
        }

        private static func enforceOverlay(on scrollView: NSScrollView) {
            guard scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
    }
}

// A behind-window vibrancy backdrop. Unlike SwiftUI's in-window materials it
// samples only what is behind the window, so in-window content sliding
// beneath it (rows under a pinned header) never shows through or shifts its
// color, and every surface using it matches the panel body exactly.
private struct PanelBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .popover
        view.state = .active
        if cornerRadius > 0 {
            view.maskImage = Self.roundedMask(radius: cornerRadius)
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    // A layer mask does not reliably clip a behind-window blur region; the
    // effect view's own maskImage does.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: edge, height: edge),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private let panelByteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
}()

private func kindIcon(_ kind: ClipboardContentKind) -> String {
    switch kind {
    case .text: return "text.alignleft"
    case .richText: return "textformat"
    case .url: return "link"
    case .image: return "photo"
    case .files: return "doc.on.doc"
    case .unknown: return "clipboard"
    }
}

private enum KeyHints {
    static func label(_ action: PanelAction) -> String {
        "\(PanelShortcuts.shortcut(for: action).displayLabel) \(action.title)"
    }

    static func join(_ hints: [String]) -> String {
        hints.joined(separator: " · ")
    }
}

// Bolds and tints each case- and diacritic-insensitive occurrence of the
// search terms. Row text is a few hundred characters at most, so a direct
// scan per term stays cheap.
private func highlightedText(_ string: String, terms: [String]) -> Text {
    guard !terms.isEmpty else { return Text(string) }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    var ranges: [Range<String.Index>] = []
    for term in terms {
        var searchRange = string.startIndex..<string.endIndex
        while ranges.count < 32,
              let found = string.range(of: term, options: options, range: searchRange) {
            ranges.append(found)
            searchRange = found.upperBound..<string.endIndex
        }
    }
    guard !ranges.isEmpty else { return Text(string) }
    ranges.sort { $0.lowerBound < $1.lowerBound }
    var text = Text(verbatim: "")
    var cursor = string.startIndex
    for range in ranges {
        // Overlapping matches from different terms merge into one run.
        let start = max(range.lowerBound, cursor)
        guard start < range.upperBound else { continue }
        text = text
            + Text(string[cursor..<start])
            + Text(string[start..<range.upperBound]).bold().foregroundColor(.accentColor)
        cursor = range.upperBound
    }
    return text + Text(string[cursor...])
}

// Hover lives in each row so moving the pointer re-renders one row rather
// than the whole list.
private struct RowHighlight: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                // Primary at low opacity reads as a neutral gray wash in both
                // light and dark appearances.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.15 : isHovered ? 0.06 : 0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            )
            .onHover { isHovered = $0 }
    }
}

// Unlocking is automatic and usually near-instant; the label fades in only
// once the wait is long enough to notice, so a quick unlock never flashes.
private struct UnlockingView: View {
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Unlocking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .opacity(isRevealed ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.15).delay(0.15)) { isRevealed = true }
        }
    }
}

private struct LinkPresentation {
    let host: String
    let address: String

    // Plain text counts as a link only when it is a single web address;
    // Link items also accept other schemes that name a host.
    init?(_ candidate: Substring, webOnly: Bool) {
        guard candidate.utf8.count <= 4096 else { return nil }
        let address = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              !address.contains(where: \.isWhitespace),
              let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              !webOnly || scheme == "http" || scheme == "https",
              var host = components.host, !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        self.host = host
        self.address = address
    }

    init?(record: ClipboardRecord) {
        switch record.kind {
        case .url:
            if let link = LinkPresentation(record.preview[...], webOnly: false) {
                self = link
                return
            }
            // Items with only a URL representation keep a placeholder
            // preview; the address itself is in the searchable text.
            for line in record.searchableText.split(separator: "\n", maxSplits: 8) {
                if let link = LinkPresentation(line, webOnly: false) {
                    self = link
                    return
                }
            }
            return nil
        case .text, .richText:
            guard let link = LinkPresentation(record.preview[...], webOnly: true) else { return nil }
            self = link
        case .image, .files, .unknown:
            return nil
        }
    }
}

/// A panel shortcut to show on a context-menu item. An open menu matches
/// key equivalents before acting on its highlighted item, so a bare Return or
/// Space hint could run Paste when the user presses Return on another item;
/// only shortcuts with a modifier are shown.
private func contextMenuHint(_ action: PanelAction) -> KeyboardShortcut? {
    guard let shortcut = PanelShortcuts.shortcut(for: action).keyboardShortcut,
          !shortcut.modifiers.isEmpty
    else { return nil }
    return shortcut
}

// A single CSS-style color literal: #RGB, #RRGGBB, #RRGGBBAA,
// rgb(), or rgba(), with comma- or space-separated channels.
private enum ColorLiteral {
    static func color(in text: String) -> NSColor? {
        guard text.utf8.count <= 48 else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { return hex(value.dropFirst()) }
        if value.hasPrefix("rgb") { return functional(value) }
        return nil
    }

    /// `#RRGGBB` and `#RRGGBBAA` always; `#RGB` only with a hex letter, so
    /// issue references like `#123` and `#1234` stay text. `#RGBA` is skipped
    /// for the same reason (`#1234`, `#cafe`).
    private static func hex(_ digits: Substring) -> NSColor? {
        guard [3, 6, 8].contains(digits.count),
              digits.allSatisfy(\.isHexDigit),
              digits.count != 3 || digits.contains(where: \.isLetter),
              let raw = UInt64(digits, radix: 16)
        else { return nil }
        let short = digits.count == 3
        let count = short ? digits.count : digits.count / 2
        let bits: UInt64 = short ? 4 : 8
        let mask: UInt64 = short ? 0xF : 0xFF
        let channels = (0..<count).map { index -> CGFloat in
            let shift = bits * UInt64(count - 1 - index)
            return CGFloat((raw >> shift) & mask) / CGFloat(mask)
        }
        return NSColor(
            srgbRed: channels[0],
            green: channels[1],
            blue: channels[2],
            alpha: channels.count > 3 ? channels[3] : 1
        )
    }

    private static func functional(_ value: String) -> NSColor? {
        let arguments: Substring
        if value.hasPrefix("rgba(") { arguments = value.dropFirst(5) }
        else if value.hasPrefix("rgb(") { arguments = value.dropFirst(4) }
        else { return nil }
        guard arguments.hasSuffix(")") else { return nil }
        let parts = arguments.dropLast().split { $0 == "," || $0 == "/" || $0 == " " }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        var channels: [CGFloat] = []
        for (index, part) in parts.enumerated() {
            let isPercent = part.hasSuffix("%")
            guard let number = Double(isPercent ? part.dropLast() : part), number.isFinite else {
                return nil
            }
            let scale: Double = isPercent ? 100 : (index < 3 ? 255 : 1)
            channels.append(CGFloat(min(max(number / scale, 0), 1)))
        }
        return NSColor(
            srgbRed: channels[0],
            green: channels[1],
            blue: channels[2],
            alpha: channels.count > 3 ? channels[3] : 1
        )
    }
}

@MainActor
private enum FileIconCache {
    /// Boxes the lookup result so missing files are remembered too.
    private final class Entry {
        let icon: NSImage?
        init(_ icon: NSImage?) { self.icon = icon }
    }

    private static let icons = NSCache<NSString, Entry>()

    // The real Finder icon for a copied file (or a stacked icon for
    // several), when the files still exist.
    static func icon(for record: ClipboardRecord) async -> NSImage? {
        let lines = record.searchableText
            .split(separator: "\n")
            .filter { $0.hasPrefix("file://") }
            .prefix(8)
            .map(String.init)
        guard !lines.isEmpty else { return nil }
        let key = lines.joined(separator: "\n") as NSString
        if let entry = icons.object(forKey: key) { return entry.icon }
        // Resolving reference URLs and checking existence touch the disk,
        // which can block for seconds on an unreachable network volume.
        let icon = await Task.detached(priority: .utility) { lookup(lines) }.value
        icons.setObject(Entry(icon), forKey: key)
        return icon
    }

    nonisolated private static func lookup(_ lines: [String]) -> NSImage? {
        let paths = lines.compactMap { line -> String? in
            guard let url = URL(string: line) else { return nil }
            // Finder copies file reference URLs (file:///.file/id=…).
            return ((url as NSURL).filePathURL ?? url).path
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard let first = existing.first else { return nil }
        return existing.count == 1
            ? NSWorkspace.shared.icon(forFile: first)
            : NSWorkspace.shared.icon(forFiles: existing) ?? NSWorkspace.shared.icon(forFile: first)
    }
}

private struct ClipboardRow: View {
    // Items captured before the kind labels were unified carry these
    // placeholder previews.
    private static let legacyPlaceholders: [ClipboardContentKind: String] = [
        .url: "URL",
        .richText: "Rich text",
        .unknown: "Clipboard item"
    ]

    @EnvironmentObject private var model: AppModel
    let record: ClipboardRecord
    let highlightTerms: [String]
    @State private var thumbnail: CachedItemImage?
    @State private var fileIcon: NSImage?

    var body: some View {
        let link = LinkPresentation(record: record)
        HStack(spacing: 10) {
            leadingIcon(isLink: link != nil)
                .frame(width: 28, height: 28)
            if let link {
                VStack(alignment: .leading, spacing: 1) {
                    highlightedText(link.host, terms: highlightTerms)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    highlightedText(link.address, terms: highlightTerms)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                highlightedText(title, terms: highlightTerms)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.snippetDerived(from: record) != nil {
                Image(systemName: "text.quote")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
                    .help("Saved as a snippet")
                    .accessibilityLabel("Saved as a snippet")
            }
            if record.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Pinned")
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 2)
        .task(id: record.id) {
            switch record.kind {
            case .image:
                guard thumbnail == nil else { return }
                thumbnail = await model.itemImage(for: record, maxPixelSize: 64)
            case .files:
                guard fileIcon == nil else { return }
                fileIcon = await FileIconCache.icon(for: record)
            case .text, .richText, .url, .unknown:
                break
            }
        }
    }

    @ViewBuilder
    private func leadingIcon(isLink: Bool) -> some View {
        if let thumbnail {
            Image(nsImage: thumbnail.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        } else if let fileIcon {
            Image(nsImage: fileIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
        } else if let swatch = swatchColor {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: swatch))
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: isLink ? "link" : kindIcon(record.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var swatchColor: NSColor? {
        guard record.kind == .text || record.kind == .richText else { return nil }
        return ColorLiteral.color(in: record.preview)
    }

    private var title: String {
        if record.kind == .image {
            if let pixels = thumbnail?.pixelSize, pixels.width > 0 {
                return "Image (\(Int(pixels.width))×\(Int(pixels.height)))"
            }
            return "Image"
        }
        if record.preview.isEmpty || Self.legacyPlaceholders[record.kind] == record.preview {
            return record.kind.displayName
        }
        return record.preview
    }
}

private struct DetailPane: View {
    @EnvironmentObject private var model: AppModel
    let record: ClipboardRecord?
    let derivedSnippet: Snippet?
    let onQuickLook: (ClipboardRecord) -> Void
    let onSaveAsSnippet: (ClipboardRecord) -> Void
    let onOpenSnippet: (Snippet) -> Void
    @State private var image: CachedItemImage?
    @State private var text: String?
    @State private var loadedID: UUID?

    var body: some View {
        if let record {
            VStack(spacing: 0) {
                preview(for: record)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                information(for: record)
            }
            .task(id: record.id) { await load(record) }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clipboard")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No Selection")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Renders whatever finished loading last — even if it belongs to the
    // previous selection — so switching items swaps the preview in a single
    // frame instead of flashing a placeholder or the collapsed preview
    // string while the new content loads.
    @ViewBuilder
    private func preview(for record: ClipboardRecord) -> some View {
        if let image {
            Image(nsImage: image.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onQuickLook(record) }
                .contextMenu {
                    Button("Quick Look") { onQuickLook(record) }
                }
                .help("Quick Look (Space)")
                .accessibilityLabel("Quick Look image")
                .accessibilityAddTraits(.isButton)
                .padding(14)
        } else if let text {
            PlainTextPreview(text: text)
        } else if record.kind == .image {
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
        } else {
            ScrollView {
                Text(record.preview)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }

    private func information(for record: ClipboardRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            infoRow("Source", record.source.name)
            infoRow("Content type", record.kind.displayName)
            if record.kind == .image, let pixels = image?.pixelSize, pixels.width > 0 {
                infoRow("Dimensions", "\(Int(pixels.width))×\(Int(pixels.height))")
            }
            infoRow("Size", panelByteFormatter.string(fromByteCount: record.byteCount))
            infoRow("Times copied", "\(record.copyCount)")
            infoRow("Last copied", record.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
            if record.useCount > 0 {
                infoRow("Times used in Pace", "\(record.useCount)")
                if let lastUsedAt = record.lastUsedAt {
                    infoRow("Last used in Pace", lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                keyHints(for: record)
                Spacer()
                if canSaveAsSnippet(record) {
                    if let derivedSnippet {
                        Button("Open \(derivedSnippet.keyword ?? derivedSnippet.name)") {
                            onOpenSnippet(derivedSnippet)
                        }
                        .buttonStyle(.borderless)
                    }
                    Button(record.kind == .image ? "Save OCR as Snippet…" : "Save as Snippet…") {
                        onSaveAsSnippet(record)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // Read from the configured shortcuts; falls back to the essentials when
    // the snippet buttons leave too little room.
    private func keyHints(for record: ClipboardRecord) -> some View {
        let paste = KeyHints.label(.paste)
        let copy = KeyHints.label(.copy)
        var full = [paste, copy]
        if record.kind == .image { full.append("Space Quick Look") }
        full.append(KeyHints.label(.delete))
        return ViewThatFits(in: .horizontal) {
            Text(KeyHints.join(full)).lineLimit(1)
            Text(KeyHints.join([paste, copy])).lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private func canSaveAsSnippet(_ record: ClipboardRecord) -> Bool {
        switch record.kind {
        case .text, .richText, .url: return true
        case .image: return record.hasOCR
        case .files, .unknown: return false
        }
    }

    private func load(_ record: ClipboardRecord) async {
        if record.kind == .image {
            let loaded = await model.itemImage(for: record, maxPixelSize: 1200)
            guard !Task.isCancelled else { return }
            image = loaded
            text = nil
        } else {
            let loaded = await model.itemDetailText(for: record)
            guard !Task.isCancelled else { return }
            text = loaded
            image = nil
        }
        loadedID = record.id
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(snippet.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let keyword = snippet.keyword {
                Text(keyword)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(snippet.isExpansionEnabled ? .secondary : .tertiary)
                    .lineLimit(1)
            }
            if snippet.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Pinned")
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SnippetDetailPane: View {
    @EnvironmentObject private var model: AppModel
    let snippet: Snippet?
    let onEdit: (Snippet) -> Void
    @State private var renderedText: String?
    @State private var renderingError: String?

    var body: some View {
        if let snippet {
            VStack(spacing: 0) {
                Group {
                    if let renderedText {
                        PlainTextPreview(text: renderedText)
                    } else if let renderingError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(renderingError)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    infoRow("Keyword", snippet.keyword ?? "None")
                    if !snippet.tags.isEmpty {
                        infoRow("Tags", snippet.tags.joined(separator: ", "))
                    }
                    infoRow("Expansion", snippet.isExpansionEnabled ? "Enabled" : "Disabled")
                    infoRow("Times used", "\(snippet.useCount)")
                    infoRow("Modified", snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    Divider().padding(.vertical, 2)
                    HStack {
                        Text(KeyHints.join([KeyHints.label(.paste), KeyHints.label(.copy)]))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Edit…") { onEdit(snippet) }
                            .buttonStyle(.borderless)
                            .keyboardShortcut("e", modifiers: .command)
                    }
                }
                .font(.system(size: 12))
                .padding(12)
            }
            .task(id: snippet.updatedAt) { await load(snippet) }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.quote")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No Selection")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    private func load(_ snippet: Snippet) async {
        do {
            let rendered = try await model.renderSnippet(snippet)
            guard !Task.isCancelled else { return }
            renderedText = rendered.text
            renderingError = nil
        } catch {
            guard !Task.isCancelled else { return }
            renderedText = nil
            renderingError = error.localizedDescription
        }
    }
}

private struct SnippetEditorPane: View {
    @Binding var draft: SnippetEditorDraft
    let errorMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(draft.isNew ? "New Snippet" : "Edit Snippet")
                    .font(.headline)
                Spacer()
                Menu {
                    placeholderButton(
                        "Current Date",
                        value: "{date}",
                        example: renderedExample(for: "{date}")
                    )
                    placeholderButton(
                        "Current Time",
                        value: "{time}",
                        example: renderedExample(for: "{time}")
                    )
                    placeholderButton(
                        "Date & Time",
                        value: "{datetime}",
                        example: renderedExample(for: "{datetime}")
                    )
                    placeholderButton(
                        "ISO 8601 Date & Time",
                        value: "{datetime format=iso8601}",
                        example: renderedExample(for: "{datetime format=iso8601}")
                    )
                    Divider()
                    placeholderButton(
                        "Clipboard",
                        value: "{clipboard}",
                        example: "latest copied text"
                    )
                    placeholderButton(
                        "Previous Clipboard",
                        value: "{clipboard offset=1}",
                        example: "second-latest copied text"
                    )
                    placeholderButton(
                        "Cursor Position",
                        value: "{cursor}",
                        example: "cursor lands here"
                    )
                    placeholderButton(
                        "UUID",
                        value: "{uuid}",
                        example: "A1B2C3D4-…"
                    )
                } label: {
                    Label("Insert Variable", systemImage: "curlybraces")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            field("Name") {
                TextField("Required", text: $draft.snippet.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                field("Keyword") {
                    TextField("Optional", text: keywordBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("Expand", isOn: $draft.snippet.isExpansionEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(draft.resolvedSnippet.keyword == nil)
                    .fixedSize()
            }

            field("Tags") {
                TextField("Comma-separated", text: $draft.tagsText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Template")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $draft.snippet.template)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .frame(minHeight: 90)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack {
                Text("⌘S to save · Esc to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        draft.snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.snippet.template.isEmpty
                    )
            }
        }
        .padding(14)
        .onAppear { nameFocused = true }
    }

    private var keywordBinding: Binding<String> {
        Binding(
            get: { draft.snippet.keyword ?? "" },
            set: { draft.snippet.keyword = $0 }
        )
    }

    private func placeholderButton(
        _ label: String,
        value: String,
        example: String
    ) -> some View {
        Button("\(label) · \(value) → \(example)") {
            if !draft.snippet.template.isEmpty,
               draft.snippet.template.last?.isWhitespace == false {
                draft.snippet.template += " "
            }
            draft.snippet.template += value
        }
    }

    private func renderedExample(for placeholder: String) -> String {
        (try? SnippetTemplateRenderer.render(placeholder).text) ?? "example"
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            content()
        }
    }
}
