import AppKit
import PaceCore
import UniformTypeIdentifiers

@MainActor
enum ExportPrompts {
    /// Asks for an export passphrase twice. Returns nil when cancelled; loops
    /// with an explanation while the entries are too short or don't match,
    /// keeping what was typed so only the problem field needs fixing.
    static func passphrase() -> String? {
        var problem: String?
        var typedPassphrase = ""
        var typedConfirmation = ""
        var focusConfirmation = false
        while true {
            let alert = NSAlert()
            alert.messageText = "Encrypt Export"
            alert.informativeText = problem ?? """
                Choose a passphrase of at least \(PaceExportCodec.minimumPassphraseLength) characters. \
                Pace doesn't store it, and the export can't be opened without it.
                """
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            let passphrase = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 22))
            passphrase.placeholderString = "Passphrase"
            passphrase.stringValue = typedPassphrase
            let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
            confirmation.placeholderString = "Confirm passphrase"
            confirmation.stringValue = typedConfirmation
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
            accessory.addSubview(passphrase)
            accessory.addSubview(confirmation)
            alert.accessoryView = accessory
            // The focused field's text is selected, so typing replaces it.
            alert.window.initialFirstResponder = focusConfirmation ? confirmation : passphrase
            passphrase.nextKeyView = confirmation

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let value = passphrase.stringValue
            typedPassphrase = value
            typedConfirmation = confirmation.stringValue
            if value.count < PaceExportCodec.minimumPassphraseLength {
                problem = "The passphrase must be at least \(PaceExportCodec.minimumPassphraseLength) characters."
                focusConfirmation = false
            } else if value != typedConfirmation {
                problem = "The passphrases don't match. Retype the confirmation."
                focusConfirmation = true
            } else {
                return value
            }
        }
    }

    static func destination(encrypted: Bool) -> URL? {
        let panel = NSSavePanel()
        panel.title = encrypted ? "Export Encrypted Pace Data" : "Export Pace Data"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = encrypted
            ? "Pace Export \(date) (encrypted).json"
            : "Pace Export \(date).json"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
