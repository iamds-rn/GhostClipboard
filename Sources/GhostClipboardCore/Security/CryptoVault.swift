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
    private let blindIndexKey: SymmetricKey

    public static let shared = CryptoVault()

    /// Initializes the vault with a 256-bit master key and derives a dedicated HMAC-SHA256 subkey via HKDF for zero-plaintext blind search indexing.
    public init(customKey: SymmetricKey? = nil) {
        let master = customKey ?? Self.loadOrCreateMasterKey()
        self.symmetricKey = master
        self.blindIndexKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data("GhostClipboard-Salt-v1".utf8),
            info: Data("GhostClipboard-BlindIndex-HMAC-v1".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - SHA256 Content Hash

    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Zero-Plaintext HMAC-SHA256 Blind Indexing

    /// Computes a single HMAC-SHA256 blind token (`bi_<16hex>`) for a normalized word or prefix.
    public func blindIndexToken(for rawToken: String) -> String {
        let normalized = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "" }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: blindIndexKey)
        let prefixHex = mac.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "bi_\(prefixHex)"
    }

    /// Generates space-separated HMAC-SHA256 blind-index tokens for a document (words, camelCase subwords, and 3+ char prefixes).
    /// Zero plaintext words or substrings are emitted.
    public func blindIndexTokens(for text: String) -> String {
        let candidateTokens = Self.extractIndexableNormalizedTokens(from: text)
        guard !candidateTokens.isEmpty else { return "" }
        return candidateTokens.map { blindIndexToken(for: $0) }.joined(separator: " ")
    }

    /// Static convenience wrapper using `CryptoVault.shared`.
    public static func blindIndexTokens(for text: String) -> String {
        shared.blindIndexTokens(for: text)
    }

    /// Produces the exact HMAC-SHA256 blind tokens to match in FTS5 for a user search query.
    public func blindIndexQueryTokens(for query: String) -> [String] {
        let rawWords = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        guard !rawWords.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for word in rawWords {
            let clipped = String(word.prefix(24))
            let hashed = blindIndexToken(for: clipped)
            if !hashed.isEmpty && seen.insert(hashed).inserted {
                result.append(hashed)
            }
        }
        return result
    }

    private static func extractIndexableNormalizedTokens(from text: String) -> [String] {
        // Split on non-alphanumeric boundaries
        let rawParts = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var expandedWords: [String] = []
        expandedWords.reserveCapacity(min(rawParts.count * 2, 256))

        for part in rawParts.prefix(160) {
            let lower = part.lowercased()
            expandedWords.append(lower)

            // Also split camelCase transitions (e.g. "calculateHash" -> "calculate", "hash")
            let camelSubwords = splitCamelCase(part)
            if camelSubwords.count > 1 {
                for sub in camelSubwords where sub.count >= 3 {
                    expandedWords.append(sub.lowercased())
                }
            }
        }

        var uniqueTokens = Set<String>()
        var orderedTokens: [String] = []

        func addToken(_ t: String) {
            guard !t.isEmpty, uniqueTokens.count < 320 else { return }
            if uniqueTokens.insert(t).inserted {
                orderedTokens.append(t)
            }
        }

        for word in expandedWords {
            let capped = String(word.prefix(24))
            if capped.count >= 1 {
                addToken(capped)
            }
            // Generate prefixes of length 3 ... min(capped.count, 16) so 3+ char prefix queries hit the blind index
            if capped.count >= 3 {
                let maxPrefix = min(capped.count, 16)
                for len in 3...maxPrefix {
                    addToken(String(capped.prefix(len)))
                }
            }
        }

        return orderedTokens
    }

    private static func splitCamelCase(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var prevWasLower = false
        for ch in word {
            if ch.isUppercase && prevWasLower && !current.isEmpty {
                parts.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
            prevWasLower = ch.isLowercase
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
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

    // MARK: - Dual-Mode Key Management (0600 Vault File + macOS Keychain Backup/Sync)

    private static let serviceName = "com.ghostclipboard.vault"
    private static let accountName = "master_aes256_key"

    private static func loadOrCreateMasterKey() -> SymmetricKey {
        // 1. Check protected 0600 local key file first so GUI and CLI binaries share the same 256-bit key without blocking on macOS Keychain ACL dialogs
        let keyFileURL = Self.localKeyFileURL()
        if let existingData = try? Data(contentsOf: keyFileURL), existingData.count == 32 {
            // Ensure 0600 permissions are enforced
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
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

    public static func localKeyFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".ghostclipboard", isDirectory: true)
            .appendingPathComponent(".vault_key", isDirectory: false)
    }

    /// Exports/backs up the current 256-bit master key into the macOS login Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
    @discardableResult
    public func backupMasterKeyToKeychain() -> Bool {
        let keyData = symmetricKey.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: Self.accountName
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = keyData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
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
