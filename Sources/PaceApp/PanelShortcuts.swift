import AppKit
import Carbon.HIToolbox
import Foundation

/// An action inside the history panel whose keyboard shortcut can be changed
/// in Settings.
enum PanelAction: String, CaseIterable, Identifiable {
    case paste
    case pastePlainText
    case pasteSingleLine
    case pasteOCRText
    case copy
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "Paste"
        case .pastePlainText: return "Paste as Plain Text"
        case .pasteSingleLine: return "Paste as Single Line"
        case .pasteOCRText: return "Paste OCR Text"
        case .copy: return "Copy"
        case .delete: return "Delete"
        }
    }

    var subtitle: String {
        switch self {
        case .paste: return "Paste the selected item"
        case .pastePlainText: return "Paste without formatting"
        case .pasteSingleLine: return "Trim whitespace and paste as one line"
        case .pasteOCRText: return "Paste the text recognized in an image"
        case .copy: return "Copy the selected item without pasting"
        case .delete: return "Remove the selected item from history"
        }
    }

    var defaultShortcut: HotKeyShortcut {
        switch self {
        case .paste:
            return HotKeyShortcut(keyCode: UInt32(kVK_Return), modifiers: 0)
        case .pastePlainText:
            return HotKeyShortcut(keyCode: UInt32(kVK_Return), modifiers: UInt32(shiftKey))
        case .pasteSingleLine:
            return HotKeyShortcut(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey | shiftKey))
        case .pasteOCRText:
            return HotKeyShortcut(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey))
        case .copy:
            return HotKeyShortcut(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey))
        case .delete:
            return HotKeyShortcut(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey))
        }
    }

    var defaultsKey: String { "panelShortcut.\(rawValue)" }
}

enum PanelShortcuts {
    static func shortcut(for action: PanelAction) -> HotKeyShortcut {
        HotKeyShortcut(storedValue: UserDefaults.standard.string(forKey: action.defaultsKey))
            ?? action.defaultShortcut
    }

    static func set(_ shortcut: HotKeyShortcut, for action: PanelAction) {
        UserDefaults.standard.set(shortcut.storedValue, forKey: action.defaultsKey)
    }

    static func restoreDefaults() {
        for action in PanelAction.allCases {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
    }

    static func action(matching event: NSEvent) -> PanelAction? {
        let modifiers = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)
        let keyCode = HotKeyShortcut.normalizedKeyCode(UInt32(event.keyCode))
        return PanelAction.allCases.first { action in
            let shortcut = shortcut(for: action)
            return HotKeyShortcut.normalizedKeyCode(shortcut.keyCode) == keyCode
                && shortcut.modifiers == modifiers
        }
    }
}
