import AppKit
import PaceCore
import SwiftUI

private final class PacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let paceHistoryPanelDidShow = Notification.Name("PaceHistoryPanelDidShow")
    static let paceOpenSettings = Notification.Name("PaceOpenSettings")
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

private enum PanelMetrics {
    static let width: CGFloat = 760
    static let listWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 16
    static let searchHeight: CGFloat = 44
    static let dividerHeight: CGFloat = 1
    static let listUnitHeight: CGFloat = 48
    static let minimumVisibleUnits = 5
    static let maximumVisibleUnits = 8

    static func visibleUnitCount(contentUnitCount: Int) -> Int {
        min(
            max(contentUnitCount, minimumVisibleUnits),
            maximumVisibleUnits
        )
    }

    static func preferredHeight(contentUnitCount: Int) -> CGFloat {
        let visibleUnits = visibleUnitCount(contentUnitCount: contentUnitCount)
        return searchHeight
            + dividerHeight
            + CGFloat(visibleUnits) * listUnitHeight
    }
}

@MainActor
final class HistoryPanelCoordinator {
    private let model: AppModel
    private var panel: PacePanel?
    private var targetApplication: NSRunningApplication?
    private var wantsVisible = false
    private var keyObserver: NSObjectProtocol?
    private var escapeMonitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        wantsVisible = true
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
        resizePanel(
            to: PanelMetrics.preferredHeight(contentUnitCount: model.records.count)
        )
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Post on the next turn: on the very first show the SwiftUI view may
        // not have attached its onReceive subscriber yet, and a synchronous
        // post is missed — leaving the search field unfocused.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .paceHistoryPanelDidShow, object: nil)
        }
    }

    func hide() {
        wantsVisible = false
        panel?.orderOut(nil)
        model.query = ""
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
            self.hide()
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
            onUnlock: { [weak self] in self?.unlockAndRestorePanel() },
            onClose: { [weak self] in self?.hide() },
            onPreferredHeightChange: { [weak self] height in
                self?.resizePanel(to: height)
            }
        )
        .environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        // The root reports its preferred height explicitly; don't let the
        // hosting view install competing window-sizing constraints.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func panelDidResignKey() {
        guard wantsVisible else { return }
        // Don't dismiss while an unlock is still settling.
        guard model.vaultState != .unlocking else { return }
        hide()
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

    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var selection: UUID?
    @State private var lastFirstID: UUID?
    @State private var lastQuery = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionSelectionTransferScheduled = false
    @State private var shortcutKeyMonitor: Any?
    @StateObject private var listScroll = ScrollViewHandle()

    var onPaste: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onCopy: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onUnlock: () -> Void
    var onClose: () -> Void
    var onPreferredHeightChange: (CGFloat) -> Void

    private var listContentUnitCount: Int {
        model.records.count
    }

    private var visibleListUnitCount: Int {
        PanelMetrics.visibleUnitCount(contentUnitCount: listContentUnitCount)
    }

    private var preferredPanelHeight: CGFloat {
        PanelMetrics.preferredHeight(contentUnitCount: listContentUnitCount)
    }

    var body: some View {
        Group {
            switch model.vaultState {
            case .locked, .unlocking:
                lockedView
            case .failed(let message):
                failedView(message)
            case .unlocked:
                historyView
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
        .onAppear {
            onPreferredHeightChange(preferredPanelHeight)
        }
        .onChange(of: preferredPanelHeight) { height in
            onPreferredHeightChange(height)
        }
    }

    // Unlocking is automatic and near-instant; this shows for a frame or two
    // at most.
    private var lockedView: some View {
        ProgressView()
            .controlSize(.small)
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

    private struct NumberedSlot {
        let number: Int
        let index: Int
        let record: ClipboardRecord
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

    private var historyView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()
                .frame(height: PanelMetrics.dividerHeight)

            if model.records.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    recordList
                        .frame(width: PanelMetrics.listWidth)
                    Divider()
                    DetailPane(record: selectedRecord)
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

    private var emptyState: some View {
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
        .animation(
            pendingDeletion == nil
                ? nil
                : .easeOut(duration: Self.deletionAnimationDuration),
            value: model.records.map(\.id)
        )
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
        ClipboardRow(record: record)
            .padding(.leading, 12)
            .padding(.trailing, 44)
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.listUnitHeight)
            .background(
                // Primary at low opacity reads as a neutral gray wash in both
                // light and dark appearances.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selection == record.id ? 0.15 : 0))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onPaste(record, .original) }
            // A plain single-tap gesture would wait out the double-click
            // window before firing; a simultaneous gesture selects instantly.
            .simultaneousGesture(TapGesture().onEnded { selection = record.id })
            .contextMenu {
                Button(record.kind == .image ? "Paste Image" : "Paste") {
                    onPaste(record, .original)
                }
                Button("Paste as Plain Text") { onPaste(record, .plainText) }
                    .disabled(record.kind == .image || record.kind == .files)
                Button("Paste as Single Line") { onPaste(record, .trimmedSingleLine) }
                    .disabled((record.kind == .image || record.kind == .files) && !record.hasOCR)
                Button("Paste OCR Text") { onPaste(record, .ocrText) }
                    .disabled(!record.hasOCR)
                Button("Copy") { onCopy(record, .original) }
                Button("Copy OCR Text") { onCopy(record, .ocrText) }
                    .disabled(!record.hasOCR)
                Divider()
                Button(record.isPinned ? "Unpin" : "Pin") {
                    Task { await model.togglePin(record) }
                }
            }
    }

    private func pasteNumbered(_ number: Int) {
        guard let numbered = numberedVisibleSlots.first(where: { $0.number == number }) else {
            return
        }
        onPaste(numbered.record, .original)
    }

    private func moveSelection(_ delta: Int) {
        guard !model.records.isEmpty else { return }
        let currentIndex = selection.flatMap { id in model.records.firstIndex { $0.id == id } } ?? -1
        let nextIndex = min(max(currentIndex + delta, 0), model.records.count - 1)
        selection = model.records[nextIndex].id
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
            if event.keyCode == 126, modifiers == .command {  // ⌘↑
                selection = model.records.first?.id
                return nil
            }
            if event.keyCode == 125, modifiers == .command {  // ⌘↓
                selection = model.records.last?.id
                return nil
            }
            guard let action = PanelShortcuts.action(matching: event) else { return event }
            if action == .paste, modifiers.isEmpty,
               event.keyCode == 36 || event.keyCode == 76,
               let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               textView.isEditable {
                // When the search field's editor has focus, its onSubmit
                // handles Return. Anywhere else — including when focus never
                // landed — Return still pastes the selection.
                return event
            }
            perform(action)
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
        case .delete: deleteSelected()
        }
    }

    private func performCopy() {
        if let record = selectedRecord ?? model.records.first {
            onCopy(record, .original)
        }
    }

    private func deleteSelected() {
        guard pendingDeletion == nil, let record = selectedRecord else { return }
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

        if queryChanged || firstID != lastFirstID {
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

private func kindLabel(_ kind: ClipboardContentKind) -> String {
    switch kind {
    case .text: return "Text"
    case .richText: return "Rich Text"
    case .url: return "Link"
    case .image: return "Image"
    case .files: return "Files"
    case .unknown: return "Other"
    }
}

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

private struct ClipboardRow: View {
    @EnvironmentObject private var model: AppModel
    let record: ClipboardRecord
    @State private var thumbnail: CachedItemImage?

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
                .frame(width: 28, height: 28)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 6)
            if record.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .task(id: record.id) {
            guard record.kind == .image, thumbnail == nil else { return }
            thumbnail = await model.itemImage(for: record, maxPixelSize: 64)
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
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
        } else {
            Image(systemName: kindIcon(record.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var title: String {
        if record.kind == .image {
            if let pixels = thumbnail?.pixelSize, pixels.width > 0 {
                return "Image (\(Int(pixels.width))×\(Int(pixels.height)))"
            }
            return "Image"
        }
        return record.preview.isEmpty ? kindLabel(record.kind) : record.preview
    }
}

private struct DetailPane: View {
    @EnvironmentObject private var model: AppModel
    let record: ClipboardRecord?
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
            infoRow("Content type", kindLabel(record.kind))
            if record.kind == .image, let pixels = image?.pixelSize, pixels.width > 0 {
                infoRow("Dimensions", "\(Int(pixels.width))×\(Int(pixels.height))")
            }
            infoRow("Size", panelByteFormatter.string(fromByteCount: record.byteCount))
            infoRow("Times copied", "\(record.copyCount)")
            infoRow("Last copied", record.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
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
