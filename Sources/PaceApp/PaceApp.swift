import AppKit
import PaceCore
import SwiftUI

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let model = AppModel()
    private lazy var panel = HistoryPanelCoordinator(model: model)
    private let hotKey = GlobalHotKey()
    private var socketServer: LocalSocketServer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        model.start()
        Task { await model.unlock() }
        _ = updateHotKey(rawValue: UserDefaults.standard.string(forKey: "hotKeyChoice"))

        let server = LocalSocketServer { [model] request in
            await model.handle(request)
        }
        do {
            try server.start()
            socketServer = server
        } catch {
            model.statusMessage = error.localizedDescription
        }
    }

    func stop() {
        socketServer?.stop()
        socketServer = nil
    }

    func togglePanel() { panel.toggle() }
    func showPanel() { panel.show() }

    @discardableResult
    func updateHotKey(rawValue: String?) -> Bool {
        updateHotKey(HotKeyShortcut(storedValue: rawValue) ?? .defaultShortcut)
    }

    @discardableResult
    func updateHotKey(_ shortcut: HotKeyShortcut) -> Bool {
        hotKey.register(shortcut: shortcut) { [weak self] in self?.togglePanel() } == noErr
    }

    func suspendHotKey() { hotKey.unregister() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppRuntime.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in AppRuntime.shared.stop() }
    }
}

@main
struct PaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(AppRuntime.shared.model)
        } label: {
            Image("MenuBarIcon")
                .accessibilityLabel("Pace")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environmentObject(AppRuntime.shared.model)
        }
    }
}

// SettingsLink alone doesn't activate the app; when the menu bar item is
// used while Pace is inactive (panel closed), the settings window would open
// behind other windows or not appear at all.
@available(macOS 14.0, *)
private struct SettingsMenuItem: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("Show Pace") { AppRuntime.shared.showPanel() }

        Divider()

        if model.capturePaused {
            Button("Resume Capture") { model.resumeCapture() }
            if let until = model.capturePausedUntil {
                Text("Capture paused until \(until.formatted(date: .omitted, time: .shortened))")
            }
        } else {
            Menu("Pause Capture") {
                Button("For 5 Minutes") { model.pauseCapture(forMinutes: 5) }
                Button("For 15 Minutes") { model.pauseCapture(forMinutes: 15) }
                Button("For 30 Minutes") { model.pauseCapture(forMinutes: 30) }
                Button("For 1 Hour") { model.pauseCapture(forMinutes: 60) }
                Divider()
                Button("Until Resumed") { model.capturePaused = true }
            }
        }

        Divider()
        Button("About Pace") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        if #available(macOS 14.0, *) {
            SettingsMenuItem()
        } else {
            Button("Settings…") {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        Divider()
        Button("Quit Pace") { NSApp.terminate(nil) }
    }
}
