import CryptoKit
import Foundation
import Security

public final class VaultKeyStore: @unchecked Sendable {
    private let service = "com.pace.clipboard.vault"
    private let account = "master-key"

    public init() {}

    public func unlock() throws -> SymmetricKey {
#if DEBUG
        return try loadOrCreateDevelopmentKey()
#else
        if let existing = try read() {
            return SymmetricKey(data: existing)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try store(keyData)
        return key
#endif
    }

    // The key lives in the login keychain. A SecAccessControl(.userPresence)
    // item would land in the data protection keychain, which requires a
    // provisioning-profile-backed application-identifier entitlement that a
    // Developer ID app doesn't have (SecItemAdd fails with -34018).
    private func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw PaceError.authenticationFailed(
                SecCopyErrorMessageString(status, nil) as String? ?? "Keychain access failed."
            )
        }
        return data
    }

    private func store(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Pace Vault Key",
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PaceError.authenticationFailed(
                SecCopyErrorMessageString(status, nil) as String? ?? "Could not save the vault key."
            )
        }
    }

#if DEBUG
    private func loadOrCreateDevelopmentKey() throws -> SymmetricKey {
        let fileManager = FileManager.default
        let directory = PacePaths.applicationSupportDirectory
        let keyURL = directory.appendingPathComponent("DevelopmentVault.key")

        if fileManager.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else {
                throw PaceError.corruptStore
            }
            return SymmetricKey(data: data)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return key
    }
#endif
}
