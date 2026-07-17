import CryptoKit
import Foundation

public enum ClipboardContentKind: String, Codable, CaseIterable, Sendable {
    case text
    case richText
    case url
    case image
    case files
    case unknown
}

public struct ClipboardSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case application
        case agent
        case commandLine
        case unknown
    }

    public var kind: Kind
    public var name: String
    public var bundleIdentifier: String?
    public var sessionIdentifier: String?

    public init(
        kind: Kind,
        name: String,
        bundleIdentifier: String? = nil,
        sessionIdentifier: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.sessionIdentifier = sessionIdentifier
    }
}

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public var itemIndex: Int
    public var typeIdentifier: String
    public var data: Data

    public init(itemIndex: Int = 0, typeIdentifier: String, data: Data) {
        self.itemIndex = itemIndex
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

public struct OCRObservation: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Float
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        text: String,
        confidence: Float,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ClipboardItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var source: ClipboardSource
    public var kind: ClipboardContentKind
    public var representations: [ClipboardRepresentation]
    public var preview: String
    public var searchableText: String
    public var fingerprint: String
    public var byteCount: Int64
    public var copyCount: Int
    public var isPinned: Bool
    public var ocrObservations: [OCRObservation]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        source: ClipboardSource,
        kind: ClipboardContentKind,
        representations: [ClipboardRepresentation],
        preview: String,
        searchableText: String,
        fingerprint: String,
        byteCount: Int64,
        copyCount: Int = 1,
        isPinned: Bool = false,
        ocrObservations: [OCRObservation] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.source = source
        self.kind = kind
        self.representations = representations
        self.preview = preview
        self.searchableText = searchableText
        self.fingerprint = fingerprint
        self.byteCount = byteCount
        self.copyCount = copyCount
        self.isPinned = isPinned
        self.ocrObservations = ocrObservations
    }

    public var plainText: String? {
        let textTypes = ["public.utf8-plain-text", "public.utf16-plain-text", "public.text"]
        for type in textTypes {
            if let data = representations.first(where: { $0.typeIdentifier == type })?.data,
               let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                return value
            }
        }
        return nil
    }

    public var ocrText: String? {
        let text = ocrObservations
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public extension ClipboardItem {
    /// A capture-path-independent identity: items with the same visible
    /// content merge even when their pasteboard representations differ
    /// (e.g. a rich-text copy vs a plain-text import of the same text).
    var contentFingerprint: String {
        if let text = plainText, !text.isEmpty {
            return "text:" + Self.sha256(Data(text.utf8))
        }
        for type in ["public.png", "public.tiff", "public.jpeg"] {
            if let data = representations.first(where: { $0.typeIdentifier == type })?.data {
                return "image:" + Self.sha256(data)
            }
        }
        var hasher = SHA256()
        for representation in representations.sorted(by: {
            if $0.itemIndex == $1.itemIndex { return $0.typeIdentifier < $1.typeIdentifier }
            return $0.itemIndex < $1.itemIndex
        }) {
            hasher.update(data: Data("\(representation.itemIndex):\(representation.typeIdentifier):".utf8))
            hasher.update(data: representation.data)
        }
        return "reps:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ClipboardRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var lastCopiedAt: Date
    public var source: ClipboardSource
    public var kind: ClipboardContentKind
    public var preview: String
    public var searchableText: String
    public var fingerprint: String
    public var byteCount: Int64
    public var copyCount: Int
    public var isPinned: Bool
    public var hasOCR: Bool

    public init(item: ClipboardItem) {
        id = item.id
        createdAt = item.createdAt
        lastCopiedAt = item.lastCopiedAt
        source = item.source
        kind = item.kind
        preview = item.preview
        searchableText = item.searchableText
        fingerprint = item.fingerprint
        byteCount = item.byteCount
        copyCount = item.copyCount
        isPinned = item.isPinned
        hasOCR = !item.ocrObservations.isEmpty
    }
}
