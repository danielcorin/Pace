import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pasteboard contents (or a history item) handed to an action.
public struct ActionInput: Sendable {
    public var representations: [ClipboardRepresentation]
    public var source: ClipboardSource?

    public init(representations: [ClipboardRepresentation], source: ClipboardSource? = nil) {
        self.representations = representations
        self.source = source
    }

    public init(text: String, source: ClipboardSource? = nil) {
        self.init(
            representations: [ClipboardRepresentation(typeIdentifier: Self.plainTextType, data: Data(text.utf8))],
            source: source
        )
    }

    public static let empty = ActionInput(representations: [])

    static let plainTextType = "public.utf8-plain-text"
    static let fileURLType = "public.file-url"
    static let urlType = "public.url"
    static let imageTypes = ["public.png", "public.jpeg", "public.tiff", "public.heic", "com.compuserve.gif"]

    public var text: String? {
        representations.first { $0.typeIdentifier == Self.plainTextType }
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    /// The best image representation, preferring formats agents can read.
    public var image: ClipboardRepresentation? {
        for type in Self.imageTypes {
            if let representation = representations.first(where: { $0.typeIdentifier == type }) {
                return representation
            }
        }
        return nil
    }

    public var fileURLs: [URL] {
        representations
            .filter { $0.typeIdentifier == Self.fileURLType }
            .compactMap { Self.textValue(of: $0.data) }
            .compactMap { URL(string: $0) }
            .filter(\.isFileURL)
    }

    /// A copied link, or text that is exactly one web URL.
    public var url: URL? {
        if let value = representations.first(where: { $0.typeIdentifier == Self.urlType })
            .flatMap({ Self.textValue(of: $0.data) }),
           let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
           !url.isFileURL, url.scheme != nil {
            return url
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    public var summary: ActionInputSummary {
        var kinds = Set<ActionInputKind>()
        let files = fileURLs
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { kinds.insert(.text) }
        if image != nil || files.contains(where: { Self.conforms($0, to: .image) }) { kinds.insert(.image) }
        if url != nil { kinds.insert(.url) }
        if !files.isEmpty { kinds.insert(.files) }
        var types = representations.map(\.typeIdentifier)
        for file in files {
            if let type = UTType(filenameExtension: file.pathExtension) { types.append(type.identifier) }
        }
        var seen = Set<String>()
        return ActionInputSummary(
            kinds: kinds,
            typeIdentifiers: types.filter { seen.insert($0).inserted },
            fileNames: files.map(\.lastPathComponent),
            textLength: text?.count ?? 0
        )
    }

    static func textValue(of data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String
    }

    static func conforms(_ file: URL, to type: UTType) -> Bool {
        UTType(filenameExtension: file.pathExtension)?.conforms(to: type) ?? false
    }
}

/// What kinds of input are present, for matching actions and explaining why
/// an action can't run.
public struct ActionInputSummary: Equatable, Sendable {
    public var kinds: Set<ActionInputKind>
    public var typeIdentifiers: [String]
    public var fileNames: [String]
    public var textLength: Int

    public init(
        kinds: Set<ActionInputKind> = [],
        typeIdentifiers: [String] = [],
        fileNames: [String] = [],
        textLength: Int = 0
    ) {
        self.kinds = kinds
        self.typeIdentifiers = typeIdentifiers
        self.fileNames = fileNames
        self.textLength = textLength
    }

    public var isEmpty: Bool { kinds.isEmpty }

    /// The single most specific kind, used for `PACE_INPUT_KIND` and the
    /// panel's input chip: files, then image, then link, then text.
    public var primaryKind: ActionInputKind? {
        [.files, .image, .url, .text].first { kinds.contains($0) }
    }

    public func satisfies(_ requirement: ActionRequirement) -> Bool {
        switch requirement {
        case .any:
            return true
        case .kind(let kind):
            return kinds.contains(kind)
        case .type(let identifier):
            guard let wanted = UTType(identifier) else {
                return typeIdentifiers.contains(identifier)
            }
            return typeIdentifiers.contains { UTType($0)?.conforms(to: wanted) ?? false }
        }
    }
}

/// The per-run folder: `input/` holds the staged pasteboard, `output/` collects
/// attachments, `state/` survives between a run and its confirm or undo
/// step, and `control/` is where the script offers those steps.
public struct ActionRunDirectory: Sendable {
    public let url: URL

    public var inputURL: URL { url.appendingPathComponent("input", isDirectory: true) }
    public var outputURL: URL { url.appendingPathComponent("output", isDirectory: true) }
    public var stateURL: URL { url.appendingPathComponent("state", isDirectory: true) }
    public var controlURL: URL { url.appendingPathComponent("control", isDirectory: true) }

    /// Private to the user: the folder is created 0700 inside the per-user
    /// temporary directory, because staged input may be sensitive.
    public static func create(in root: URL, id: UUID = UUID()) throws -> ActionRunDirectory {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = ActionRunDirectory(url: root.appendingPathComponent(id.uuidString, isDirectory: true))
        for url in [directory.url, directory.inputURL, directory.outputURL, directory.stateURL, directory.controlURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return directory
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where an input ended up on disk and how the script receives it.
public struct StagedActionInput: Sendable, Equatable {
    public var textFile: URL?
    public var imageFile: URL?
    public var fileURLs: [URL]
    public var url: URL?
    /// Positional arguments: the files that best match what the action asked
    /// for (copied files, else the image, else the text file).
    public var arguments: [String]
    public var text: String?
    public var kind: ActionInputKind?
    public var kinds: [ActionInputKind]
}

public enum ActionInputStager {
    /// Writes `input` into `directory.inputURL` with a `manifest.json` that
    /// lists every representation. `matched` picks which files become the
    /// positional arguments.
    public static func stage(
        _ input: ActionInput,
        matched requirement: ActionRequirement?,
        in directory: ActionRunDirectory
    ) throws -> StagedActionInput {
        let folder = directory.inputURL
        var manifestRepresentations: [[String: Any]] = []

        var textFile: URL?
        if let text = input.text {
            let url = folder.appendingPathComponent("input.txt")
            try write(Data(text.utf8), to: url)
            textFile = url
        }

        var imageFile: URL?
        if let image = input.image {
            let (data, fileExtension) = agentFriendlyImage(image)
            let url = folder.appendingPathComponent("input.\(fileExtension)")
            try write(data, to: url)
            imageFile = url
        }

        for (index, representation) in input.representations.enumerated() {
            var entry: [String: Any] = [
                "item": representation.itemIndex,
                "type": representation.typeIdentifier,
                "bytes": representation.data.count
            ]
            switch representation.typeIdentifier {
            case ActionInput.plainTextType:
                entry["file"] = textFile?.path
            case _ where representation.typeIdentifier == input.image?.typeIdentifier
                && representation.itemIndex == input.image?.itemIndex:
                entry["file"] = imageFile?.path
            case ActionInput.fileURLType, ActionInput.urlType:
                entry["value"] = ActionInput.textValue(of: representation.data)
            default:
                if let url = try writeExtra(representation, index: index, in: folder) {
                    entry["file"] = url.path
                }
            }
            manifestRepresentations.append(entry)
        }

        let summary = input.summary
        let files = input.fileURLs
        let kinds = ActionInputKind.allCases.filter { summary.kinds.contains($0) }
        let arguments = positionalArguments(
            matched: requirement,
            files: files,
            imageFile: imageFile,
            textFile: textFile
        )

        var manifest: [String: Any] = [
            "kind": summary.primaryKind?.rawValue ?? NSNull(),
            "kinds": kinds.map(\.rawValue),
            "arguments": arguments,
            "files": files.map(\.path),
            "representations": manifestRepresentations
        ]
        manifest["text_file"] = textFile?.path
        manifest["image_file"] = imageFile?.path
        manifest["url"] = input.url?.absoluteString
        if let source = input.source {
            var sourceEntry: [String: Any] = ["name": source.name]
            sourceEntry["bundle_id"] = source.bundleIdentifier
            manifest["source"] = sourceEntry
        }
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try write(manifestData, to: folder.appendingPathComponent("manifest.json"))

        return StagedActionInput(
            textFile: textFile,
            imageFile: imageFile,
            fileURLs: files,
            url: input.url,
            arguments: arguments,
            text: input.text,
            kind: primaryKind(for: requirement, summary: summary),
            kinds: kinds
        )
    }

    private static func positionalArguments(
        matched requirement: ActionRequirement?,
        files: [URL],
        imageFile: URL?,
        textFile: URL?
    ) -> [String] {
        let imageFiles = imageFile.map { [$0.path] }
            ?? files.filter { ActionInput.conforms($0, to: .image) }.map(\.path)
        switch requirement {
        case .kind(.image)?:
            return imageFiles
        case .kind(.text)?, .kind(.url)?:
            return textFile.map { [$0.path] } ?? []
        case .kind(.files)?:
            return files.map(\.path)
        case .type(let identifier)?:
            let wanted = UTType(identifier)
            let matching = files.filter { file in
                wanted.map { ActionInput.conforms(file, to: $0) } ?? false
            }
            if !matching.isEmpty { return matching.map(\.path) }
            return wanted?.conforms(to: .image) == true ? imageFiles : files.map(\.path)
        case .any?, nil:
            if !files.isEmpty { return files.map(\.path) }
            if let imageFile { return [imageFile.path] }
            return textFile.map { [$0.path] } ?? []
        }
    }

    private static func primaryKind(
        for requirement: ActionRequirement?,
        summary: ActionInputSummary
    ) -> ActionInputKind? {
        if case .kind(let kind)? = requirement { return kind }
        return summary.primaryKind
    }

    /// TIFF (what some apps put on the pasteboard) becomes PNG, which every
    /// model and image tool reads.
    private static func agentFriendlyImage(_ representation: ClipboardRepresentation) -> (Data, String) {
        switch representation.typeIdentifier {
        case "public.png": return (representation.data, "png")
        case "public.jpeg": return (representation.data, "jpg")
        case "com.compuserve.gif": return (representation.data, "gif")
        default:
            if let png = pngData(from: representation.data) { return (png, "png") }
            let fileExtension = UTType(representation.typeIdentifier)?.preferredFilenameExtension ?? "img"
            return (representation.data, fileExtension)
        }
    }

    private static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Rich text, movies, PDFs, and other data with a known file extension
    /// are written as `input-N.ext`; private and dynamic types are skipped.
    private static func writeExtra(
        _ representation: ClipboardRepresentation,
        index: Int,
        in folder: URL
    ) throws -> URL? {
        let identifier = representation.typeIdentifier
        guard !identifier.hasPrefix("dyn."),
              !ActionInput.imageTypes.contains(identifier),
              let type = UTType(identifier),
              type.conforms(to: .data),
              let fileExtension = type.preferredFilenameExtension,
              !representation.data.isEmpty else { return nil }
        let url = folder.appendingPathComponent("input-\(index).\(fileExtension)")
        try write(representation.data, to: url)
        return url
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
