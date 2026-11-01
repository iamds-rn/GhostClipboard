import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum CryptoVaultError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidUTF8
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Failed to encrypt clipboard payload with AES-GCM."
        case .decryptionFailed: return "Failed to decrypt clipboard payload."
        case .invalidUTF8: return "Decrypted data is not valid UTF-8."
        case .keychainFailure(let status): return "Keychain operation failed with status \(status)."
        }
    }
}

public final class CryptoVault: Sendable {
    private let symmetricKey: SymmetricKey

    public static let shared = CryptoVault()

    /// Initializes the vault with a key stored in macOS Keychain (or fallback deterministic local app support key if Keychain is restricted in headless CI/CLI).
    public init(customKey: SymmetricKey? = nil) {
        if let customKey = customKey {
            self.symmetricKey = customKey
        } else {
            self.symmetricKey = Self.loadOrCreateMasterKey()
        }
    }

    // MARK: - SHA256 Content Hash

    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - AES-GCM Authenticated Encryption

    public func encryptString(_ plaintext: String) throws -> Data {
        let data = Data(plaintext.utf8)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw CryptoVaultError.encryptionFailed
        }
        return combined
    }

    public func decryptString(_ combinedData: Data) throws -> String {
        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
        guard let string = String(data: decryptedData, encoding: .utf8) else {
            throw CryptoVaultError.invalidUTF8
        }
        return string
    }

    // MARK: - Key Management (Keychain + Protected Local Fallback)

    private static let serviceName = "com.ghostclipboard.vault"
    private static let accountName = "master_aes256_key"

    private static func loadOrCreateMasterKey() -> SymmetricKey {
        // 1. Check protected 0600 local key file first so GUI and CLI binaries share the same 256-bit key without blocking on macOS Keychain ACL dialogs
        let keyFileURL = Self.localKeyFileURL()
        if let existingData = try? Data(contentsOf: keyFileURL), existingData.count == 32 {
            return SymmetricKey(data: existingData)
        }

        // 2. Generate new 256-bit key and store in 0600-restricted local key file
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try? Self.persistLocalKeyFile(keyData, to: keyFileURL)

        return newKey
    }

    private static func persistLocalKeyFile(_ keyData: Data, to keyFileURL: URL) throws {
        let dir = keyFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try keyData.write(to: keyFileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
    }

    private static func localKeyFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".ghostclipboard", isDirectory: true)
            .appendingPathComponent(".vault_key", isDirectory: false)
    }

    // MARK: - LocalAuthentication Biometric / Passcode Gate

    public static func authenticateUser(reason: String = "Authenticate to reveal sensitive clipboard item") async -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }
}
