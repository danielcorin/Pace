import AppKit
import PaceCore
import SwiftUI

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let model = AppModel()
    private lazy var panel = HistoryPanelCoordinator(model: model)
    private let hotKey = GlobalHotKey()
    private let snippetHotKey = GlobalHotKey()
    private var socketServer: LocalSocketServer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        migrateDefaultHotKeysIfNeeded()
        model.start()
        Task { await model.unlock() }
        _ = updateHotKey(rawValue: UserDefaults.standard.string(forKey: "hotKeyChoice"))
        _ = updateSnippetHotKey(rawValue: UserDefaults.standard.string(forKey: "snippetHotKeyChoice"))

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

    func togglePanel(scope: PacePanelScope = .clipboard) { panel.toggle(scope: scope) }
    func showPanel(scope: PacePanelScope = .clipboard) { panel.show(scope: scope) }

    @discardableResult
    func updateHotKey(rawValue: String?) -> Bool {
        updateHotKey(HotKeyShortcut(storedValue: rawValue) ?? .defaultShortcut)
    }

    @discardableResult
    func updateHotKey(_ shortcut: HotKeyShortcut) -> Bool {
        hotKey.register(shortcut: shortcut) { [weak self] in self?.togglePanel(scope: .clipboard) } == noErr
    }

    @discardableResult
    func updateSnippetHotKey(rawValue: String?) -> Bool {
        updateSnippetHotKey(HotKeyShortcut(storedValue: rawValue) ?? .defaultSnippetShortcut)
    }

    @discardableResult
    func updateSnippetHotKey(_ shortcut: HotKeyShortcut) -> Bool {
        snippetHotKey.register(shortcut: shortcut) { [weak self] in self?.togglePanel(scope: .snippets) } == noErr
    }

    func suspendHotKeys() {
        hotKey.unregister()
        snippetHotKey.unregister()
    }

    func restoreHotKeys() {
        _ = updateHotKey(rawValue: UserDefaults.standard.string(forKey: "hotKeyChoice"))
        _ = updateSnippetHotKey(rawValue: UserDefaults.standard.string(forKey: "snippetHotKeyChoice"))
    }

    private func migrateDefaultHotKeysIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "hotKeyDefaultsVersion"
        let version = defaults.integer(forKey: migrationKey)
        guard version < 3 else { return }

        // Version 3 corrects the first snippet build's reversed mapping and
        // applies the explicitly requested defaults to the installed app.
        if version >= 2 {
            defaults.set(HotKeyShortcut.defaultShortcut.storedValue, forKey: "hotKeyChoice")
            defaults.set(
                HotKeyShortcut.defaultSnippetShortcut.storedValue,
                forKey: "snippetHotKeyChoice"
            )
            defaults.set(3, forKey: migrationKey)
            return
        }

        let clipboardRaw = defaults.string(forKey: "hotKeyChoice")
        let clipboardShortcut = HotKeyShortcut(storedValue: clipboardRaw)
        if clipboardRaw == nil || clipboardShortcut == .previousDefaultShortcut {
            defaults.set(
                HotKeyShortcut.defaultShortcut.storedValue,
                forKey: "hotKeyChoice"
            )
        }

        let snippetRaw = defaults.string(forKey: "snippetHotKeyChoice")
        let snippetShortcut = HotKeyShortcut(storedValue: snippetRaw)
        if snippetRaw == nil || snippetShortcut == .previousDefaultSnippetShortcut {
            defaults.set(
                HotKeyShortcut.defaultSnippetShortcut.storedValue,
                forKey: "snippetHotKeyChoice"
            )
        }
        defaults.set(3, forKey: migrationKey)
    }
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
            MenuBarLabel(model: AppRuntime.shared.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environmentObject(AppRuntime.shared.model)
        }
    }
}

/// Badges the menu bar icon while Pace lacks Accessibility access, so the
/// missing grant is visible without opening the menu.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.hasAccessibilityAccess {
            Image("MenuBarIcon")
                .accessibilityLabel("Pace")
        } else {
            Image(nsImage: Self.badgedIcon)
                .accessibilityLabel("Pace, needs Accessibility access")
        }
    }

    /// The template icon with a dot in its top-right corner. A clear ring is
    /// knocked out around the dot so it reads against the glyph; staying a
    /// template keeps it right on light, dark, and tinted menu bars.
    private static let badgedIcon: NSImage = {
        let base = NSImage(named: "MenuBarIcon") ?? NSImage()
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dot = NSRect(x: size.width - 7, y: size.height - 7, width: 7, height: 7)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
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

    /// Full color so it stands out: menus render symbol images as monochrome
    /// templates unless the image opts out.
    private static let warningIcon: NSImage = {
        let symbol = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Action needed"
        )
        let colors = NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow])
        let image = symbol?.withSymbolConfiguration(colors) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    var body: some View {
        if !model.hasAccessibilityAccess {
            Button {
                model.requestAccessibilityAccess()
            } label: {
                Label {
                    Text("Grant Accessibility Access…")
                } icon: {
                    Image(nsImage: Self.warningIcon)
                }
            }
            Text("Pace needs it to paste into other apps")
            Divider()
        }

        Button("Show Clipboard") { AppRuntime.shared.showPanel(scope: .clipboard) }
        Button("Show Snippets") { AppRuntime.shared.showPanel(scope: .snippets) }

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
