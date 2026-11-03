import AppKit
import PaceCore
import SwiftUI
import UniformTypeIdentifiers

/// The Actions scope of the panel: scripts from the actions folder that run
/// on the clipboard (or a history item), with their runs listed above them.
struct ActionsView<ScopePicker: View>: View {
    private enum Field: Hashable {
        case search
        case argument
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var center: ActionCenter
    let scopePicker: ScopePicker
    @FocusState private var focus: Field?
    @State private var arguments: [String: String] = [:]
    /// The action whose run is waiting on a second ⏎ to accept the
    /// sensitive-input warning.
    @State private var awaitingApprovalFor: String?
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().frame(height: PanelMetrics.dividerHeight)
            HStack(spacing: 0) {
                list.frame(width: PanelMetrics.listWidth)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            focus = .search
            installKeyMonitor()
        }
        .onDisappear(perform: removeKeyMonitor)
        .onReceive(NotificationCenter.default.publisher(for: .paceHistoryPanelDidShow)) { _ in
            focus = .search
        }
        .onChange(of: center.query) { _ in center.selectFirstMatch() }
        .onChange(of: center.selection) { selected in
            if selected != awaitingApprovalFor.map(ActionsSelection.action) { awaitingApprovalFor = nil }
        }
        .onChange(of: center.input?.id) { _ in awaitingApprovalFor = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            scopePicker
            Divider().frame(height: 18)
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if center.query.isEmpty {
                    Text("Search actions")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .allowsHitTesting(false)
                }
                TextField("", text: $center.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focus, equals: .search)
                    .onSubmit(performPrimary)
                    .accessibilityLabel("Search actions")
            }
            if !center.query.isEmpty {
                Button { center.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear Search")
                .accessibilityLabel("Clear search")
            }
            InputChip(input: center.input)
            Button { center.openActionsFolder() } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Actions Folder (⌘O)")
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.searchHeight)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let activeRuns = center.activeRuns
                    let completedCount = center.completedRuns.count
                    let actions = center.visibleActions
                    let hasRuns = !activeRuns.isEmpty || completedCount > 0
                    if hasRuns {
                        sectionHeader("Runs")
                        ForEach(activeRuns) { runRow($0) }
                        if completedCount > 0 {
                            CompletedRunsRow(count: completedCount, isExpanded: center.showsCompletedRuns)
                                .modifier(ActionListRow(isSelected: center.selection == .completedRuns, height: 32))
                                .id(ActionsSelection.completedRuns)
                                .onTapGesture {
                                    center.selection = .completedRuns
                                    withAnimation(.easeOut(duration: 0.15)) { center.toggleCompletedRuns() }
                                }
                                .contextMenu {
                                    Button(center.showsCompletedRuns ? "Hide Completed Runs" : "Show Completed Runs") {
                                        center.toggleCompletedRuns()
                                    }
                                    Button("Clear Completed Runs", role: .destructive) { center.clearCompletedRuns() }
                                }
                            ForEach(center.listedCompletedRuns) { runRow($0) }
                        }
                    }
                    if !actions.isEmpty {
                        if hasRuns { sectionHeader("Actions") }
                        ForEach(actions) { action in
                            ActionRow(action: action, blockingReason: center.blockingReason(for: action))
                                .modifier(ActionListRow(isSelected: center.selection == .action(action.id)))
                                .id(ActionsSelection.action(action.id))
                                .onTapGesture(count: 2) { attemptRun(action, skippingArgument: false) }
                                .simultaneousGesture(TapGesture().onEnded { center.selection = .action(action.id) })
                                .contextMenu { actionMenu(action) }
                        }
                    }
                    if actions.isEmpty, !hasRuns {
                        listEmptyState
                    }
                }
                .padding(.vertical, 2)
                .background(OverlayScrollerStyle())
            }
            .onChange(of: center.selection) { selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selected) }
            }
        }
    }

    private func runRow(_ run: ActionRun) -> some View {
        RunRow(run: run)
            .modifier(ActionListRow(isSelected: center.selection == .run(run.id)))
            .id(ActionsSelection.run(run.id))
            .onTapGesture(count: 2) { center.performPrimary(on: run) }
            .simultaneousGesture(TapGesture().onEnded { center.selection = .run(run.id) })
            .contextMenu { runMenu(run) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 24, alignment: .bottomLeading)
    }

    private var listEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: center.query.isEmpty ? "bolt" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(center.query.isEmpty ? "No Actions Yet" : "No Results")
                .font(.headline)
            Text(center.query.isEmpty
                ? "Add executable scripts to the actions folder, or run `pace actions new <name>`."
                : "Try a different search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if center.query.isEmpty {
                Button("Open Actions Folder") { center.openActionsFolder() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func runMenu(_ run: ActionRun) -> some View {
        if run.isRunning {
            Button("Cancel") { center.cancel(run) }
        } else {
            if let confirmTitle = run.confirmTitle {
                Button(confirmTitle) { center.confirm(run) }
            }
            if let undoTitle = run.undoTitle {
                Button(undoTitle) { center.undo(run) }
            }
            Button("Paste Result") { center.pasteResult(of: run) }
                .disabled(!run.hasResultText)
            Button("Copy Result") { center.copyResult(of: run) }
                .disabled(!run.hasResultText && run.attachments.isEmpty)
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([run.session.directory.outputURL])
        }
        Button("Edit Script") { center.edit(run.action) }
        Divider()
        Button("Dismiss", role: .destructive) { center.dismiss(run) }
    }

    @ViewBuilder
    private func actionMenu(_ action: PaceAction) -> some View {
        Button("Run") { attemptRun(action, skippingArgument: true) }
            .disabled(center.blockingReason(for: action) != nil)
        Divider()
        Button("Edit Script") { center.edit(action) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([action.fileURL]) }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch center.selection {
        case .run(let id)?:
            if let run = center.run(id: id) {
                RunDetail(run: run)
            } else {
                placeholder
            }
        case .action(let id)?:
            if let action = center.action(id: id) {
                ActionDetail(
                    action: action,
                    input: center.input,
                    blockingReason: center.blockingReason(for: action),
                    argument: Binding(
                        get: { arguments[action.id] ?? "" },
                        set: { arguments[action.id] = $0 }
                    ),
                    argumentFocus: $focus,
                    argumentField: .argument,
                    showsSensitiveWarning: center.input?.isSensitive == true && !center.sensitiveInputApproved,
                    awaitingSensitiveApproval: awaitingApprovalFor == action.id,
                    onRun: { attemptRun(action, skippingArgument: true) },
                    onEdit: { center.edit(action) }
                )
                .id(action.id)
            } else {
                placeholder
            }
        case .completedRuns?:
            completedRunsDetail
        case nil:
            placeholder
        }
    }

    private var completedRunsDetail: some View {
        let count = center.completedRuns.count
        return VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(count == 1 ? "1 completed run" : "\(count) completed runs")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button(center.showsCompletedRuns ? "Hide" : "Show") { center.toggleCompletedRuns() }
                Button("Clear All", role: .destructive) { center.clearCompletedRuns() }
            }
            .controlSize(.small)
            Text("\(PanelShortcuts.shortcut(for: .paste).displayLabel) \(center.showsCompletedRuns ? "Hide" : "Show") · \(PanelShortcuts.shortcut(for: .delete).displayLabel) Clear All")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No Selection")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Commands

    private var selectedRun: ActionRun? {
        guard case .run(let id)? = center.selection else { return nil }
        return center.run(id: id)
    }

    private var selectedAction: PaceAction? {
        guard case .action(let id)? = center.selection else { return nil }
        return center.action(id: id)
    }

    /// ⏎: on an action, move to its instructions field first (when it has
    /// one), then run; on a run, confirm, paste, or open its result.
    private func performPrimary() {
        if center.selection == .completedRuns {
            withAnimation(.easeOut(duration: 0.15)) { center.toggleCompletedRuns() }
        } else if let run = selectedRun {
            center.performPrimary(on: run)
        } else if let action = selectedAction {
            attemptRun(action, skippingArgument: focus == .argument)
        }
    }

    private func attemptRun(_ action: PaceAction, skippingArgument: Bool) {
        center.selection = .action(action.id)
        guard center.blockingReason(for: action) == nil else {
            NSSound.beep()
            return
        }
        if action.argument != nil, !skippingArgument {
            focus = .argument
            return
        }
        if center.input?.isSensitive == true, !center.sensitiveInputApproved {
            guard awaitingApprovalFor == action.id else {
                awaitingApprovalFor = action.id
                return
            }
            center.sensitiveInputApproved = true
            awaitingApprovalFor = nil
        }
        center.run(action, argument: arguments[action.id] ?? "")
        arguments[action.id] = nil
        focus = .search
    }

    // The search field's editor swallows some modified keys before hidden
    // buttons see them, so panel commands are read here, honoring the
    // shortcuts configured in Settings.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow is PacePanel, model.panelScope == .actions else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView
            let editingText = textView?.isEditable == true
            switch (event.keyCode, modifiers) {
            case (125, []), (126, []):  // ↓ ↑
                // The multi-line instructions field moves between its lines.
                if focus == .argument { return event }
                center.moveSelection(event.keyCode == 125 ? 1 : -1)
                return nil
            case (47, .command):  // ⌘.
                if let run = selectedRun, run.isRunning { center.cancel(run) }
                return nil
            case (6, .command):  // ⌘Z
                guard let run = selectedRun, run.undoTitle != nil else { return event }
                center.undo(run)
                return nil
            case (14, .command):  // ⌘E
                if let action = selectedRun?.action ?? selectedAction { center.edit(action) }
                return nil
            case (31, .command):  // ⌘O
                center.openActionsFolder()
                return nil
            case (126, .command), (125, .command):  // ⌘↑ ⌘↓
                if focus == .argument { return event }
                center.selectEdge(last: event.keyCode == 125)
                return nil
            default:
                break
            }
            guard let action = PanelShortcuts.action(matching: event) else { return event }
            switch action {
            case .paste:
                // Return finishes an input method's composition first.
                if textView?.hasMarkedText() == true { return event }
                if editingText, focus != .search, focus != .argument { return event }
                performPrimary()
            case .copy:
                if let run = selectedRun {
                    center.copyResult(of: run)
                } else if let selected = selectedAction {
                    attemptRun(selected, skippingArgument: true)
                }
            case .delete where center.selection == .completedRuns:
                center.clearCompletedRuns()
            case .delete:
                guard let run = selectedRun else { return event }
                center.dismiss(run)
            case .pastePlainText, .pasteSingleLine, .pasteOCRText, .saveAsSnippet:
                return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Rows

private struct ActionListRow: ViewModifier {
    let isSelected: Bool
    var height = PanelMetrics.listUnitHeight

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .modifier(RowHighlight(isSelected: isSelected))
            .contentShape(Rectangle())
    }
}

private struct CompletedRunsRow: View {
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 28)
            Text("Completed")
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) completed runs")
        .accessibilityHint(isExpanded ? "Hides them" : "Shows them")
    }
}

