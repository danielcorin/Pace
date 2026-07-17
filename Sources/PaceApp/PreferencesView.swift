import PaceCore
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hotKeyChoice") private var hotKeyRawValue = HotKeyShortcut.defaultShortcut.storedValue

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

            retentionTab
                .tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 560, height: 460)
        .onAppear(perform: load)
    }

    private var currentShortcut: HotKeyShortcut {
        HotKeyShortcut(storedValue: hotKeyRawValue) ?? .defaultShortcut
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                LabeledContent {
                    HotKeyRecorder(
                        shortcut: currentShortcut,
                        onBeginRecording: { AppRuntime.shared.suspendHotKey() },
                        onComplete: finishRecording
                    )
                    .frame(width: 150, height: 28)
                } label: {
                    Text("Show Pace")
                    Text("Global keyboard shortcut to open the clipboard panel")
                }

                if let shortcutMessage {
                    feedbackRow(shortcutMessage, systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
            }

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
            _ = AppRuntime.shared.updateHotKey(currentShortcut)
            return
        }

        if AppRuntime.shared.updateHotKey(shortcut) {
            hotKeyRawValue = shortcut.storedValue
            withAnimation(Self.quickFade) { shortcutMessage = nil }
        } else {
            _ = AppRuntime.shared.updateHotKey(currentShortcut)
            withAnimation(Self.quickFade) {
                shortcutMessage = "That shortcut is already in use. Your previous shortcut is still active."
            }
        }
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

    private func load() {
        let policy = model.retentionPolicy
        unlimitedDays = policy.maximumAgeDays == nil
        unlimitedItems = policy.maximumItemCount == nil
        unlimitedStorage = policy.maximumStorageBytes == nil
        days = policy.maximumAgeDays.map(String.init) ?? "30"
        items = policy.maximumItemCount.map(String.init) ?? "10000"
        storageMB = policy.maximumStorageBytes.map { String($0 / 1_000_000) } ?? "1000"
        protectsPinnedItems = policy.protectsPinnedItems
    }
}
