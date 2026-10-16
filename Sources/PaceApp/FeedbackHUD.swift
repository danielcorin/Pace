import AppKit
import SwiftUI

enum FeedbackStyle {
    case success, info, warning, error
}

struct FeedbackAction {
    let title: String
    let perform: @MainActor () -> Void
}

private enum HUDMetrics {
    static let maximumPillWidth: CGFloat = 460
    /// Room around the pill for its shadow and the drop-in offset.
    static let margin: CGFloat = 14
}

/// A small pill that floats just below the menu bar to confirm an action or
/// report a problem. It never activates Pace or takes focus, so it can appear
/// over whatever app the user is working in.
@MainActor
final class FeedbackHUD {
    private static let fadeOutDuration: TimeInterval = 0.22

    private let state = FeedbackHUDState()
    private var panel: FeedbackHUDPanel?
    private var dismissTask: Task<Void, Never>?
    private var generation = 0

    func show(_ message: String, style: FeedbackStyle, symbol: String?, action: FeedbackAction?) {
        generation += 1
        dismissTask?.cancel()
        let feedback = Feedback(message: message, style: style, symbol: symbol, action: action)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = self.panel ?? makePanel()
        let wasVisible = panel.isVisible && state.isPresented

        panel.ignoresMouseEvents = action == nil
        panel.setFrame(frame(for: feedback), display: true)
        state.reduceMotion = reduceMotion

        if wasVisible {
            // Replace in place: the old message crossfades into the new one.
            withAnimation(.easeInOut(duration: 0.18)) { state.feedback = feedback }
        } else {
            state.feedback = feedback
            state.isPresented = false
            panel.orderFrontRegardless()
            // Let the hidden starting state render before animating to it.
            let shownGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == shownGeneration else { return }
                let entrance: Animation = reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.38, dampingFraction: 0.72)
                withAnimation(entrance) {
                    self.state.isPresented = true
                }
            }
        }
        announce(message)
        scheduleDismissal(after: Self.displayDuration(for: feedback))
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }
        generation += 1
        let dismissedGeneration = generation
        withAnimation(.easeIn(duration: Self.fadeOutDuration)) { state.isPresented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration) { [weak self] in
            // A newer message arrived while this one was fading out.
            guard let self, self.generation == dismissedGeneration else { return }
            panel.orderOut(nil)
            self.state.feedback = nil
        }
    }

    private static func displayDuration(for feedback: Feedback) -> TimeInterval {
        if feedback.action != nil { return 5 }
        switch feedback.style {
        case .success, .info: return 1.8
        case .warning, .error: return 3.5
        }
    }

    private func scheduleDismissal(after seconds: TimeInterval) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func perform(_ action: FeedbackAction) {
        action.perform()
        dismiss()
    }

    /// Top center of the screen under the pointer, just below the menu bar.
    private func frame(for feedback: Feedback) -> NSRect {
        let measured = NSHostingView(rootView: FeedbackPill(feedback: feedback, onAction: {})).fittingSize
        let pillWidth = min(ceil(measured.width), HUDMetrics.maximumPillWidth)
        let size = NSSize(
            width: pillWidth + HUDMetrics.margin * 2,
            height: ceil(measured.height) + HUDMetrics.margin * 2
        )
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            // The window, margin included, stays below the menu bar so it
            // never sits over menu bar items; the pill lands `margin` lower.
            y: visible.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func makePanel() -> FeedbackHUDPanel {
        let panel = FeedbackHUDPanel()
        let view = FeedbackHUDView(state: state) { [weak self] action in self?.perform(action) }
        panel.contentView = FirstMouseHostingView(rootView: view)
        self.panel = panel
        return panel
    }

    /// VoiceOver users don't see the pill, so speak it.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

private struct Feedback: Identifiable {
    let id = UUID()
    let message: String
    let style: FeedbackStyle
    let symbol: String?
    let action: FeedbackAction?

    var symbolName: String {
        if let symbol { return symbol }
        switch style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch style {
        case .success: return .green
        case .info: return .secondary
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

private final class FeedbackHUDState: ObservableObject {
    @Published var feedback: Feedback?
    @Published var isPresented = false
    var reduceMotion = false
}

private final class FeedbackHUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // The pill draws its own shadow; a window shadow would outline the margin.
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // Feedback must never pull focus from the app the user is typing in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel never activates, so the action button needs the first click.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct FeedbackHUDView: View {
    @ObservedObject var state: FeedbackHUDState
    let onAction: (FeedbackAction) -> Void

    var body: some View {
        let hidden = !state.isPresented && !state.reduceMotion
        ZStack {
            if let feedback = state.feedback {
                FeedbackPill(feedback: feedback) {
                    if let action = feedback.action { onAction(action) }
                }
                .id(feedback.id)
                .transition(.opacity)
            }
        }
        .scaleEffect(hidden ? 0.96 : 1)
        .offset(y: hidden ? -10 : 0)
        .opacity(state.isPresented ? 1 : 0)
        .padding(HUDMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeedbackPill: View {
    let feedback: Feedback
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(feedback.tint)
            Text(feedback.message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let action = feedback.action {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                Button(action: onAction) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, feedback.action == nil ? 16 : 14)
        .padding(.vertical, 9)
        .frame(maxWidth: HUDMetrics.maximumPillWidth)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
        .accessibilityElement(children: .combine)
    }
}
