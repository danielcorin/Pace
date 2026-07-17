import AppKit
import CryptoKit
import Foundation
import PaceCore

struct PasteboardSnapshot: Sendable {
    var representations: [ClipboardRepresentation]
    var source: ClipboardSource

    var typeIdentifiers: [String] { representations.map(\.typeIdentifier) }

    var plainText: String? {
        for representation in representations where representation.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue {
            if let text = String(data: representation.data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    var imageData: Data? {
        let imageTypes = [
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            "public.jpeg"
        ]
        for type in imageTypes {
            if let data = representations.first(where: { $0.typeIdentifier == type })?.data {
                return data
            }
        }
        return nil
    }

    @MainActor
    static func capture(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var representations: [ClipboardRepresentation] = []

        for (itemIndex, item) in items.enumerated() {
            for type in item.types {
                if type == .string, let string = item.string(forType: type) {
                    representations.append(
                        ClipboardRepresentation(
                            itemIndex: itemIndex,
                            typeIdentifier: type.rawValue,
                            data: Data(string.utf8)
                        )
                    )
                } else if let data = item.data(forType: type) {
                    representations.append(
                        ClipboardRepresentation(
                            itemIndex: itemIndex,
                            typeIdentifier: type.rawValue,
                            data: data
                        )
                    )
                }
            }
        }

        guard !representations.isEmpty else { return nil }
        let application = NSWorkspace.shared.frontmostApplication
        let source = ClipboardSource(
            kind: .application,
            name: application?.localizedName ?? "Unknown Application",
            bundleIdentifier: application?.bundleIdentifier
        )
        return PasteboardSnapshot(representations: representations, source: source)
    }

    func makeItem(now: Date = Date()) -> ClipboardItem {
        let kind = inferredKind
        let preview = inferredPreview(kind: kind)
        let searchable = inferredSearchableText(preview: preview)
        let byteCount = representations.reduce(Int64(0)) { $0 + Int64($1.data.count) }

        var item = ClipboardItem(
            createdAt: now,
            lastCopiedAt: now,
            source: source,
            kind: kind,
            representations: representations,
            preview: preview,
            searchableText: searchable,
            fingerprint: "",
            byteCount: byteCount
        )
        item.fingerprint = item.contentFingerprint
        return item
    }

    private var inferredKind: ClipboardContentKind {
        let types = Set(typeIdentifiers)
        if types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || types.contains("public.jpeg") {
            return .image
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .files }
        if types.contains(NSPasteboard.PasteboardType.URL.rawValue) { return .url }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) {
            return .richText
        }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return .text }
        return .unknown
    }

    private func inferredPreview(kind: ClipboardContentKind) -> String {
        if let plainText {
            return plainText
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefixString(240)
        }
        if kind == .files {
            let paths = representations
                .filter { $0.typeIdentifier == NSPasteboard.PasteboardType.fileURL.rawValue }
                .compactMap { Self.textValue(from: $0.data) }
                .compactMap { URL(string: $0)?.lastPathComponent }
            if !paths.isEmpty { return paths.joined(separator: ", ").prefixString(240) }
        }
        switch kind {
        case .image: return "Image"
        case .files: return "Files"
        case .url: return "URL"
        case .richText: return "Rich text"
        case .text: return "Text"
        case .unknown: return "Clipboard item"
        }
    }

    private func inferredSearchableText(preview: String) -> String {
        var components = [preview, source.name, source.bundleIdentifier ?? ""]
        for representation in representations {
            switch representation.typeIdentifier {
            case NSPasteboard.PasteboardType.string.rawValue:
                if let text = String(data: representation.data, encoding: .utf8) {
                    components.append(text.prefixString(250_000))
                }
            case NSPasteboard.PasteboardType.fileURL.rawValue,
                 NSPasteboard.PasteboardType.URL.rawValue:
                if let value = Self.textValue(from: representation.data) {
                    components.append(value)
                }
            default:
                break
            }
        }
        return components.joined(separator: "\n")
    }

    private static func textValue(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String
    }
}

enum ClipboardRestoreMode {
    case original
    case plainText
    case ocrText
}

extension ClipboardItem {
    @MainActor
    func restore(to pasteboard: NSPasteboard = .general, mode: ClipboardRestoreMode = .original) throws {
        pasteboard.clearContents()

        if mode == .plainText, let plainText {
            pasteboard.setString(plainText, forType: .string)
            return
        }
        if mode == .ocrText {
            guard let ocrText else {
                throw PaceError.notFound("No OCR text is available for this image.")
            }
            pasteboard.setString(ocrText, forType: .string)
            return
        }

        let grouped = Dictionary(grouping: representations, by: \.itemIndex)
        let items = grouped.keys.sorted().map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in grouped[index] ?? [] {
                let type = NSPasteboard.PasteboardType(representation.typeIdentifier)
                if type == .string, let string = String(data: representation.data, encoding: .utf8) {
                    item.setString(string, forType: type)
                } else {
                    item.setData(representation.data, forType: type)
                }
            }
            return item
        }
        // Text-only targets (terminal prompts, Raycast-style fields) can't
        // take image data, and some let the synthesized ⌘V fall through as a
        // literal "v" keystroke. Give them the OCR text as a plain-text
        // representation; image-capable apps still prefer the image types
        // written first.
        if kind == .image,
           !representations.contains(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue }),
           let ocrText,
           let first = items.first {
            first.setString(ocrText, forType: .string)
        }
        pasteboard.writeObjects(items)
    }
}
