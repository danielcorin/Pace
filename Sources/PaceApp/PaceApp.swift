import AppKit
import Carbon.HIToolbox
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
    private var welcomeWindow: WelcomeWindowController?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let showsWelcome = shouldShowWelcome()
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

        if showsWelcome { showWelcome() }
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

    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.show()
            return
        }
        let controller = WelcomeWindowController(model: model) { [weak self] in
            self?.welcomeWindow = nil
        }
        welcomeWindow = controller
        controller.show()
    }

    /// The welcome window appears once, on a fresh install. Earlier versions
    /// had no flag, so an existing hotkey migration marker or saved history
    /// identifies people who already use Pace. Must run before the migration
    /// below sets that marker.
    private func shouldShowWelcome() -> Bool {
        let defaults = UserDefaults.standard
        let welcomeKey = "hasShownWelcome"
        guard !defaults.bool(forKey: welcomeKey) else { return false }
        defaults.set(true, forKey: welcomeKey)

        let isExistingUser = defaults.object(forKey: "hotKeyDefaultsVersion") != nil
            || FileManager.default.fileExists(
                atPath: PacePaths.applicationSupportDirectory.appendingPathComponent("Catalog.pace").path
            )
        return !isExistingUser
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
/// missing grant is visible without opening the menu, and dims it while
/// capture is paused.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let paused = model.capturePaused
        let badged = !model.hasAccessibilityAccess
        if !paused, !badged {
            Image("MenuBarIcon")
                .accessibilityLabel("Pace")
        } else {
            Image(nsImage: Self.icon(dimmed: paused, badged: badged))
                .accessibilityLabel(spokenLabel(paused: paused, badged: badged))
        }
    }

    private func spokenLabel(paused: Bool, badged: Bool) -> String {
        var parts = ["Pace"]
        if paused { parts.append("capture paused") }
        if badged { parts.append("needs Accessibility access") }
        return parts.joined(separator: ", ")
    }

    private static func icon(dimmed: Bool, badged: Bool) -> NSImage {
        switch (dimmed, badged) {
        case (true, true): dimmedBadgedIcon
        case (true, false): dimmedIcon
        default: badgedIcon
        }
    }

    private static let badgedIcon = makeIcon(dimmed: false, badged: true)
    private static let dimmedIcon = makeIcon(dimmed: true, badged: false)
    private static let dimmedBadgedIcon = makeIcon(dimmed: true, badged: true)

    /// The template icon, optionally at half alpha and with a dot in its
    /// top-right corner. A clear ring is knocked out around the dot so it
    /// reads against the glyph, and the dot stays fully opaque on a dimmed
    /// glyph so the missing grant still stands out. Staying a template keeps
    /// it right on light, dark, and tinted menu bars.
    private static func makeIcon(dimmed: Bool, badged: Bool) -> NSImage {
        let base = NSImage(named: "MenuBarIcon") ?? NSImage()
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.5 : 1)
            guard badged else { return true }
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
    @AppStorage("hotKeyChoice") private var hotKeyRawValue = HotKeyShortcut.defaultShortcut.storedValue
    @AppStorage("snippetHotKeyChoice") private var snippetHotKeyRawValue = HotKeyShortcut.defaultSnippetShortcut.storedValue

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
            .menuShortcut((HotKeyShortcut(storedValue: hotKeyRawValue) ?? .defaultShortcut).keyboardShortcut)
        Button("Show Snippets") { AppRuntime.shared.showPanel(scope: .snippets) }
            .menuShortcut((HotKeyShortcut(storedValue: snippetHotKeyRawValue) ?? .defaultSnippetShortcut).keyboardShortcut)

        Divider()

        if model.capturePaused {
            Button("Resume Capture") { model.resumeCapture() }
            if let until = model.capturePausedUntil {
                Text("Capture paused until \(until.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Capture paused until you resume it")
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

private extension View {
    /// Shows a global hotkey beside its menu item. Status item menus only
    /// display the equivalent; the Carbon hotkey still does the work.
    @ViewBuilder
    func menuShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}

extension HotKeyShortcut {
    /// The SwiftUI equivalent for display in menus, or nil for keys SwiftUI
    /// can't express (function keys and unlabeled key codes).
    var keyboardShortcut: KeyboardShortcut? {
        guard let key = Self.keyEquivalents[keyCode] else { return nil }
        var eventModifiers: SwiftUI.EventModifiers = []
        if modifiers & UInt32(controlKey) != 0 { eventModifiers.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { eventModifiers.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { eventModifiers.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { eventModifiers.insert(.command) }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    private static let keyEquivalents: [UInt32: KeyEquivalent] = {
        var keys: [UInt32: KeyEquivalent] = [
            UInt32(kVK_Return): .return, UInt32(kVK_Tab): .tab,
            UInt32(kVK_Space): .space, UInt32(kVK_Delete): .delete,
            UInt32(kVK_ForwardDelete): .deleteForward, UInt32(kVK_Escape): .escape,
            UInt32(kVK_Home): .home, UInt32(kVK_End): .end,
            UInt32(kVK_PageUp): .pageUp, UInt32(kVK_PageDown): .pageDown,
            UInt32(kVK_LeftArrow): .leftArrow, UInt32(kVK_RightArrow): .rightArrow,
            UInt32(kVK_UpArrow): .upArrow, UInt32(kVK_DownArrow): .downArrow
        ]
        let characters: [(Int, Character)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"),
            (kVK_ANSI_E, "e"), (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"),
            (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"), (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"),
            (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"), (kVK_ANSI_P, "p"),
            (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"),
            (kVK_ANSI_Y, "y"), (kVK_ANSI_Z, "z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-"),
            (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Grave, "`")
        ]
        for (keyCode, character) in characters {
            keys[UInt32(keyCode)] = KeyEquivalent(character)
        }
        return keys
    }()
}