private struct ActionRow: View {
    let action: PaceAction
    let blockingReason: String?

    var body: some View {
        HStack(spacing: 10) {
            ActionIcon(symbol: action.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let blockingReason {
                    Label(blockingReason, systemImage: action.isRunnable ? "nosign" : "exclamationmark.triangle")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 11))
                        .foregroundStyle(action.isRunnable ? Color.secondary : Color.orange)
                        .lineLimit(1)
                } else if let summary = action.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            RequirementBadges(action: action, compact: true)
        }
        .opacity(blockingReason == nil ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityHint(blockingReason ?? "")
    }
}

private struct RunRow: View {
    @ObservedObject var run: ActionRun

    var body: some View {
        HStack(spacing: 10) {
            RunStatusIcon(run: run)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.action.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(subtitle(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func subtitle(now: Date) -> String {
        if run.isRunning {
            let elapsed = Int(now.timeIntervalSince(run.stepStartedAt))
            return "\(run.statusLine ?? "Running…") · \(elapsed)s"
        }
        guard let result = run.result else { return "" }
        if !result.termination.succeeded {
            return "\(ActionCenter.failureSummary(result.termination).capitalizedFirst)"
        }
        if let confirmTitle = run.confirmTitle { return "Waiting: \(confirmTitle)" }
        if let line = run.firstResultLine { return line }
        let count = run.attachments.count
        if count > 0 { return count == 1 ? run.attachments[0].name : "\(count) files" }
        return "Finished"
    }
}

private struct RunStatusIcon: View {
    @ObservedObject var run: ActionRun

    var body: some View {
        if run.isRunning {
            ProgressView().controlSize(.small)
        } else if let result = run.result {
            Image(systemName: symbol(result))
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint(result))
        }
    }

    private func symbol(_ result: ActionStepResult) -> String {
        switch result.termination {
        case .exited(0): return run.confirmTitle != nil ? "hand.raised.circle.fill" : "checkmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .timedOut: return "clock.badge.exclamationmark"
        default: return "xmark.octagon.fill"
        }
    }

    private func tint(_ result: ActionStepResult) -> Color {
        switch result.termination {
        case .exited(0): return run.confirmTitle != nil ? .orange : .green
        case .cancelled: return .secondary
        default: return .red
        }
    }
}

private struct ActionIcon: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? PaceAction.defaultIcon : symbol)
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

/// Small symbols for each kind of input an action takes, so it's clear at a
/// glance why a row is dimmed.
private struct RequirementBadges: View {
    let action: PaceAction
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            if action.acceptsAnything {
                badge(.any)
            } else {
                ForEach(action.accepts, id: \.self) { badge($0) }
            }
        }
    }

