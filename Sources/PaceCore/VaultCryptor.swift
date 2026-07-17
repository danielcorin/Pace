import CryptoKit
import Foundation

public enum VaultCryptor {
    private static let formatVersion = Data("PACE1".utf8)

    public static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw PaceError.corruptStore }
        return formatVersion + combined
    }

    public static func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        guard ciphertext.starts(with: formatVersion) else { throw PaceError.corruptStore }
        let combined = ciphertext.dropFirst(formatVersion.count)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key)
    }
}
