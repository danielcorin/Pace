import AppKit
import PaceCore
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hotKeyChoice") private var hotKeyRawValue = HotKeyShortcut.defaultShortcut.storedValue
    @AppStorage("snippetHotKeyChoice") private var snippetHotKeyRawValue = HotKeyShortcut.defaultSnippetShortcut.storedValue
    @AppStorage(SnippetExpansionPreferences.enabledKey) private var snippetExpansionEnabled = true
    @AppStorage(SnippetExpansionPreferences.modeKey) private var snippetExpansionMode = SnippetExpansionMode.immediately.rawValue
    @AppStorage(SnippetExpansionPreferences.restoreClipboardKey) private var restoresClipboardAfterExpansion = true
    @AppStorage(SnippetExpansionPreferences.defaultPrefixKey) private var defaultSnippetPrefix = ";"
    @AppStorage(SnippetExpansionPreferences.injectionDelayKey) private var snippetInjectionDelay = 0.04

    @State private var days = "30"
    @State private var items = "10000"
    @State private var storageMB = "1000"
    @State private var unlimitedDays = false
    @State private var unlimitedItems = false
    @State private var unlimitedStorage = false
    @State private var protectsPinnedItems = true

    @State private var cleanupOutcome: CleanupOutcome?
    @State private var isCleaningUp = false
    @State private var cliFeedback: Feedback?
    @State private var shortcutMessage: String?
    @State private var panelShortcuts: [PanelAction: HotKeyShortcut] = [:]
    @State private var excludedSnippetApplications: [String] = []

    private struct Feedback: Equatable {
        var message: String
        var isError: Bool
    }

    private enum CleanupOutcome: Equatable {
        case preview(RetentionReport)
        case applied(RetentionReport)
    }

    private static let quickFade = Animation.easeOut(duration: 0.15)

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "command") }

            snippetsTab
                .tabItem { Label("Snippets", systemImage: "text.quote") }

            retentionTab
                .tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 560, height: 460)
        .onAppear(perform: load)
    }

    private var currentShortcut: HotKeyShortcut {
        HotKeyShortcut(storedValue: hotKeyRawValue) ?? .defaultShortcut
    }

    private var currentSnippetShortcut: HotKeyShortcut {
        HotKeyShortcut(storedValue: snippetHotKeyRawValue) ?? .defaultSnippetShortcut
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle(isOn: $model.capturePaused) {
                    Text("Pause clipboard capture")
                    if let until = model.capturePausedUntil {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("New copies aren't saved while paused")
                    }
                }
                LabeledContent {
                    Menu("Pause For") {
                        Button("5 Minutes") { model.pauseCapture(forMinutes: 5) }
                        Button("15 Minutes") { model.pauseCapture(forMinutes: 15) }
                        Button("30 Minutes") { model.pauseCapture(forMinutes: 30) }
                        Button("1 Hour") { model.pauseCapture(forMinutes: 60) }
                    }
                    .fixedSize()
                } label: {
                    Text("Pause temporarily")
                    Text("Capture resumes automatically when time is up")
                }
                Toggle(isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )) {
                    Text("Launch Pace at login")
                    Text("Start Pace automatically after you sign in")
                }
            }
            .toggleStyle(.switch)

            Section {
                LabeledContent {
                    Button("Install") { installCLI() }
                } label: {
                    Text("Command Line Tool")
                    Text("Adds the pace command at ~/.local/bin/pace")
                }

                if let cliFeedback {
                    feedbackRow(
                        cliFeedback.message,
                        systemImage: cliFeedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        color: cliFeedback.isError ? .orange : .green
                    )
                }
            } footer: {
                footerText {
                    HStack(alignment: .firstTextBaseline) {
                        Spacer()
                        Text("Pace \(appVersion)")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts

    private var shortcutsTab: some View {
        Form {
            Section {
                LabeledContent {
                    HotKeyRecorder(
                        shortcut: currentShortcut,
                        actionName: "Show Clipboard",
                        onBeginRecording: { AppRuntime.shared.suspendHotKeys() },
                        onComplete: finishRecording
                    )
                    .frame(width: 150, height: 28)
                } label: {
                    Text("Show Clipboard")
                    Text("Global keyboard shortcut to open the clipboard panel")
                }
                LabeledContent {
                    HotKeyRecorder(
                        shortcut: currentSnippetShortcut,
                        actionName: "Show Snippets",
                        onBeginRecording: { AppRuntime.shared.suspendHotKeys() },
                        onComplete: finishSnippetRecording
                    )
                    .frame(width: 150, height: 28)
                } label: {
                    Text("Show Snippets")
                    Text("Global keyboard shortcut to open the snippet library")
                }
            }

            Section {
                ForEach(PanelAction.allCases) { action in
                    LabeledContent {
                        HotKeyRecorder(
                            shortcut: panelShortcut(for: action),
                            captureContext: .panel,
                            actionName: action.title,
                            onBeginRecording: { AppRuntime.shared.suspendHotKeys() },
                            onComplete: { finishPanelRecording(for: action, shortcut: $0) }
                        )
                        .frame(width: 150, height: 28)
                    } label: {
                        Text(action.title)
                        Text(action.subtitle)
                    }
                }

                if let shortcutMessage {
                    feedbackRow(shortcutMessage, systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
            } header: {
                Text("In the Panel")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { restoreDefaultPanelShortcuts() }
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Snippets

    private var snippetsTab: some View {
        Form {
            Section {
                Toggle(isOn: $snippetExpansionEnabled) {
                    Text("Expand snippets while typing")
                    Text("Replace configured keywords in other applications")
                }
                .toggleStyle(.switch)
                .onChange(of: snippetExpansionEnabled) { _ in
                    model.refreshSnippetExpansionSettings()
                }

                Picker("Expansion mode", selection: $snippetExpansionMode) {
                    ForEach(SnippetExpansionMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .onChange(of: snippetExpansionMode) { _ in
                    model.refreshSnippetExpansionSettings()
                }

                LabeledContent {
                    TextField("", text: $defaultSnippetPrefix)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 90)
                } label: {
                    Text("Default keyword prefix")
                    Text("Prefills the keyword when creating a snippet")
                }

                Toggle(isOn: $restoresClipboardAfterExpansion) {
                    Text("Restore clipboard after pasting")
                    Text("Snippet insertion won't replace what you previously copied")
                }
                .toggleStyle(.switch)

                Picker("Compatibility delay", selection: $snippetInjectionDelay) {
                    Text("Fast").tag(0.02)
                    Text("Normal").tag(0.04)
                    Text("Slow").tag(0.10)
                    Text("Extra Slow").tag(0.18)
                }
            } header: {
                HStack {
                    Text("Expansion")
                    Spacer()
                    Button("Open Snippets") {
                        AppRuntime.shared.showPanel(scope: .snippets)
                    }
                    .font(.caption)
                }
            }

            Section {
                ForEach(excludedSnippetApplications, id: \.self) { bundleID in
                    HStack {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                        Text(applicationName(for: bundleID))
                        Spacer()
                        Text(bundleID)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Button {
                            removeExcludedApplication(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Add Application…") { addExcludedApplication() }
            } header: {
                Text("Disabled Applications")
            } footer: {
                footerText {
                    Text("Pace never expands in secure text fields. Keychain Access and common password managers are always excluded.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Retention

    private var retentionTab: some View {
        Form {
            Section {
                limitRow("Keep history for", value: $days, unit: "days", unlimited: $unlimitedDays)
                limitRow("Maximum entries", value: $items, unit: "items", unlimited: $unlimitedItems)
                limitRow("Maximum storage", value: $storageMB, unit: "MB", unlimited: $unlimitedStorage)
            } footer: {
                footerText {
                    Text("When a limit is exceeded, the oldest unpinned items are removed first.")
                }
            }

            Section {
                Toggle(isOn: $protectsPinnedItems) {
                    Text("Protect pinned items")
                    Text("Pinned items are never removed by cleanup")
                }
                .toggleStyle(.switch)

                HStack(spacing: 10) {
                    Button("Preview Cleanup") { runCleanup(prune: false) }
                        .disabled(isCleaningUp || draftPolicy == nil)
                    Button("Apply and Clean Up") { runCleanup(prune: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isCleaningUp || draftPolicy == nil)
                    if isCleaningUp {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if let cleanupOutcome {
                    outcomeRow(cleanupOutcome)
                }
            } footer: {
                footerText { Text(storageFooter) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: draftPolicy) { _ in
            guard cleanupOutcome != nil else { return }
            withAnimation(Self.quickFade) { cleanupOutcome = nil }
        }
    }

    private func limitRow(
        _ title: String,
        value: Binding<String>,
        unit: String,
        unlimited: Binding<Bool>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                TextField("", text: value, prompt: Text("1"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 72)
                    .disabled(unlimited.wrappedValue)
                    .opacity(unlimited.wrappedValue ? 0.5 : 1)
                    .onChange(of: value.wrappedValue) { newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(9))
                        if digits != newValue { value.wrappedValue = digits }
                    }
                Text(unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)
                Toggle("Unlimited", isOn: unlimited)
                    .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private func outcomeRow(_ outcome: CleanupOutcome) -> some View {
        switch outcome {
        case .preview(let report) where report.itemCount == 0:
            feedbackRow(
                "Nothing to clean up — everything is within these limits.",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .preview(let report):
            feedbackRow(
                "Cleanup would remove \(itemsPhrase(report.itemCount)) (\(byteString(report.byteCount))).",
                systemImage: "info.circle.fill",
                color: .blue
            )
        case .applied(let report) where report.itemCount == 0:
            feedbackRow(
                "Settings applied. No items needed to be removed.",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .applied(let report):
            feedbackRow(
                "Settings applied. Removed \(itemsPhrase(report.itemCount)) (\(byteString(report.byteCount))).",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
    }

    private func feedbackRow(_ message: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .transition(.opacity)
    }

    private func footerText(@ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var storageFooter: String {
        model.vaultState == .unlocked
            ? "Current history size: \(byteString(model.storageBytes))."
            : "Unlock Pace to see the current history size."
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private func byteString(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func itemsPhrase(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }

    // MARK: - Actions

    /// The retention policy the current form values describe, or nil while a
    /// non-unlimited field is empty or zero (buttons stay disabled until valid).
    private var draftPolicy: RetentionPolicy? {
        var policy = RetentionPolicy(
            maximumAgeDays: nil,
            maximumItemCount: nil,
            maximumStorageBytes: nil,
            protectsPinnedItems: protectsPinnedItems
        )
        if !unlimitedDays {
            guard let value = Int(days), value >= 1 else { return nil }
            policy.maximumAgeDays = value
        }
        if !unlimitedItems {
            guard let value = Int(items), value >= 1 else { return nil }
            policy.maximumItemCount = value
        }
        if !unlimitedStorage {
            guard let value = Int64(storageMB), value >= 1 else { return nil }
            policy.maximumStorageBytes = value * 1_000_000
        }
        return policy
    }

    private func runCleanup(prune: Bool) {
        guard let policy = draftPolicy, !isCleaningUp else { return }
        isCleaningUp = true
        Task {
            let report: RetentionReport?
            if prune {
                report = await model.updateRetention(policy, pruneImmediately: true)
            } else {
                _ = await model.updateRetention(policy, pruneImmediately: false)
                report = await model.retentionPreview()
            }
            withAnimation(Self.quickFade) {
                if let report {
                    cleanupOutcome = prune ? .applied(report) : .preview(report)
                }
                isCleaningUp = false
            }
        }
    }

    private func finishRecording(_ shortcut: HotKeyShortcut?) {
        guard let shortcut else {
            AppRuntime.shared.restoreHotKeys()
            return
        }

        if shortcut == currentSnippetShortcut {
            AppRuntime.shared.restoreHotKeys()
            showShortcutConflict(with: "Show Snippets")
            return
        }
        if let taken = PanelAction.allCases.first(where: { panelShortcut(for: $0) == shortcut }) {
            AppRuntime.shared.restoreHotKeys()
            showShortcutConflict(with: taken.title)
            return
        }
        if AppRuntime.shared.updateHotKey(shortcut) {
            hotKeyRawValue = shortcut.storedValue
            AppRuntime.shared.restoreHotKeys()
            withAnimation(Self.quickFade) { shortcutMessage = nil }
        } else {
            AppRuntime.shared.restoreHotKeys()
            withAnimation(Self.quickFade) {
                shortcutMessage = "That shortcut is already in use. Your previous shortcut is still active."
            }
        }
    }

    private func finishSnippetRecording(_ shortcut: HotKeyShortcut?) {
        guard let shortcut else {
            AppRuntime.shared.restoreHotKeys()
            return
        }
        if shortcut == currentShortcut {
            AppRuntime.shared.restoreHotKeys()
            showShortcutConflict(with: "Show Clipboard")
            return
        }
        if let taken = PanelAction.allCases.first(where: { panelShortcut(for: $0) == shortcut }) {
            AppRuntime.shared.restoreHotKeys()
            showShortcutConflict(with: taken.title)
            return
        }
        if AppRuntime.shared.updateSnippetHotKey(shortcut) {
            snippetHotKeyRawValue = shortcut.storedValue
            AppRuntime.shared.restoreHotKeys()
            withAnimation(Self.quickFade) { shortcutMessage = nil }
        } else {
            AppRuntime.shared.restoreHotKeys()
            withAnimation(Self.quickFade) {
                shortcutMessage = "That shortcut is already in use. Your previous shortcut is still active."
            }
        }
    }

    // Recording suspends the global hotkey so pressing it doesn't toggle the
    // panel; every exit path must restore it.
    private func finishPanelRecording(for action: PanelAction, shortcut: HotKeyShortcut?) {
        AppRuntime.shared.restoreHotKeys()
        guard let shortcut else { return }

        if shortcut == currentShortcut {
            showShortcutConflict(with: "Show Clipboard")
            return
        }
        if shortcut == currentSnippetShortcut {
            showShortcutConflict(with: "Show Snippets")
            return
        }
        if let taken = PanelAction.allCases.first(where: {
            $0 != action && panelShortcut(for: $0) == shortcut
        }) {
            showShortcutConflict(with: taken.title)
            return
        }
        PanelShortcuts.set(shortcut, for: action)
        panelShortcuts[action] = shortcut
        withAnimation(Self.quickFade) { shortcutMessage = nil }
    }

    private func showShortcutConflict(with name: String) {
        withAnimation(Self.quickFade) {
            shortcutMessage = "That shortcut is already used by \(name). Your previous shortcut is still active."
        }
    }

    private func panelShortcut(for action: PanelAction) -> HotKeyShortcut {
        panelShortcuts[action] ?? PanelShortcuts.shortcut(for: action)
    }

    private func restoreDefaultPanelShortcuts() {
        PanelShortcuts.restoreDefaults()
        for action in PanelAction.allCases {
            panelShortcuts[action] = action.defaultShortcut
        }
        withAnimation(Self.quickFade) { shortcutMessage = nil }
    }

    private func installCLI() {
        withAnimation(Self.quickFade) {
            do {
                let url = try CLIInstaller.install()
                let path = (url.path as NSString).abbreviatingWithTildeInPath
                cliFeedback = Feedback(message: "Installed at \(path)", isError: false)
            } catch {
                cliFeedback = Feedback(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func addExcludedApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !excludedSnippetApplications.contains(bundleID) else { return }
        excludedSnippetApplications.append(bundleID)
        excludedSnippetApplications.sort()
        persistExcludedApplications()
    }

    private func removeExcludedApplication(_ bundleID: String) {
        excludedSnippetApplications.removeAll { $0 == bundleID }
        persistExcludedApplications()
    }

    private func persistExcludedApplications() {
        UserDefaults.standard.set(
            excludedSnippetApplications,
            forKey: SnippetExpansionPreferences.excludedBundleIDsKey
        )
        model.refreshSnippetExpansionSettings()
    }

    private func applicationName(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }

    private func load() {
        let policy = model.retentionPolicy
        unlimitedDays = policy.maximumAgeDays == nil
        unlimitedItems = policy.maximumItemCount == nil
        unlimitedStorage = policy.maximumStorageBytes == nil
        days = policy.maximumAgeDays.map(String.init) ?? "30"
        items = policy.maximumItemCount.map(String.init) ?? "10000"
        storageMB = policy.maximumStorageBytes.map { String($0 / 1_000_000) } ?? "1000"
        protectsPinnedItems = policy.protectsPinnedItems
        excludedSnippetApplications = UserDefaults.standard.stringArray(
            forKey: SnippetExpansionPreferences.excludedBundleIDsKey
        ) ?? []
        for action in PanelAction.allCases {
            panelShortcuts[action] = PanelShortcuts.shortcut(for: action)
        }
    }
}
