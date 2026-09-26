import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

public enum PaceExportScope: String, Codable, CaseIterable, Sendable {
    case all
    case clipboard
    case snippets

    public var includesClipboard: Bool { self != .snippets }
    public var includesSnippets: Bool { self != .clipboard }
}

/// A decrypted, self-describing dump of Pace's history and snippets. Binary
/// representations (images, rich text) are base64 encoded by JSONEncoder;
/// `text` repeats each item's plain or OCR text so tools like jq can read it
/// without decoding representations.
public struct PaceExportArchive: Codable, Sendable {
    public static let formatIdentifier = "pace-export"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var clipboard: [ExportedClipboardEntry]?
    public var snippets: [Snippet]?

    public init(
        exportedAt: Date = Date(),
        clipboard: [ClipboardItem]?,
        snippets: [Snippet]?
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.clipboard = clipboard?.map(ExportedClipboardEntry.init(item:))
        self.snippets = snippets
    }
}

public struct ExportedClipboardEntry: Codable, Sendable {
    public var text: String?
    public var item: ClipboardItem

    public init(item: ClipboardItem) {
        text = item.plainText ?? item.ocrText
        self.item = item
    }
}

public struct PaceExportSummary: Codable, Equatable, Sendable {
    public var path: String
    public var clipboardItemCount: Int
    public var snippetCount: Int
    public var byteCount: Int64
    public var isEncrypted: Bool

    public init(path: String, clipboardItemCount: Int, snippetCount: Int, byteCount: Int64, isEncrypted: Bool) {
        self.path = path
        self.clipboardItemCount = clipboardItemCount
        self.snippetCount = snippetCount
        self.byteCount = byteCount
        self.isEncrypted = isEncrypted
    }
}

public enum PaceExportCodec {
    public static let minimumPassphraseLength = 8
    public static let defaultIterations = 600_000
    private static let iterationRange = 100_000...10_000_000

    /// Encrypted exports are a JSON envelope around an AES-256-GCM sealed box
    /// whose key is derived from the passphrase with PBKDF2-HMAC-SHA256, so
    /// the file stays readable by tooling outside Pace given the passphrase.
    private struct EncryptedEnvelope: Codable {
        static let formatIdentifier = "pace-export-encrypted"

        var format = Self.formatIdentifier
        var version = 1
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: Data
        var cipher = "aes-256-gcm"
        var sealed: Data

        var associatedData: Data {
            Data("\(format)/\(version)/\(kdf)/\(iterations)/\(cipher)".utf8)
        }
    }

    public static func encode(_ archive: PaceExportArchive) throws -> Data {
        let encoder = JSONEncoder.pace
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    public static func decode(_ data: Data) throws -> PaceExportArchive {
        guard let archive = try? JSONDecoder.pace.decode(PaceExportArchive.self, from: data),
              archive.format == PaceExportArchive.formatIdentifier else {
            throw PaceError.invalidArgument("The file is not a Pace export.")
        }
        return archive
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(EncryptedEnvelope.self, from: data))?.format
            == EncryptedEnvelope.formatIdentifier
    }

    public static func encrypt(
        _ plaintext: Data,
        passphrase: String,
        iterations: Int = defaultIterations
    ) throws -> Data {
        guard passphrase.count >= minimumPassphraseLength else {
            throw PaceError.invalidArgument(
                "The export passphrase must be at least \(minimumPassphraseLength) characters."
            )
        }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PaceError.unavailable("Could not generate random data for the export.")
        }
        var envelope = EncryptedEnvelope(iterations: iterations, salt: salt, sealed: Data())
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: envelope.associatedData)
        guard let combined = box.combined else {
            throw PaceError.unavailable("Could not encrypt the export.")
        }
        envelope.sealed = combined
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(EncryptedEnvelope.self, from: data),
              envelope.format == EncryptedEnvelope.formatIdentifier else {
            throw PaceError.invalidArgument("The file is not an encrypted Pace export.")
        }
        guard envelope.version == 1,
              envelope.kdf == "pbkdf2-sha256",
              envelope.cipher == "aes-256-gcm",
              iterationRange.contains(envelope.iterations) else {
            throw PaceError.invalidArgument("This encrypted export uses unsupported parameters.")
        }
        let key = try deriveKey(passphrase: passphrase, salt: envelope.salt, iterations: envelope.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            return try AES.GCM.open(box, using: key, authenticating: envelope.associatedData)
        } catch {
            throw PaceError.authenticationFailed("The passphrase is incorrect or the export is damaged.")
        }
    }

    /// Writes through a 0600 temporary file and renames it into place, so the
    /// plaintext is never world-readable, even briefly, and a failed export
    /// never leaves a partial file at the destination.
    public static func write(_ data: Data, to url: URL, overwrite: Bool) throws {
        let fileManager = FileManager.default
        if !overwrite, fileManager.fileExists(atPath: url.path) {
            throw PaceError.invalidArgument("\(url.path) already exists.")
        }
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PaceError.notFound("The folder \(directory.path) does not exist.")
        }

        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw PaceError.unavailable("Could not write to \(directory.path): \(String(cString: strerror(errno))).")
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw PaceError.unavailable("Could not write \(url.path): \(String(cString: strerror(errno))).")
            }
        } catch {
            unlink(temporaryURL.path)
            throw error
        }
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        guard !password.isEmpty else {
            throw PaceError.invalidArgument("An export passphrase is required.")
        }
        var derived = [UInt8](repeating: 0, count: 32)
        defer { derived.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                passwordBytes.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { passwordPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        &derived,
                        derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw PaceError.unavailable("Could not derive the export key.")
        }
        return SymmetricKey(data: derived)
    }
}
