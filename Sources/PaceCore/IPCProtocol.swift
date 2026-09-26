import Foundation

public enum IPCCommand: String, Codable, Sendable {
    case status
    case unlock
    case lock
    case list
    case search
    case get
    case add
    case copy
    case paste
    case delete
    case clear
    case pin
    case retentionShow
    case retentionSet
    case retentionPreview
    case retentionPrune
    case snippetList
    case snippetSearch
    case snippetGet
    case snippetAdd
    case snippetUpdate
    case snippetDelete
    case snippetCopy
    case snippetPaste
    case snippetRender
    case snippetPromote
    case show
    case export
}

public struct IPCRequest: Codable, Sendable {
    public var id: UUID
    public var command: IPCCommand
    public var arguments: [String: String]
    public var input: Data?

    public init(
        id: UUID = UUID(),
        command: IPCCommand,
        arguments: [String: String] = [:],
        input: Data? = nil
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.input = input
    }
}

public struct PaceStatus: Codable, Equatable, Sendable {
    public var isUnlocked: Bool
    public var isCapturePaused: Bool
    public var itemCount: Int?
    public var storageBytes: Int64?
    public var snippetCount: Int?
    public var isSnippetExpansionEnabled: Bool?
    public var retentionPolicy: RetentionPolicy

    public init(
        isUnlocked: Bool,
        isCapturePaused: Bool,
        itemCount: Int?,
        storageBytes: Int64?,
        snippetCount: Int? = nil,
        isSnippetExpansionEnabled: Bool? = nil,
        retentionPolicy: RetentionPolicy
    ) {
        self.isUnlocked = isUnlocked
        self.isCapturePaused = isCapturePaused
        self.itemCount = itemCount
        self.storageBytes = storageBytes
        self.snippetCount = snippetCount
        self.isSnippetExpansionEnabled = isSnippetExpansionEnabled
        self.retentionPolicy = retentionPolicy
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: UUID
    public var success: Bool
    public var errorCode: String?
    public var message: String?
    public var records: [ClipboardRecord]?
    public var item: ClipboardItem?
    public var snippets: [Snippet]?
    public var snippet: Snippet?
    public var renderedSnippet: RenderedSnippet?
    public var status: PaceStatus?
    public var retentionPolicy: RetentionPolicy?
    public var retentionReport: RetentionReport?
    public var exportSummary: PaceExportSummary?

    public init(
        id: UUID,
        success: Bool,
        errorCode: String? = nil,
        message: String? = nil,
        records: [ClipboardRecord]? = nil,
        item: ClipboardItem? = nil,
        snippets: [Snippet]? = nil,
        snippet: Snippet? = nil,
        renderedSnippet: RenderedSnippet? = nil,
        status: PaceStatus? = nil,
        retentionPolicy: RetentionPolicy? = nil,
        retentionReport: RetentionReport? = nil,
        exportSummary: PaceExportSummary? = nil
    ) {
        self.id = id
        self.success = success
        self.errorCode = errorCode
        self.message = message
        self.records = records
        self.item = item
        self.snippets = snippets
        self.snippet = snippet
        self.renderedSnippet = renderedSnippet
        self.status = status
        self.retentionPolicy = retentionPolicy
        self.retentionReport = retentionReport
        self.exportSummary = exportSummary
    }

    public static func failure(id: UUID, error: Error) -> IPCResponse {
        if let paceError = error as? PaceError {
            return IPCResponse(
                id: id,
                success: false,
                errorCode: paceError.code,
                message: paceError.localizedDescription
            )
        }
        return IPCResponse(
            id: id,
            success: false,
            errorCode: "internal_error",
            message: error.localizedDescription
        )
    }
}
