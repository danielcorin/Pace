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
    static let size = CGSize(width: 760, height: 480)
    static let listWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 16
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
        model.pasteTargetName = targetApplication?.localizedName
        // Unlocking needs no user interaction; never surface a locked panel.
        if model.vaultState == .locked {
            Task { await model.unlock() }
        }

        let panel = panel ?? makePanel()
        self.panel = panel
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
            contentRect: NSRect(origin: .zero, size: PanelMetrics.size),
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
            onClose: { [weak self] in self?.hide() }
        )
        .environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        // The root view has a fixed frame; don't let the hosting view install
        // its own window-sizing constraints on top of it.
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
    @State private var returnKeyMonitor: Any?
    @StateObject private var listScroll = ScrollViewHandle()

    var onPaste: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onCopy: (ClipboardRecord, ClipboardRestoreMode) -> Void
    var onUnlock: () -> Void
    var onClose: () -> Void

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
        .frame(width: PanelMetrics.size.width, height: PanelMetrics.size.height)
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
        selection.flatMap { id in model.records.first { $0.id == id } }
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
        let grouped = SearchQuery(model.query).text.isEmpty
        var sections: [RecordSection] = []
        for (index, record) in model.records.enumerated() {
            let title = grouped ? Self.dateBucketTitle(for: record.lastCopiedAt) : ""
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

    private static func dateBucketTitle(for date: Date, now: Date = Date()) -> String {
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
            footer
        }
        .overlay {
            Button("") { performCopy() }
                .keyboardShortcut(.return, modifiers: [.command])
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { performPaste(mode: .plainText) }
                .keyboardShortcut(.return, modifiers: [.shift])
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { performPaste(mode: .ocrText) }
                .keyboardShortcut(.return, modifiers: [.option])
                .opacity(0)
                .allowsHitTesting(false)
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
            installReturnMonitor()
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
            List {
                ForEach(recordSections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            listRow(entry.record, number: entry.offset < 9 ? entry.offset + 1 : nil)
                        }
                    } header: {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .animation(
                pendingDeletion == nil ? nil : .easeOut(duration: 0.16),
                value: model.records.map(\.id)
            )
            .onChange(of: selection) { selected in
                if let selected { scroll(proxy, to: selected) }
            }
            // Insertions shift rows under a preserved pixel offset, leaving
            // the viewport clipped mid-row; re-anchor it on the selection
            // after the new layout settles.
            .onChange(of: model.records) { _ in
                guard let selection else { return }
                DispatchQueue.main.async { scroll(proxy, to: selection) }
            }
        }
    }

    // For the first row, scroll the NSScrollView to its absolute origin —
    // anchoring the row via ScrollViewProxy scrolls the list's own top inset
    // out of view. Before the handle attaches (first layout) the list is
    // still at its natural origin, so doing nothing is correct there.
    private func scroll(_ proxy: ScrollViewProxy, to id: UUID) {
        if id == model.records.first?.id {
            listScroll.scrollToTop()
        } else {
            proxy.scrollTo(id)
        }
    }

    private func listRow(_ record: ClipboardRecord, number: Int?) -> some View {
        ClipboardRow(record: record, shortcutNumber: number)
            .id(record.id)
            .background(OverlayScrollerStyle(handle: listScroll))
            .listRowSeparator(.hidden)
            .listRowBackground(
                // Primary at low opacity reads as a neutral gray wash in both
                // light and dark appearances.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selection == record.id ? 0.15 : 0))
                    .padding(.horizontal, 6)
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
        HStack(spacing: 14) {
            hint("↑↓", "Navigate")
            hint("↩", pasteHintLabel)
            hint("⌘↩", "Copy")
            hint("⇧↩", "Plain Text")
            hint("⌥↩", "OCR Text")
            hint("⌘⌫", "Delete")
            Spacer()
            Text("\(model.records.count) shown")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var pasteHintLabel: String {
        if let target = model.pasteTargetName, !target.isEmpty {
            return "Paste to \(target)"
        }
        return "Paste"
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.tertiary)
        }
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

    // When the search field is focused, its field editor consumes modified
    // Return events before the hidden shortcut buttons ever see them —
    // intercept those combinations while the panel is key.
    private func installReturnMonitor() {
        guard returnKeyMonitor == nil else { return }
        returnKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is PacePanel else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if event.keyCode == 43, modifiers == .command {  // ⌘,
                NotificationCenter.default.post(name: .paceOpenSettings, object: nil)
                return nil
            }
            if event.keyCode == 51, modifiers == .command {  // ⌘⌫
                deleteSelected()
                return nil
            }
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }
            if modifiers == .command {
                performCopy()
                return nil
            }
            if modifiers == .option {
                performPaste(mode: .ocrText)
                return nil
            }
            if modifiers == .shift {
                performPaste(mode: .plainText)
                return nil
            }
            if modifiers.isEmpty {
                // When the search field's editor has focus, its onSubmit
                // handles Return. Anywhere else — including when focus never
                // landed — Return still pastes the selection.
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                   textView.isEditable {
                    return event
                }
                performPaste(mode: .original)
                return nil
            }
            return event
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
        let record = selectedRecord ?? model.records.first
        if let record, mode != .ocrText || record.hasOCR { onPaste(record, mode) }
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

        if let pendingDeletion,
           !model.records.contains(where: { $0.id == pendingDeletion.deletedID }) {
            // Keep the highlight on the outgoing row until this records
            // update removes it, then transfer selection directly to the
            // adjacent survivor as the list closes the gap.
            selection = pendingDeletion.replacementID.flatMap { replacementID in
                model.records.contains(where: { $0.id == replacementID }) ? replacementID : nil
            } ?? firstID
            self.pendingDeletion = nil
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
    weak var scrollView: NSScrollView?

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
// scroll view back through `handle` for direct scrolling.
private struct OverlayScrollerStyle: NSViewRepresentable {
    var handle: ScrollViewHandle?

    init(handle: ScrollViewHandle? = nil) {
        self.handle = handle
    }

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
