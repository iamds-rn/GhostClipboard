# Security Policy & Cryptographic Architecture

GhostClipboard is engineered around a simple invariant: **sensitive credentials should never reach persistent storage, and persisted clipboard items should never exist in plaintext on disk.**

---

## 1. Threat Model

### What GhostClipboard Protects Against
1. **Accidental Secret Persistence**: Copying passwords from 1Password/Bitwarden/Keychain, cloud API keys (`AKIA...`, `ghp_...`, `sk-...`, `sk-ant-...`, `sk_live_...`, `xoxb-...`, `AIza...`), PEM/SSH private keys, JWTs, database connection URLs with credentials, or `.env` files.
   - **Mitigation**: `SensitiveContentEngine` evaluates pasteboard metadata (`org.nspasteboard.ConcealedType`, password manager bundle IDs) and content signatures **before** any SQLite write occurs. `Level 2` (`SensitivityLevel.sensitive`) secrets are discarded immediately (`RetentionDisposition.discardImmediately`).
2. **Plaintext Disk Inspection / Forensic Leakage**: Malware, backup indexers, or unauthorized processes reading SQLite `.sqlite3`, `-wal`, or `-shm` files on disk.
   - **Mitigation**: Every persisted clip payload and preview is encrypted via `AES-256-GCM`. Furthermore, the SQLite FTS5 full-text search table (`clips_fts`) stores **zero plaintext words**—only `HMAC-SHA256` blind tokens (`bi_<16-hex>`).
3. **Opaque High-Entropy Secret Exposure**: Copying unlabeled secret tokens or password candidates that lack a known vendor prefix.
   - **Mitigation**: Standalone strings matching token/password structural heuristics with high Shannon entropy (`≥ 3.7 bits/char` across 4 character classes or `≥ 4.25 bits/char` across 3+ classes) are classified as `Level 1` (`SensitivityLevel.potentiallySensitive`) and quarantined in memory only (`RetentionDisposition.memoryOnlyEphemeral`, 10-minute quarantine TTL) and never written to SQLite unless explicitly promoted by the user.
4. **Lingering 2FA / OTP Codes**: One-time verification codes left on the system pasteboard indefinitely.
   - **Mitigation**: Ephemeral secrets (`Level 3` — `SensitivityLevel.ephemeralSecret`) live strictly in RAM (`RetentionDisposition.memoryOnlyEphemeral`) and are purged from both GhostClipboard's memory and `NSPasteboard.general` when the countdown expires.
5. **Unauthorized Local CLI Scraping**: Unprivileged scripts attempting to dump clipboard history via `ghostclipboard-cli`.
   - **Mitigation**: CLI read subcommands (`recent`, `search`, `list`) are gated by the `enableCLIAccess` preference and return exit code `2` when disabled.

### Out of Scope (Non-Goals)
- **Active Root / Kernel Compromise**: If an attacker already has root or same-UID code execution capable of reading process memory or querying the unlocked user Keychain, local encryption cannot prevent live interception of `NSPasteboard.general`.
- **Hardware Keyloggers / Screen Recording**: Physical or OS-level screen/keyboard capture occurs upstream of the macOS pasteboard.

---

## 2. Cryptographic Specification

| Component | Algorithm / Primitive | Implementation Details |
| :--- | :--- | :--- |
| **Master Vault Key** | `256-bit SymmetricKey` | Generated via Apple `CryptoKit` CSPRNG; stored in macOS Keychain (`com.ghostclipboard.security.vault`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and `0600` local key fallback (`~/.ghostclipboard/.vault_key`). |
| **Payload Encryption** | `AES-256-GCM` | `CryptoKit.AES.GCM.seal(_:using:)` with a random 96-bit nonce per encryption operation and a 128-bit authentication tag. Combined representation (`nonce \|\| ciphertext \|\| tag`) is stored as a `BLOB` (`encrypted_content`, `encrypted_preview`). |
| **Blind Index Subkey** | `HKDF<SHA256>` | Derived deterministically from the 256-bit master key using `salt = "GhostClipboard-Salt-v1"` and `info = "GhostClipboard-BlindIndex-HMAC-v1"` (`outputByteCount: 32`). |
| **FTS5 Search Tokens** | `HMAC-SHA256` (64-bit truncated token) | Normalized words, camelCase subwords, and 3–24 character prefixes are authenticated with `HMAC<SHA256>` using the blind index subkey and formatted as `bi_<16-hex>`. Stored in `clips_fts(search_tokens)`. |
| **Deduplication Digest** | `SHA-256` | Used for O(1) duplicate suppression (`content_hash`) on non-sensitive persisted clips. |

### Verifying Zero Plaintext On Disk
You can verify that neither the `clips` table nor the `clips_fts` full-text index contains any plaintext words by running the automated test suite:
```bash
swift run GhostClipboardTests
```
Specifically, Section 12 (`Zero-Plaintext HMAC-SHA256 Blind Index & Raw Disk Verification`) in `Tests/GhostClipboardTests/GhostClipboardTests.swift` checkpoints the SQLite WAL and inspects the raw bytes of the `.sqlite3` and `-wal` files on disk to assert that zero plaintext tokens or payloads exist on disk.

---

## 3. Reporting a Vulnerability

If you discover a security vulnerability, secret-detection bypass, or cryptographic flaw in GhostClipboard:

1. **Do NOT open a public GitHub issue** with exploit details right away.
2. Please report the issue privately via [GitHub Security Advisories](https://github.com/iamds-rn/GhostClipboard/security/advisories/new) on the repository.
3. Include:
   - Affected component (`SensitiveContentEngine`, `CryptoVault`, `SQLiteStorageEngine`, `GhostCLIRunner`, etc.).
   - Minimal reproduction steps or sample input (sanitized/redacted).
   - Impact assessment.

We aim to acknowledge security reports within **48 hours** and ship a verified patch + regression test in `Tests/GhostClipboardTests/GhostClipboardTests.swift` within **7 days**.
