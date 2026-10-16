import AppKit
import ApplicationServices
import SwiftUI

enum AccessibilityPermission {
    /// Whether this process can currently use the Accessibility API.
    ///
    /// `AXIsProcessTrusted()` picks up a grant live but caches it: after the
    /// user removes or switches off Pace in System Settings it keeps returning
    /// true until relaunch, while real AX calls start failing with
    /// `cannotComplete`. So a trusted answer is confirmed with an actual query.
    ///
    /// `CGPreflightPostEventAccess` is no alternative: it keeps its launch-time
    /// answer too, and it rides the current event's provenance, so a check
    /// triggered by a Karabiner-synthesized keystroke is evaluated against
    /// Karabiner.
    static var isGranted: Bool {
        guard AXIsProcessTrusted() else { return false }
        if answers(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) { return true }
        // A hung frontmost app also fails that query; the Dock always answers.
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return false }
        return answers(AXUIElementCreateApplication(dock.processIdentifier), kAXRoleAttribute)
    }

    private static func answers(_ element: AXUIElement, _ attribute: String) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .cannotComplete, .apiDisabled, .notImplemented: return false
        default: return true
        }
    }
}

/// Walks the user through granting Accessibility access: opens the
/// Accessibility pane of System Settings and pins a panel under its window
/// holding a draggable Pace icon. Dropping the icon on the pane's app list
/// adds Pace the same way a Finder drag does, which current macOS requires
/// because the AX consent prompt no longer registers apps itself.
///
/// The Settings window is located with `CGWindowListCopyWindowInfo`, whose
/// bounds and owner fields need no permission. Pace doesn't have
/// Accessibility access yet, so the AX API can't be used to find it.
@MainActor
final class AccessibilityGuide {
    private static let settingsBundleID = "com.apple.systempreferences"
    private static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!
    private static let panelHeight: CGFloat = 88
    private static let gap: CGFloat = 8
    /// Where the app list sits within the Settings window, measured on macOS
    /// 26 (the window has a fixed width and the sidebar can't be resized).
    /// The guide lines up with the list rather than the sidebar.
    private static let listLeadingInset: CGFloat = 251
    private static let listTrailingInset: CGFloat = 20

    private let state = AccessibilityGuideState()
    private var panel: AccessibilityGuidePanel?
    private var timer: Timer?
    private var ticks = 0
    private var startedAt = Date()
    private var sawSettings = false
    private var onGranted: (() -> Void)?

    var isActive: Bool { timer != nil }

    func start(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
        openPane()
        guard !isActive else { return }

        state.isGranted = false
        startedAt = Date()
        sawSettings = false
        ticks = 0
        // Common modes keep the panel tracking while a drag session runs
        // the event-tracking loop.
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        onGranted = nil
    }

    private func openPane() {
        if NSWorkspace.shared.open(Self.paneURL) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func tick() {
        ticks += 1
        if ticks % 10 == 0, !state.isGranted, AccessibilityPermission.isGranted {
            granted()
            return
        }
        guard !state.isGranted else { return }

        guard let settings = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.settingsBundleID).first
        else {
            // Settings quit after showing, or never launched.
            if sawSettings || Date().timeIntervalSince(startedAt) > 10 { stop() }
            return
        }
        sawSettings = true

        guard settings.isActive, let frame = Self.mainWindowFrame(of: settings.processIdentifier) else {
            panel?.orderOut(nil)
            return
        }
        position(below: frame)
    }

    private func granted() {
        state.isGranted = true
        onGranted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.stop()
        }
    }

    private func position(below settingsFrame: CGRect) {
        let panel = self.panel ?? makePanel()
        let screen = NSScreen.screens.max {
            $0.frame.intersection(settingsFrame).area < $1.frame.intersection(settingsFrame).area
        }
        let visible = screen?.visibleFrame ?? settingsFrame

        let list = Self.listColumn(in: settingsFrame)
        var frame = CGRect(
            x: list.minX,
            y: settingsFrame.minY - Self.gap - Self.panelHeight,
            width: list.width,
            height: Self.panelHeight
        )
        // No room under the window: float over its bottom edge instead, which
        // still sits beneath the app list.
        if frame.minY < visible.minY {
            frame.origin.y = settingsFrame.minY + 12
        }

        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
    }

    private func makePanel() -> AccessibilityGuidePanel {
        let panel = AccessibilityGuidePanel()
        let view = AccessibilityGuideView(state: state) { [weak self] in self?.stop() }
        panel.contentView = FirstMouseHostingView(rootView: view)
        self.panel = panel
        return panel
    }

    /// The horizontal span of the pane's app list, or the whole window when
    /// it's too narrow to match the measured layout.
    private static func listColumn(in settingsFrame: CGRect) -> CGRect {
        let width = settingsFrame.width - listLeadingInset - listTrailingInset
        guard width >= 360 else { return settingsFrame }
        return CGRect(
            x: settingsFrame.minX + listLeadingInset,
            y: settingsFrame.minY,
            width: width,
            height: settingsFrame.height
        )
    }

    /// The largest normal-layer window of `pid`, in AppKit screen coordinates.
    private static func mainWindowFrame(of pid: pid_t) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let bounds = info.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width > 200, rect.height > 200
            else { return nil }
            return rect
        }
        guard let rect = bounds.max(by: { $0.area < $1.area }),
              let primary = NSScreen.screens.first
        else { return nil }
        // CG window bounds are top-left based on the primary display.
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

private final class AccessibilityGuideState: ObservableObject {
    @Published var isGranted = false
}

private final class AccessibilityGuidePanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    // Never take focus from System Settings: the drop target lives there.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel never activates, so every first click must reach the views.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AccessibilityGuideView: View {
    @ObservedObject var state: AccessibilityGuideState
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if state.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                    .frame(width: 64)
                Text("Pace can paste now")
                    .font(.headline)
            } else {
                VStack(spacing: 3) {
                    DraggableAppIcon()
                        .frame(width: 44, height: 44)
                    Text("Pace")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                )
                .help("Drag into the Accessibility list")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Drag Pace into the list above")
                        .font(.headline)
                    Text("This lets Pace paste into other apps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Listed but not working? Remove it and drag it in again.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator)
        )
        .animation(.easeOut(duration: 0.2), value: state.isGranted)
    }
}

private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableAppIconView { DraggableAppIconView() }
    func updateNSView(_ nsView: DraggableAppIconView, context: Context) {}
}

/// Drags the running app bundle as a file URL, exactly what Finder offers
/// when an app is dragged from /Applications.
private final class DraggableAppIconView: NSView, NSDraggingSource {
    private let appURL = Bundle.main.bundleURL
    private lazy var icon = NSWorkspace.shared.icon(forFile: appURL.path)

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