    @ViewBuilder
    private func badge(_ requirement: ActionRequirement) -> some View {
        if compact {
            Image(systemName: requirement.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .help("Accepts \(requirement.displayName.lowercased())")
        } else {
            Label(requirement.displayName, systemImage: requirement.symbol)
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
    }
}

private struct InputChip: View {
    let input: PanelActionInput?

    var body: some View {
        HStack(spacing: 5) {
            if input?.isSensitive == true {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
            }
            Image(systemName: input?.summary.primaryKind?.symbol ?? "clipboard")
            Text(input?.label ?? "Empty clipboard")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .frame(maxWidth: 200)
        .fixedSize()
        .help(input.map { "Input: \($0.originTitle.lowercased())" } ?? "The clipboard is empty")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Action detail

private struct ActionDetail<Field: Hashable>: View {
    let action: PaceAction
    let input: PanelActionInput?
    let blockingReason: String?
    @Binding var argument: String
    var argumentFocus: FocusState<Field?>.Binding
    let argumentField: Field
    let showsSensitiveWarning: Bool
    let awaitingSensitiveApproval: Bool
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        ActionIcon(symbol: action.icon, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.title).font(.headline)
                            if let summary = action.summary {
                                Text(summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    InputPreviewCard(input: input)
                    requirements
                    if let argumentLabel = action.argument {
                        TextField(argumentLabel, text: $argument, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .lineLimit(1...5)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color(nsColor: .separatorColor))
                            )
                            .focused(argumentFocus, equals: argumentField)
                            .onSubmit(onRun)
                            .disabled(blockingReason != nil)
                    }
                    if showsSensitiveWarning, blockingReason == nil {
                        sensitiveWarning
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Text(KeyHints.join(hints))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("Edit Script", action: onEdit)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                Button(awaitingSensitiveApproval ? "Run Anyway" : "Run", action: onRun)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(blockingReason != nil)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
        }
    }

    private var hints: [String] {
        let run = PanelShortcuts.shortcut(for: .paste).displayLabel
        if action.argument != nil {
            return ["\(run) Instructions, then \(run) Run", "\(PanelShortcuts.shortcut(for: .copy).displayLabel) Run Now", "⌘E Edit"]
        }
        return ["\(run) Run", "⌘E Edit"]
    }

    @ViewBuilder
    private var requirements: some View {
        HStack(spacing: 6) {
            Text("Accepts")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            RequirementBadges(action: action)
            Spacer(minLength: 0)
        }
        if !action.issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(action.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(CompactLabelStyle())
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let blockingReason {
            Label(
                "\(blockingReason). The \(input?.originTitle.lowercased() ?? "clipboard") has \(inputDescription).",
                systemImage: "nosign"
            )
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputDescription: String {
        guard let kinds = input?.summary.kinds, !kinds.isEmpty else { return "nothing usable" }
        let names = ActionInputKind.allCases.filter(kinds.contains).map { $0.displayName.lowercased() }
        return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    private var sensitiveWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This looks sensitive", systemImage: "lock.fill")
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("It may be a password, key, or card number. Running writes it to a private temporary file and hands it to this script.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if awaitingSensitiveApproval {
                Text("Press \(PanelShortcuts.shortcut(for: .paste).displayLabel) again to run anyway.")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(awaitingSensitiveApproval ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InputPreviewCard: View {
    let input: PanelActionInput?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: input?.summary.primaryKind?.symbol ?? "clipboard")
                Text(input.map { "\($0.originTitle) · \($0.label)" } ?? "The clipboard is empty")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let input {
            if let thumbnail = input.thumbnail, input.summary.kinds.contains(.image) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 120, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if input.summary.kinds.contains(.files) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(input.input.fileURLs.prefix(4), id: \.self) { file in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12))
                    }
                    if input.input.fileURLs.count > 4 {
                        Text("and \(input.input.fileURLs.count - 4) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if input.isSensitive {
                Text("Hidden because it looks sensitive")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else if let text = input.textPreview, !text.isEmpty {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Run detail

private struct RunDetail: View {
    @EnvironmentObject private var center: ActionCenter
    @ObservedObject var run: ActionRun

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !run.argument.isEmpty {
                            Text("“\(run.argument)”")
                                .font(.system(size: 12))
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        ForEach(Array(run.segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 { stepDivider(segment.step) }
                            if !segment.output.isEmpty { ActionOutputText(text: segment.output) }
                        }
                        status
                        if !run.attachments.isEmpty {
                            AttachmentList(attachments: run.attachments) { attachment in
                                center.copyAttachments([attachment], from: run)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: run.segments.last?.output.utf8.count) { _ in
                    guard run.isRunning else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RunStatusIcon(run: run).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.action.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(run.inputLabel) · \(elapsed(now: context.date))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if run.isRunning {
                Button("Cancel") { center.cancel(run) }
                    .controlSize(.small)
                    .help("Cancel (⌘.)")
            } else {
                Button { center.dismiss(run) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss (\(PanelShortcuts.shortcut(for: .delete).displayLabel))")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private func elapsed(now: Date) -> String {
        let end = run.finishedAt ?? now
        let seconds = max(0, Int(end.timeIntervalSince(run.stepStartedAt)))
        let duration = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        if run.isRunning { return "running \(duration)" }
        return "took \(duration)"
    }

    private func stepDivider(_ step: ActionStep) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(step == .confirm ? "Confirmed" : step == .undo ? "Undo" : "Run")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private var status: some View {
        if run.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(run.statusLine ?? "Running…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else if let result = run.result, !result.termination.succeeded {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(run.action.title) \(ActionCenter.failureSummary(result.termination))",
                    systemImage: result.termination == .cancelled ? "stop.circle" : "xmark.octagon"
                )
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(result.termination == .cancelled ? Color.secondary : Color.red)
                if !run.log.isEmpty {
                    Text(String(run.log.suffix(6_000)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        } else if run.segments.allSatisfy({ $0.output.isEmpty }), run.attachments.isEmpty {
            Text("Finished with no output.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(KeyHints.join(hints))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            if let undoTitle = run.undoTitle {
                Button(undoTitle) { center.undo(run) }
                    .controlSize(.small)
                    .help("⌘Z")
            }
            if let confirmTitle = run.confirmTitle {
                Button(confirmTitle) { center.confirm(run) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help(PanelShortcuts.shortcut(for: .paste).displayLabel)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var hints: [String] {
        if run.isRunning { return ["⌘. Cancel", "Esc Hide (keeps running)"] }
        let primary = PanelShortcuts.shortcut(for: .paste).displayLabel
        var hints: [String] = []
        if let confirmTitle = run.confirmTitle {
            hints.append("\(primary) \(confirmTitle)")
        } else if run.hasResultText {
            hints.append("\(primary) Paste")
        }
        if run.hasResultText || !run.attachments.isEmpty {
            hints.append("\(PanelShortcuts.shortcut(for: .copy).displayLabel) Copy")
        }
        hints.append("\(PanelShortcuts.shortcut(for: .delete).displayLabel) Dismiss")
        return hints
    }
}

/// Script output rendered as light Markdown: inline styles and links, with
/// headings bolded and list dashes turned into bullets.
private struct ActionOutputText: View {
    let text: String

    var body: some View {
        Group {
            if text.utf8.count > 80_000 {
                Text(verbatim: text).font(.system(size: 12, design: .monospaced))
            } else {
                Text(Self.render(text)).font(.system(size: 13))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func render(_ text: String) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            if let match = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return "**\(trimmed[match.upperBound...])**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let indent = String(repeating: " ", count: line.count - trimmed.count)
                return indent + "• " + trimmed.dropFirst(2)
            }
            return String(line)
        }
        let source = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
    }
}

private struct AttachmentList: View {
    let attachments: [ActionAttachment]
    let onCopy: (ActionAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                AttachmentView(attachment: attachment, onCopy: { onCopy(attachment) })
            }
        }
    }
}

private struct AttachmentView: View {
    let attachment: ActionAttachment
    let onCopy: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Group {
            if attachment.isImage, let image {
                VStack(alignment: .leading, spacing: 4) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 240, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    caption
                }
            } else {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    caption
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(attachment.url) }
        .onDrag { NSItemProvider(contentsOf: attachment.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(attachment.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
            Button("Copy", action: onCopy)
        }
        .help("Double-click to open, or drag it out")
        .task(id: attachment.url) {
            guard attachment.isImage else { return }
            let url = attachment.url
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            image = data.flatMap { ActionCenter.downsampled($0, maxPixelSize: 900)?.image }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(attachment.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(panelByteFormatter.string(fromByteCount: attachment.byteCount))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Symbols

extension ActionInputKind {
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .url: return "link"
        case .files: return "doc.on.doc"
        }
    }
}

extension ActionRequirement {
    var symbol: String {
        switch self {
        case .any: return "square.dashed"
        case .kind(let kind): return kind.symbol
        case .type(let identifier):
            guard let type = UTType(identifier) else { return "doc" }
            if type.conforms(to: .movie) { return "film" }
            if type.conforms(to: .audio) { return "waveform" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .text) { return "doc.plaintext" }
            return "doc"
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
