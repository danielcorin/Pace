import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    let shortcut: HotKeyShortcut
    var captureContext: HotKeyShortcut.CaptureContext = .globalHotKey
    var actionName = "Show Pace"
    let onBeginRecording: () -> Void
    let onComplete: (HotKeyShortcut?) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        configure(button)
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        configure(button)
        button.refreshTitle()
    }

    private func configure(_ button: HotKeyRecorderButton) {
        button.shortcut = shortcut
        button.captureContext = captureContext
        button.onBeginRecording = onBeginRecording
        button.onComplete = onComplete
        button.setAccessibilityLabel("\(actionName) keyboard shortcut")
    }
}

final class HotKeyRecorderButton: NSButton {
    var shortcut = HotKeyShortcut.defaultShortcut
    var captureContext = HotKeyShortcut.CaptureContext.globalHotKey
    var onBeginRecording: (() -> Void)?
    var onComplete: ((HotKeyShortcut?) -> Void)?

    private var recording = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(toggleRecording)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        focusRingType = .exterior
        setAccessibilityHelp("Press to record a new keyboard shortcut")
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, recording { finish(with: nil) }
        return resigned
    }

    func refreshTitle() {
        guard !recording else { return }
        title = shortcut.displayLabel
    }

    @objc private func toggleRecording() {
        if recording {
            finish(with: nil)
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        recording = true
        title = "Press shortcut…"
        state = .on
        window?.makeFirstResponder(self)
        onBeginRecording?()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finish(with: nil)
            return
        }
        guard let shortcut = HotKeyShortcut.from(event: event, context: captureContext) else {
            NSSound.beep()
            title = "Add ⌘, ⌥, or ⌃"
            return
        }
        finish(with: shortcut)
    }

    private func finish(with shortcut: HotKeyShortcut?) {
        guard recording else { return }
        recording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        state = .off
        title = (shortcut ?? self.shortcut).displayLabel
        onComplete?(shortcut)
        window?.makeFirstResponder(nil)
    }
}
