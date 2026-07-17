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
    static let footerHeight: CGFloat = 30
    static let dividerHeight: CGFloat = 1
    static let listUnitHeight: CGFloat = 48
    static let minimumVisibleUnits = 5
    static let maximumVisibleUnits = 8
    static let pinnedSectionHeaderClearance = listUnitHeight

    static func visibleUnitCount(contentUnitCount: Int) -> Int {
        min(
            max(contentUnitCount, minimumVisibleUnits),
            maximumVisibleUnits
        )
    }

    static func preferredHeight(contentUnitCount: Int) -> CGFloat {
        let visibleUnits = visibleUnitCount(contentUnitCount: contentUnitCount)
        return searchHeight
            + footerHeight
            + dividerHeight * 2
            + CGFloat(visibleUnits) * listUnitHeight
    }
}

private func historyDateBucketTitle(for date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
    if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This Month" }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.month(.wide))
    }
    return date.formatted(.dateTime.month(.wide).year())
}

private func historyDateSectionCount(in records: [ClipboardRecord]) -> Int {
    var count = 0
    var previousTitle: String?
    for record in records {
        let title = historyDateBucketTitle(for: record.lastCopiedAt)
        if title != previousTitle {
            count += 1
            previousTitle = title
        }
    }
    return count
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
            to: PanelMetrics.preferredHeight(
                contentUnitCount: model.records.count + historyDateSectionCount(in: model.records)
            )
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
                    height: PanelMetrics.preferredHeight(
                        contentUnitCount: model.records.count
                            + historyDateSectionCount(in: model.records)
                    )
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

    private enum SelectionScrollDirection {
        case upward
        case downward
        case unchanged
    }

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
    @State private var lastRevealedSelection: UUID?
    @State private var shortcutKeyMonitor: Any?
    @StateObject private var listScroll = ScrollViewHandle()

    var onPaste: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onCopy: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onUnlock: () -> Void
    var onClose: () -> Void
    var onPreferredHeightChange: (CGFloat) -> Void

    private var listContentUnitCount: Int {
        model.records.count + (showsDateSectionHeaders ? recordSections.count : 0)
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
        .background(.thickMaterial)
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

    private struct RecordEntry: Identifiable {
        let offset: Int
        let record: ClipboardRecord
        var id: UUID { record.id }
    }

    private struct RecordSection: Identifiable {
        let id: Int
        let title: String
        var entries: [RecordEntry]
    }

    // Consecutive records sharing a date bucket form a section. Headings are
    // only shown while browsing — text search results are relevance-ordered,
    // so chronological headings would interleave.
    private var recordSections: [RecordSection] {
        let grouped = showsDateSectionHeaders
        var sections: [RecordSection] = []
        for (index, record) in model.records.enumerated() {
            let title = grouped ? historyDateBucketTitle(for: record.lastCopiedAt) : ""
            if let last = sections.indices.last, sections[last].title == title {
                sections[last].entries.append(RecordEntry(offset: index, record: record))
            } else {
                sections.append(RecordSection(
                    id: sections.count,
                    title: title,
                    entries: [RecordEntry(offset: index, record: record)]
                ))
            }
        }
        return sections
    }

    private var showsDateSectionHeaders: Bool {
        SearchQuery(model.query).text.isEmpty
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

            Divider()
                .frame(height: PanelMetrics.dividerHeight)
            footer
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
        ScrollViewReader { proxy in
            // Selection is tracked manually (arrow keys + clicks) so the row
            // highlight can be a translucent accent wash instead of the
            // system's solid selection color.
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(recordSections) { section in
                        if section.title.isEmpty {
                            ForEach(section.entries) { entry in
                                listRow(
                                    entry.record,
                                    number: entry.offset < 9 ? entry.offset + 1 : nil
                                )
                            }
                        } else {
                            Section {
                                ForEach(section.entries) { entry in
                                    listRow(
                                        entry.record,
                                        number: entry.offset < 9 ? entry.offset + 1 : nil
                                    )
                                }
                            } header: {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: PanelMetrics.listUnitHeight)
                                    .background(.thickMaterial)
                            }
                        }
                    }
                }
            }
            .animation(
                pendingDeletion == nil
                    ? nil
                    : .easeOut(duration: Self.deletionAnimationDuration),
                value: model.records.map(\.id)
            )
            .onChange(of: selection) { selected in
                if let selected { revealSelection(selected, with: proxy) }
            }
            // Insertions shift rows under a preserved pixel offset, leaving
            // the viewport clipped mid-row; re-anchor it on the selection
            // after the new layout settles.
            .onChange(of: model.records) { _ in
                guard let selection else { return }
                DispatchQueue.main.async {
                    revealSelection(selection, with: proxy)
                }
            }
        }
    }

    // Prefer one direct, minimal AppKit adjustment for ordinary arrow-key
    // movement. SwiftUI's scrollTo followed by an AppKit correction produces
    // a visible down-then-up flicker at the viewport edge. A directional proxy
    // scroll is only needed when LazyVStack has not materialized the target.
    private func revealSelection(_ id: UUID, with proxy: ScrollViewProxy) {
        // A records update may have queued work for a selection that rapid
        // key repeat has already moved past.
        guard selection == id else { return }

        let direction = selectionScrollDirection(to: id)
        lastRevealedSelection = id

        if id == model.records.first?.id {
            // Anchoring the first row via ScrollViewProxy scrolls the
            // scroll view's own top inset out of view.
            listScroll.scrollToTop()
            return
        }

        let topClearance = showsDateSectionHeaders
            ? PanelMetrics.pinnedSectionHeaderClearance
            : 0
        guard !listScroll.ensureRowIsVisible(id, topClearance: topClearance) else {
            return
        }

        // Large or very rapid selection jumps can outrun LazyVStack's
        // materialized views. Anchor the target at the edge it entered from
        // so key repeat never pulls the selection into the middle.
        proxy.scrollTo(id, anchor: fallbackScrollAnchor(for: direction))
    }

    private func selectionScrollDirection(to id: UUID) -> SelectionScrollDirection {
        guard let previousID = lastRevealedSelection,
              let previousIndex = model.records.firstIndex(where: { $0.id == previousID }),
              let nextIndex = model.records.firstIndex(where: { $0.id == id }) else {
            return .unchanged
        }
        if nextIndex > previousIndex { return .downward }
        if nextIndex < previousIndex { return .upward }
        return .unchanged
    }

    private func fallbackScrollAnchor(for direction: SelectionScrollDirection) -> UnitPoint {
        switch direction {
        case .downward:
            return .bottom
        case .upward:
            guard showsDateSectionHeaders else { return .top }
            // ScrollViewProxy aligns the same unit point in the row and
            // viewport. This fraction places the row's top exactly one
            // 48-point unit below the pinned date header.
            let y = 1 / CGFloat(max(visibleListUnitCount - 1, 1))
            return UnitPoint(x: 0.5, y: y)
        case .unchanged:
            return .center
        }
    }

    private func listRow(_ record: ClipboardRecord, number: Int?) -> some View {
        ClipboardRow(record: record, shortcutNumber: number)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.listUnitHeight)
            .id(record.id)
            .background(
                OverlayScrollerStyle(
                    handle: listScroll,
                    rowID: record.id
                )
            )
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

    private var footer: some View {
        HStack {
            Spacer()
            Text("\(model.records.count) shown")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func pasteNumbered(_ number: Int) {
        guard number <= model.records.count else { return }
        onPaste(model.records[number - 1], .original)
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
// scrolling to the list's absolute origin needs the NSScrollView itself.
@MainActor
private final class ScrollViewHandle: ObservableObject {
    private final class WeakView {
        weak var value: NSView?

        init(_ value: NSView) {
            self.value = value
        }
    }

    weak var scrollView: NSScrollView?
    private var rowViews: [UUID: WeakView] = [:]

    func register(rowView: NSView, for id: UUID) {
        rowViews[id] = WeakView(rowView)
    }

    func unregister(rowView: NSView, for id: UUID) {
        guard rowViews[id]?.value === rowView else { return }
        rowViews[id] = nil
    }

    func scrollToTop() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let origin = NSPoint(
            x: 0,
            y: document.isFlipped
                ? 0
                : document.bounds.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @discardableResult
    func ensureRowIsVisible(_ id: UUID, topClearance: CGFloat) -> Bool {
        guard let rowView = rowViews[id]?.value,
              rowView.window != nil,
              rowView.bounds.height > 0,
              let scrollView,
              let document = scrollView.documentView else {
            rowViews[id] = nil
            return false
        }

        // Rows and section headers share one exact layout unit, so aligning
        // the row bounds also aligns the viewport to the item grid.
        let rowRect = rowView.convert(rowView.bounds, to: document)
        let viewport = scrollView.documentVisibleRect
        var targetY = viewport.origin.y

        if document.isFlipped {
            let visibleTop = viewport.minY + topClearance
            let visibleBottom = viewport.maxY
            if rowRect.minY < visibleTop {
                targetY = rowRect.minY - topClearance
            } else if rowRect.maxY > visibleBottom {
                targetY = rowRect.maxY - viewport.height
            }
        } else {
            let visibleTop = viewport.maxY - topClearance
            let visibleBottom = viewport.minY
            if rowRect.maxY > visibleTop {
                targetY = rowRect.maxY + topClearance - viewport.height
            } else if rowRect.minY < visibleBottom {
                targetY = rowRect.minY
            }
        }

        let minimumY = document.bounds.minY
        let maximumY = max(minimumY, document.bounds.maxY - viewport.height)
        targetY = min(max(targetY, minimumY), maximumY)
        guard abs(targetY - viewport.origin.y) > 0.5 else { return true }

        scrollView.contentView.scroll(
            to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
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
// reserves, which would shift row content) never shows. It also reports the
// scroll view and materialized rows back through `handle` so selection
// movement can account for the pinned section header overlay immediately.
private struct OverlayScrollerStyle: NSViewRepresentable {
    var handle: ScrollViewHandle?
    var rowID: UUID

    init(
        handle: ScrollViewHandle? = nil,
        rowID: UUID
    ) {
        self.handle = handle
        self.rowID = rowID
    }

    func makeNSView(context: Context) -> ProbeView {
        let probe = ProbeView()
        probe.handle = handle
        probe.rowID = rowID
        return probe
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        if let previousID = nsView.rowID, previousID != rowID {
            nsView.handle?.unregister(rowView: nsView, for: previousID)
        }
        nsView.handle = handle
        nsView.rowID = rowID
        nsView.applyIfAttached()
        nsView.updateRowRegistration()
    }

    final class ProbeView: NSView {
        var handle: ScrollViewHandle?
        var rowID: UUID?
        private var styleObservation: NSKeyValueObservation?
        private weak var observedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfAttached()
            updateRowRegistration()
        }

        func applyIfAttached() {
            var ancestor = superview
            while let current = ancestor, !(current is NSScrollView) { ancestor = current.superview }
            guard let scrollView = ancestor as? NSScrollView else { return }
            handle?.scrollView = scrollView
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

        func updateRowRegistration() {
            guard let handle, let rowID else { return }
            if window != nil {
                handle.register(rowView: self, for: rowID)
            } else {
                handle.unregister(rowView: self, for: rowID)
            }
        }

        private static func enforceOverlay(on scrollView: NSScrollView) {
            guard scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
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
    let shortcutNumber: Int?
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
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
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
