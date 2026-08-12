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
    public var lastUsedAt: Date?
    public var useCount: Int
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
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
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
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.ocrObservations = ocrObservations
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case lastCopiedAt
        case source
        case kind
        case representations
        case preview
        case searchableText
        case fingerprint
        case byteCount
        case copyCount
        case lastUsedAt
        case useCount
        case isPinned
        case ocrObservations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastCopiedAt = try values.decode(Date.self, forKey: .lastCopiedAt)
        source = try values.decode(ClipboardSource.self, forKey: .source)
        kind = try values.decode(ClipboardContentKind.self, forKey: .kind)
        representations = try values.decode([ClipboardRepresentation].self, forKey: .representations)
        preview = try values.decode(String.self, forKey: .preview)
        searchableText = try values.decode(String.self, forKey: .searchableText)
        fingerprint = try values.decode(String.self, forKey: .fingerprint)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        copyCount = try values.decode(Int.self, forKey: .copyCount)
        lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try values.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        ocrObservations = try values.decode([OCRObservation].self, forKey: .ocrObservations)
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
    public var lastUsedAt: Date?
    public var useCount: Int
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
        lastUsedAt = item.lastUsedAt
        useCount = item.useCount
        isPinned = item.isPinned
        hasOCR = !item.ocrObservations.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case lastCopiedAt
        case source
        case kind
        case preview
        case searchableText
        case fingerprint
        case byteCount
        case copyCount
        case lastUsedAt
        case useCount
        case isPinned
        case hasOCR
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastCopiedAt = try values.decode(Date.self, forKey: .lastCopiedAt)
        source = try values.decode(ClipboardSource.self, forKey: .source)
        kind = try values.decode(ClipboardContentKind.self, forKey: .kind)
        preview = try values.decode(String.self, forKey: .preview)
        searchableText = try values.decode(String.self, forKey: .searchableText)
        fingerprint = try values.decode(String.self, forKey: .fingerprint)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        copyCount = try values.decode(Int.self, forKey: .copyCount)
        lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try values.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        hasOCR = try values.decode(Bool.self, forKey: .hasOCR)
    }
}
