import AppKit
import ImageIO
import PaceCore
import UniformTypeIdentifiers

/// Builds the item provider for dragging a clipboard image into another app.
///
/// SwiftUI drags can't offer real file promises, so the image is decrypted on
/// demand, written to a private temporary folder, and offered both as a file
/// URL (Finder, Mail, browsers, chat apps) and as PNG data (apps that take
/// image data directly). Nothing is decrypted unless the drag is dropped
/// somewhere that asks for it, and the plaintext copy is removed a few
/// minutes later (or at the next launch, if Pace quits first).
enum ImageDragProvider {
    /// Long enough for receivers that read the file lazily after the drop.
    private static let fileLifetime: TimeInterval = 10 * 60

    private static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Pace-Drag", isDirectory: true)
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    static func make(record: ClipboardRecord, store: HistoryStore) -> NSItemProvider {
        let name = "Pace Image \(filenameFormatter.string(from: record.lastCopiedAt)).png"
        let loader = Loader(recordID: record.id, store: store, filename: name)
        let provider = NSItemProvider()
        provider.suggestedName = name
        // File URL first: Finder only accepts files, and apps that take
        // images accept an image file too.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            Task.detached {
                do {
                    completion(try await loader.fileURL().dataRepresentation, nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            Task.detached {
                do {
                    completion(try await loader.pngData(), nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        return provider
    }

    /// Removes drag files older than their lifetime; with `all`, every one.
    static func purgeStaleFiles(all: Bool = false) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-fileLifetime)
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if all || created < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// Shares one decrypt and conversion between the file and data
    /// representations of a single drag.
    private actor Loader {
        let recordID: UUID
        let store: HistoryStore
        let filename: String
        private var png: Data?
        private var file: URL?

        init(recordID: UUID, store: HistoryStore, filename: String) {
            self.recordID = recordID
            self.store = store
            self.filename = filename
        }

        func pngData() async throws -> Data {
            if let png { return png }
            let item = try await store.item(id: recordID)
            let data = try ImageDragProvider.pngData(from: item.representations)
            png = data
            return data
        }

        func fileURL() async throws -> URL {
            if let file { return file }
            let data = try await pngData()
            ImageDragProvider.purgeStaleFiles()
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: ImageDragProvider.rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let directory = ImageDragProvider.rootDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                try? fileManager.removeItem(at: directory)
                throw error
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ImageDragProvider.fileLifetime) {
                try? FileManager.default.removeItem(at: directory)
            }
            file = url
            return url
        }
    }

    private static func pngData(from representations: [ClipboardRepresentation]) throws -> Data {
        if let png = representations.first(where: { $0.typeIdentifier == UTType.png.identifier })?.data {
            return png
        }
        guard let source = representations
            .first(where: { [UTType.jpeg.identifier, UTType.tiff.identifier].contains($0.typeIdentifier) })?.data,
              let image = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(image) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImageFromSource(destination, image, 0, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
