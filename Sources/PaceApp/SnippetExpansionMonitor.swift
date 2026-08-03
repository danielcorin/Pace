import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog
import PaceCore

enum SnippetExpansionMode: String, CaseIterable, Identifiable {
    case immediately
    case delimiterKeeping
    case delimiterDiscarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: return "Immediately"
        case .delimiterKeeping: return "After Delimiter (Keep)"
        case .delimiterDiscarding: return "After Delimiter (Discard)"
        }
    }
}

enum SnippetExpansionPreferences {
    static let enabledKey = "snippetExpansion.enabled"
    static let modeKey = "snippetExpansion.mode"
    static let restoreClipboardKey = "snippetExpansion.restoreClipboard"
    static let defaultPrefixKey = "snippetExpansion.defaultPrefix"
    static let injectionDelayKey = "snippetExpansion.injectionDelay"
    static let excludedBundleIDsKey = "snippetExpansion.excludedBundleIDs"

    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var mode: SnippetExpansionMode {
        SnippetExpansionMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "")
            ?? .immediately
    }

    static var restoresClipboard: Bool {
        if UserDefaults.standard.object(forKey: restoreClipboardKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: restoreClipboardKey)
    }

    static var defaultPrefix: String {
        UserDefaults.standard.string(forKey: defaultPrefixKey) ?? ";"
    }

    static var injectionDelay: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: injectionDelayKey)
        return stored > 0 ? stored : 0.04
    }

    static var excludedBundleIDs: Set<String> {
        var values = Set(UserDefaults.standard.stringArray(forKey: excludedBundleIDsKey) ?? [])
        values.formUnion(defaultExcludedBundleIDs)
        if let ownBundleID = Bundle.main.bundleIdentifier { values.insert(ownBundleID) }
        return values
    }

    static let defaultExcludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess"
    ]
}

@MainActor
final class SnippetExpansionMonitor {
    struct Match {
        var snippet: Snippet
        var triggerCharacterCount: Int
        var delimiter: String?
        var targetApplication: NSRunningApplication?
    }

