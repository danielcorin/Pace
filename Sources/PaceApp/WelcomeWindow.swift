import AppKit
import SwiftUI

/// The one-time welcome shown on a fresh install: the two global hotkeys,
/// where history lives, and the Accessibility grant Pace needs to paste.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void

    init(model: AppModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        window.title = "Welcome to Pace"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self

        let hostingView = NSHostingView(
            rootView: WelcomeView { [weak self] in self?.getStarted() }
                .environmentObject(model)
        )
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
    }

    func show() {
        // Pace has no Dock icon, so the window would otherwise open behind
        // whatever app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func getStarted() {
        window.close()
        AppRuntime.shared.showPanel(scope: .clipboard)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hotKeyChoice") private var hotKeyRawValue = HotKeyShortcut.defaultShortcut.storedValue
    @AppStorage("snippetHotKeyChoice") private var snippetHotKeyRawValue = HotKeyShortcut.defaultSnippetShortcut.storedValue
    @State private var appeared = false

    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
                .accessibilityHidden(true)
                .modifier(entrance(0))

            VStack(spacing: 4) {
                Text("Welcome to Pace")
                    .font(.system(size: 26, weight: .semibold))
                Text("Your clipboard history, one keystroke away.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 14)
            .modifier(entrance(1))

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    "doc.on.clipboard",
                    "Open your clipboard history",
                    shortcut: HotKeyShortcut(storedValue: hotKeyRawValue) ?? .defaultShortcut
                )
                .modifier(entrance(2))
                featureRow(
                    "text.quote",
                    "Open your snippets",
                    shortcut: HotKeyShortcut(storedValue: snippetHotKeyRawValue) ?? .defaultSnippetShortcut
                )
                .modifier(entrance(3))
                featureRow("lock.shield", "Everything stays encrypted on this Mac")
                    .modifier(entrance(4))
            }
            .padding(.top, 26)

            accessibilityStep
                .padding(.top, 22)
                .modifier(entrance(5))

            Button(action: onGetStarted) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 24)
            .modifier(entrance(6))
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 420)
        .onAppear { appeared = true }
        .task { await watchAccessibilityAccess() }
    }

    /// The guide reports a grant made through it; polling also catches one
    /// made directly in System Settings.
    private func watchAccessibilityAccess() async {
        while !Task.isCancelled, !model.hasAccessibilityAccess {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            model.refreshPermissions()
        }
    }

    private func featureRow(_ systemImage: String, _ title: String, shortcut: HotKeyShortcut? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let shortcut {
                Text(shortcut.displayLabel)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibilityStep: some View {
        HStack(spacing: 12) {
            Image(systemName: "accessibility")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow Accessibility access")
                    .font(.headline)
                Text("Pace needs it to paste into other apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                if model.hasAccessibilityAccess {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Button("Grant Access…") { model.requestAccessibilityAccess() }
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.7),
                value: model.hasAccessibilityAccess
            )
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Fades each section in, rising slightly and staggered top to bottom
    /// unless Reduce Motion is on, in which case everything simply fades.
    private func entrance(_ index: Int) -> Entrance {
        Entrance(appeared: appeared, index: index, reduceMotion: reduceMotion)
    }
}

private struct Entrance: ViewModifier {
    let appeared: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.25)
                    : .spring(response: 0.55, dampingFraction: 0.85).delay(0.1 + Double(index) * 0.05),
                value: appeared
            )
    }
}