    typealias Handler = @MainActor (Match) -> Void

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var fallbackEventMonitor: Any?
    private var healthTimer: Timer?
    private var snippets: [Snippet] = []
    private var buffer = ""
    private var maximumKeywordLength = 0
    private var lastBundleIdentifier: String?
    private var lastEventKeyCode: UInt16?
    private var lastEventTimestamp: TimeInterval = 0
    private var isHandlingMatch = false
    private let handler: Handler
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "llc.wvlen.Pace",
        category: "SnippetExpansion"
    )

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        // AppKit's monitor has broad compatibility but no health API, so
        // recreate it whenever Pace observes an application activation. Keep
        // the supervised Core Graphics tap alongside it as an independent
        // event source rather than choosing only one listener.
        removeFallbackMonitor()
        installFallbackMonitor()
        ensureRunning()
        startHealthChecks()
    }

    func ensureRunning() {
        if let eventTap {
            if !CFMachPortIsValid(eventTap) {
                removeEventTap()
                _ = installEventTap()
            } else if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                Self.logger.notice("Re-enabled disabled Core Graphics event tap")
            }
        } else {
            _ = installEventTap()
        }

        if fallbackEventMonitor == nil { installFallbackMonitor() }
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        removeEventTap()
        removeFallbackMonitor()
        isHandlingMatch = false
        lastEventKeyCode = nil
        lastEventTimestamp = 0
        reset()
    }

    func restart() {
        stop()
        start()
    }

    func update(snippets: [Snippet]) {
        self.snippets = snippets
            .filter { $0.isExpansionEnabled && $0.keyword?.isEmpty == false }
            .sorted { ($0.keyword?.count ?? 0) > ($1.keyword?.count ?? 0) }
        maximumKeywordLength = self.snippets.map { $0.keyword?.count ?? 0 }.max() ?? 0
        // Keystrokes collected against an older catalog must never be used
        // to match a newly saved or edited snippet.
        reset()
    }

    func finishMatch() {
        isHandlingMatch = false
        reset()
    }

    @discardableResult
    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func installFallbackMonitor() {
        guard fallbackEventMonitor == nil else { return }
        fallbackEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func removeEventTap() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            CFRunLoopSourceInvalidate(eventTapSource)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTapSource = nil
        eventTap = nil
    }

    private func removeFallbackMonitor() {
        if let fallbackEventMonitor { NSEvent.removeMonitor(fallbackEventMonitor) }
        fallbackEventMonitor = nil
    }

    private func startHealthChecks() {
        guard healthTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureRunning() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func eventTapWasDisabled() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Self.logger.notice("Recovered Core Graphics event tap after macOS disabled it")
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<SnippetExpansionMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak monitor] in monitor?.eventTapWasDisabled() }
        } else if type == .keyDown, let keyEvent = NSEvent(cgEvent: event) {
            Task { @MainActor [weak monitor] in monitor?.handle(keyEvent) }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ event: NSEvent) {
        // Both listeners intentionally observe the same event. NSEvent keeps
        // the source timestamp when constructed from a CGEvent, so discard
        // only the duplicate delivery while preserving genuine key repeat.
        if lastEventKeyCode == event.keyCode,
           abs(lastEventTimestamp - event.timestamp) < 0.005 {
            return
        }
        lastEventKeyCode = event.keyCode
        lastEventTimestamp = event.timestamp

        guard SnippetExpansionPreferences.isEnabled,
              !isHandlingMatch,
              !snippets.isEmpty else {
            reset()
            return
        }

        let target = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = target?.bundleIdentifier
        if bundleIdentifier != lastBundleIdentifier {
            buffer = ""
            lastBundleIdentifier = bundleIdentifier
        }
        guard !SnippetExpansionPreferences.excludedBundleIDs.contains(bundleIdentifier ?? ""),
              !Self.focusedElementIsSecure() else {
            reset()
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else {
            reset()
            return
        }

        if event.keyCode == UInt16(kVK_Delete) {
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        let resettingKeyCodes: Set<UInt16> = [
            UInt16(kVK_Escape), UInt16(kVK_Tab), UInt16(kVK_Return),
            UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
            UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
            UInt16(kVK_Home), UInt16(kVK_End),
            UInt16(kVK_PageUp), UInt16(kVK_PageDown), UInt16(kVK_ForwardDelete)
        ]
        guard !resettingKeyCodes.contains(event.keyCode),
              let characters = event.characters,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            reset()
            return
        }

        buffer += characters
        if buffer.count > maximumKeywordLength + 1 {
            buffer = String(buffer.suffix(maximumKeywordLength + 1))
        }

        let mode = SnippetExpansionPreferences.mode
        let match: Match?
        switch mode {
        case .immediately:
            match = matchingSuffix(in: buffer).map {
                Match(
                    snippet: $0,
                    triggerCharacterCount: $0.keyword?.count ?? 0,
                    delimiter: nil,
                    targetApplication: target
                )
            }
        case .delimiterKeeping, .delimiterDiscarding:
            guard characters.count == 1,
                  let character = characters.first,
                  character.isWhitespace || character.isPunctuation else { return }
            let withoutDelimiter = String(buffer.dropLast())
            match = matchingSuffix(in: withoutDelimiter).map {
                Match(
                    snippet: $0,
                    triggerCharacterCount: ($0.keyword?.count ?? 0) + 1,
                    delimiter: mode == .delimiterKeeping ? characters : nil,
                    targetApplication: target
                )
            }
        }

        guard let match else { return }
        isHandlingMatch = true
        handler(match)
    }

    private func matchingSuffix(in value: String) -> Snippet? {
        snippets.first { snippet in
            guard let keyword = snippet.keyword else { return false }
            return value.hasSuffix(keyword)
        }
    }

    private func reset() {
        buffer = ""
    }

    private static func focusedElementIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
              let focused else { return false }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subrole
        ) == .success else { return false }
        return (subrole as? String) == "AXSecureTextField"
    }

    deinit {
        healthTimer?.invalidate()
        if let fallbackEventMonitor { NSEvent.removeMonitor(fallbackEventMonitor) }
        if let eventTapSource { CFRunLoopSourceInvalidate(eventTapSource) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }
}
