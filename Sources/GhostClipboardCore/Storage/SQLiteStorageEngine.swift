import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StorageError: Error, LocalizedError {
    case openDatabaseFailed(String)
    case statementFailed(String)
    case encryptionFailure(Error)

    public var errorDescription: String? {
        switch self {
        case .openDatabaseFailed(let msg): return "SQLite open failed: \(msg)"
        case .statementFailed(let msg): return "SQLite statement failed: \(msg)"
        case .encryptionFailure(let err): return "Encryption error: \(err.localizedDescription)"
        }
    }
}

public final class SQLiteStorageEngine: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.ghostclipboard.sqlite", qos: .userInitiated)
    private let vault: CryptoVault
    public let databasePath: String

    public static func defaultDatabaseURL() -> URL {
        if let customPath = ProcessInfo.processInfo.environment["GHOSTCLIPBOARD_DB_PATH"], !customPath.isEmpty {
            let customURL = URL(fileURLWithPath: customPath)
            try? FileManager.default.createDirectory(at: customURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            return customURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".ghostclipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ghostclipboard.sqlite3", isDirectory: false)
    }

    public init(databaseURL: URL? = nil, vault: CryptoVault = .shared) throws {
        let url = databaseURL ?? Self.defaultDatabaseURL()
        self.databasePath = url.path
        self.vault = vault

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown open error"
            throw StorageError.openDatabaseFailed(msg)
        }
        sqlite3_busy_timeout(db, 3000)

        try configurePragmas()
        try migrateSchema()
        try seedDefaultCategoriesAndExclusions()
        try migrateFTSIndexToBlindTokensIfNeeded()
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Schema, Pragmas & Zero-Plaintext Blind FTS Migration

    private func configurePragmas() throws {
        try executeRaw("PRAGMA journal_mode = WAL;")
        try executeRaw("PRAGMA synchronous = NORMAL;")
        try executeRaw("PRAGMA temp_store = MEMORY;")
        try executeRaw("PRAGMA cache_size = -2000;")
        try executeRaw("PRAGMA mmap_size = 16777216;")
        try executeRaw("PRAGMA foreign_keys = ON;")
        try executeRaw("PRAGMA secure_delete = ON;")
    }

    public func releaseMemory() {
        queue.sync {
            if let db = db {
                _ = sqlite3_db_release_memory(db)
            }
        }
    }

    private func migrateSchema() throws {
        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS clips (
            id TEXT PRIMARY KEY NOT NULL,
            encrypted_content BLOB NOT NULL,
            encrypted_preview BLOB NOT NULL,
            content_hash TEXT NOT NULL,
            primary_category TEXT NOT NULL,
            secondary_categories_json TEXT NOT NULL DEFAULT '[]',
            detected_language TEXT,
            source_application TEXT,
            source_bundle_id TEXT,
            sensitivity_level INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            is_ephemeral INTEGER NOT NULL DEFAULT 0,
            character_count INTEGER NOT NULL DEFAULT 0,
            line_count INTEGER NOT NULL DEFAULT 1,
            byte_size INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_used_at REAL NOT NULL,
            expires_at REAL,
            color_json TEXT,
            url_hostname TEXT,
            is_suspicious_domain INTEGER NOT NULL DEFAULT 0,
            terminal_warning TEXT,
            detection_reasons_json TEXT NOT NULL DEFAULT '[]',
            user_overrode_category INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_clips_created_at ON clips(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_clips_primary_category ON clips(primary_category);
        CREATE INDEX IF NOT EXISTS idx_clips_content_hash ON clips(content_hash);
        CREATE INDEX IF NOT EXISTS idx_clips_expires_at ON clips(expires_at);
        CREATE INDEX IF NOT EXISTS idx_clips_pinned ON clips(is_pinned);

        CREATE TABLE IF NOT EXISTS clip_categories (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            slug TEXT UNIQUE NOT NULL,
            icon_name TEXT NOT NULL,
            sort_order INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS clip_category_assignments (
            clip_id TEXT NOT NULL,
            category_slug TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 1.0,
            is_primary INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (clip_id, category_slug),
            FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS application_exclusions (
            id TEXT PRIMARY KEY NOT NULL,
            bundle_identifier TEXT UNIQUE NOT NULL,
            application_name TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS preferences (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS excluded_events (
            id TEXT PRIMARY KEY NOT NULL,
            timestamp REAL NOT NULL,
            reason TEXT NOT NULL,
            secret_type TEXT NOT NULL,
            source_application TEXT,
            sensitivity_level INTEGER NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
            clip_id UNINDEXED,
            searchable_text,
            category,
            language,
            source_app,
            hostname
        );
        """
        try executeRaw(schemaSQL)
    }

    private func seedDefaultCategoriesAndExclusions() throws {
        queue.sync {
            for (index, cat) in ClipCategory.allCases.enumerated() {
                let sql = """
                INSERT OR IGNORE INTO clip_categories (id, name, slug, icon_name, sort_order)
                VALUES (?, ?, ?, ?, ?);
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, index: 1, value: cat.rawValue)
                bindText(stmt, index: 2, value: cat.displayName)
                bindText(stmt, index: 3, value: cat.rawValue)
                bindText(stmt, index: 4, value: cat.systemIconName)
                sqlite3_bind_int(stmt, 5, Int32(index))
                sqlite3_step(stmt)
            }

            let alreadySeeded = scalarInt("SELECT COUNT(*) FROM preferences WHERE key = 'default_exclusions_seeded';") > 0
            if !alreadySeeded {
                let defaultApps: [(String, String)] = [
                    ("com.1password.1password", "1Password"),
                    ("com.agilebits.onepassword7", "1Password 7"),
                    ("com.bitwarden.desktop", "Bitwarden"),
                    ("org.keepassxc.keepassxc", "KeePassXC"),
                    ("com.dashlane.dashlanephonefinal", "Dashlane"),
                    ("com.lastpass.LastPass", "LastPass"),
                    ("com.apple.keychainaccess", "Keychain Access"),
                    ("com.apple.Passwords", "Apple Passwords")
                ]

                for (bundleID, appName) in defaultApps {
                    let sql = """
                    INSERT OR IGNORE INTO application_exclusions (id, bundle_identifier, application_name, is_enabled, created_at)
                    VALUES (?, ?, ?, 1, ?);
                    """
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                    defer { sqlite3_finalize(stmt) }
                    bindText(stmt, index: 1, value: UUID().uuidString)
                    bindText(stmt, index: 2, value: bundleID)
                    bindText(stmt, index: 3, value: appName)
                    sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
                    sqlite3_step(stmt)
                }

                var markerStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES ('default_exclusions_seeded', '1', ?);", -1, &markerStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(markerStmt) }
                    sqlite3_bind_double(markerStmt, 1, Date().timeIntervalSince1970)
                    sqlite3_step(markerStmt)
                }
            }
        }
    }

    /// Automatically migrates any legacy plaintext FTS5 rows to HMAC-SHA256 blind tokens and vacuums the SQLite file.
    private func migrateFTSIndexToBlindTokensIfNeeded() throws {
        try queue.sync {
            let migrated = scalarInt("SELECT COUNT(*) FROM preferences WHERE key = 'blind_fts_v2_migrated' AND value = '1';") > 0
            let hasLegacyPlaintextFTS = scalarInt("SELECT COUNT(*) FROM clips_fts WHERE (searchable_text NOT LIKE 'bi_%' AND searchable_text != '') OR (category NOT LIKE 'bi_%' AND category != '');") > 0

            guard !migrated || hasLegacyPlaintextFTS else { return }

            // Fetch all existing clips and re-index with HMAC-SHA256 blind tokens
            var existingClips: [ClipItem] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT * FROM clips;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let clip = decodeClipRow(stmt) {
                        existingClips.append(clip)
                    }
                }
                sqlite3_finalize(stmt)
            }

            try executeRawInternal("DELETE FROM clips_fts;")

            for clip in existingClips where clip.sensitivityLevel == .normal && !clip.isEphemeral {
                // Ensure both url_hostname and terminal_warning are encrypted at rest
                let encHost = encryptOptionalField(clip.urlHostname)
                let encWarn = encryptOptionalField(clip.terminalSafetyWarning)
                if encHost != nil || encWarn != nil {
                    var upStmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, "UPDATE clips SET url_hostname = ?, terminal_warning = ? WHERE id = ?;", -1, &upStmt, nil) == SQLITE_OK {
                        bindOptionalText(upStmt, index: 1, value: encHost)
                        bindOptionalText(upStmt, index: 2, value: encWarn)
                        bindText(upStmt, index: 3, value: clip.id.uuidString)
                        sqlite3_step(upStmt)
                        sqlite3_finalize(upStmt)
                    }
                }
                try indexClipInFTSInternal(clip)
            }

            var markerStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES ('blind_fts_v2_migrated', '1', ?);", -1, &markerStmt, nil) == SQLITE_OK {
                sqlite3_bind_double(markerStmt, 1, Date().timeIntervalSince1970)
                sqlite3_step(markerStmt)
                sqlite3_finalize(markerStmt)
            }

            // Reclaim and overwrite any historical plaintext pages in WAL and main database file
            try? executeRawInternal("PRAGMA wal_checkpoint(TRUNCATE);")
            try? executeRawInternal("VACUUM;")
        }
    }

    private func encryptOptionalField(_ plaintext: String?) -> String? {
        guard let plaintext = plaintext, !plaintext.isEmpty else { return nil }
        guard let encrypted = try? vault.encryptString(plaintext) else { return nil }
        return "enc:" + encrypted.base64EncodedString()
    }

    private func decryptOptionalField(_ stored: String?) -> String? {
        guard let stored = stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("enc:") {
            let b64 = String(stored.dropFirst(4))
            guard let data = Data(base64Encoded: b64),
                  let decrypted = try? vault.decryptString(data) else {
                return nil
            }
            return decrypted
        }
        return stored
    }

    // MARK: - Save & Update Clips

    /// Persists a clip. Note: Security rule 6.1 strictly forbids Level 2/3 sensitive secrets from being persisted in SQLite.
    public func saveClip(_ clip: ClipItem, ignoreDuplicates: Bool = true) throws {
        // Hard security invariant check: never persist Level 2 or Level 3 or ephemeral items to disk
        guard clip.sensitivityLevel == .normal && !clip.isEphemeral else {
            return
        }

        try queue.sync {
            try saveClipInternal(clip, ignoreDuplicates: ignoreDuplicates)
        }
    }

    /// High-throughput batch insert inside a single SQLite transaction on the persistent connection.
    public func saveClipsBatch(_ clips: [ClipItem], ignoreDuplicates: Bool = true) throws {
        try queue.sync {
            try executeRawInternal("BEGIN IMMEDIATE TRANSACTION;")
            do {
                for clip in clips where clip.sensitivityLevel == .normal && !clip.isEphemeral {
                    try saveClipInternal(clip, ignoreDuplicates: ignoreDuplicates)
                }
                try executeRawInternal("COMMIT;")
            } catch {
                try? executeRawInternal("ROLLBACK;")
                throw error
            }
        }
    }

    private func saveClipInternal(_ clip: ClipItem, ignoreDuplicates: Bool) throws {
        if ignoreDuplicates, let existingID = try findClipIDByHashInternal(clip.contentHash) {
            try touchClipInternal(id: existingID, at: clip.createdAt)
            return
        }

        let encryptedContent = try vault.encryptString(clip.content)
        let encryptedPreview = try vault.encryptString(clip.contentPreview)
        let encryptedHostname = encryptOptionalField(clip.urlHostname)
        let encryptedWarning = encryptOptionalField(clip.terminalSafetyWarning)

        let secondaryJSON = (try? String(data: JSONEncoder().encode(clip.secondaryCategories), encoding: .utf8)) ?? "[]"
        let colorJSON = clip.colorComponents.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        let reasonsJSON = (try? String(data: JSONEncoder().encode(clip.detectionReasons), encoding: .utf8)) ?? "[]"

        let sql = """
        INSERT OR REPLACE INTO clips (
            id, encrypted_content, encrypted_preview, content_hash,
            primary_category, secondary_categories_json, detected_language,
            source_application, source_bundle_id, sensitivity_level,
            is_pinned, is_favorite, is_ephemeral,
            character_count, line_count, byte_size,
            created_at, updated_at, last_used_at, expires_at,
            color_json, url_hostname, is_suspicious_domain,
            terminal_warning, detection_reasons_json, user_overrode_category
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StorageError.statementFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, value: clip.id.uuidString)
        bindBlob(stmt, index: 2, data: encryptedContent)
        bindBlob(stmt, index: 3, data: encryptedPreview)
        bindText(stmt, index: 4, value: clip.contentHash)
        bindText(stmt, index: 5, value: clip.primaryCategory.rawValue)
        bindText(stmt, index: 6, value: secondaryJSON)
        bindOptionalText(stmt, index: 7, value: clip.detectedLanguage?.rawValue)
        bindOptionalText(stmt, index: 8, value: clip.sourceApplication)
        bindOptionalText(stmt, index: 9, value: clip.sourceBundleID)
        sqlite3_bind_int(stmt, 10, Int32(clip.sensitivityLevel.rawValue))
        sqlite3_bind_int(stmt, 11, clip.isPinned ? 1 : 0)
        sqlite3_bind_int(stmt, 12, clip.isFavorite ? 1 : 0)
        sqlite3_bind_int(stmt, 13, clip.isEphemeral ? 1 : 0)
        sqlite3_bind_int(stmt, 14, Int32(clip.characterCount))
        sqlite3_bind_int(stmt, 15, Int32(clip.lineCount))
        sqlite3_bind_int(stmt, 16, Int32(clip.byteSize))
        sqlite3_bind_double(stmt, 17, clip.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 18, clip.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 19, clip.lastUsedAt.timeIntervalSince1970)
        if let exp = clip.expiresAt {
            sqlite3_bind_double(stmt, 20, exp.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 20)
        }
        bindOptionalText(stmt, index: 21, value: colorJSON)
        bindOptionalText(stmt, index: 22, value: encryptedHostname)
        sqlite3_bind_int(stmt, 23, clip.isSuspiciousDomain ? 1 : 0)
        bindOptionalText(stmt, index: 24, value: encryptedWarning)
        bindText(stmt, index: 25, value: reasonsJSON)
        sqlite3_bind_int(stmt, 26, clip.userOverrodeCategory ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StorageError.statementFailed(lastErrorMessage())
        }

        // Record category assignments
        try updateCategoryAssignmentsInternal(for: clip)

        // Index in FTS5 ONLY for Level 0 normal items using HMAC-SHA256 blind tokens
        if clip.sensitivityLevel == .normal && !clip.isEphemeral {
            try indexClipInFTSInternal(clip)
        }
    }

    private func updateCategoryAssignmentsInternal(for clip: ClipItem) throws {
        let deleteSQL = "DELETE FROM clip_category_assignments WHERE clip_id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &delStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(delStmt) }
            bindText(delStmt, index: 1, value: clip.id.uuidString)
            sqlite3_step(delStmt)
        }

        let insertSQL = """
        INSERT OR REPLACE INTO clip_category_assignments (clip_id, category_slug, confidence, is_primary)
        VALUES (?, ?, ?, ?);
        """
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(insStmt) }
            bindText(insStmt, index: 1, value: clip.id.uuidString)
            bindText(insStmt, index: 2, value: clip.primaryCategory.rawValue)
            sqlite3_bind_double(insStmt, 3, 1.0)
            sqlite3_bind_int(insStmt, 4, 1)
            sqlite3_step(insStmt)
        }

        for secondary in clip.secondaryCategories {
            var secStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &secStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(secStmt) }
                bindText(secStmt, index: 1, value: clip.id.uuidString)
                bindText(secStmt, index: 2, value: secondary.rawValue)
                sqlite3_bind_double(secStmt, 3, 0.8)
                sqlite3_bind_int(secStmt, 4, 0)
                sqlite3_step(secStmt)
            }
        }
    }

    /// Stores ONLY HMAC-SHA256 blind index tokens (`bi_<16hex>`) in `clips_fts` so zero plaintext content or hostname exists on disk.
    private func indexClipInFTSInternal(_ clip: ClipItem) throws {
        let delSQL = "DELETE FROM clips_fts WHERE clip_id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(delStmt) }
            bindText(delStmt, index: 1, value: clip.id.uuidString)
            sqlite3_step(delStmt)
        }

        let combinedIndexableText = [
            clip.content,
            clip.primaryCategory.displayName,
            clip.primaryCategory.shortLabel,
            clip.detectedLanguage?.rawValue ?? "",
            clip.sourceApplication ?? "",
            clip.urlHostname ?? ""
        ].joined(separator: " ")

        let blindSearchableTokens = vault.blindIndexTokens(for: combinedIndexableText)
        let blindCategoryTokens = vault.blindIndexTokens(for: clip.primaryCategory.displayName)
        let blindLangTokens = vault.blindIndexTokens(for: clip.detectedLanguage?.rawValue ?? "")
        let blindAppTokens = vault.blindIndexTokens(for: clip.sourceApplication ?? "")
        let blindHostTokens = vault.blindIndexTokens(for: clip.urlHostname ?? "")

        let insSQL = """
        INSERT INTO clips_fts (clip_id, searchable_text, category, language, source_app, hostname)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insSQL, -1, &insStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(insStmt) }
            bindText(insStmt, index: 1, value: clip.id.uuidString)
            bindText(insStmt, index: 2, value: blindSearchableTokens)
            bindText(insStmt, index: 3, value: blindCategoryTokens)
            bindText(insStmt, index: 4, value: blindLangTokens)
            bindText(insStmt, index: 5, value: blindAppTokens)
            bindText(insStmt, index: 6, value: blindHostTokens)
            sqlite3_step(insStmt)
        }
    }

    private func findClipIDByHashInternal(_ hash: String) throws -> UUID? {
        let sql = "SELECT id FROM clips WHERE content_hash = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: hash)
        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            return UUID(uuidString: String(cString: cStr))
        }
        return nil
    }

    private func touchClipInternal(id: UUID, at date: Date) throws {
        let sql = "UPDATE clips SET created_at = ?, updated_at = ?, last_used_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let ts = date.timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, ts)
        sqlite3_bind_double(stmt, 2, ts)
        sqlite3_bind_double(stmt, 3, ts)
        bindText(stmt, index: 4, value: id.uuidString)
        sqlite3_step(stmt)
    }

    // MARK: - Fetch & Search Clips (Cryptographic Blind FTS5 + Decrypted Substring Verification)

    public func searchClips(
        _ query: String,
        category: ClipCategory? = nil,
        pinnedOnly: Bool = false,
        expiringOnly: Bool = false,
        limit: Int = 200
    ) throws -> [ClipItem] {
        try fetchClips(
            query: query,
            category: category,
            pinnedOnly: pinnedOnly,
            expiringOnly: expiringOnly,
            limit: limit
        )
    }

    public func fetchClips(
        query: String? = nil,
        category: ClipCategory? = nil,
        pinnedOnly: Bool = false,
        expiringOnly: Bool = false,
        limit: Int = 200
    ) throws -> [ClipItem] {
        try queue.sync {
            try fetchClipsInternal(
                query: query,
                category: category,
                pinnedOnly: pinnedOnly,
                expiringOnly: expiringOnly,
                limit: limit
            )
        }
    }

    private func fetchClipsInternal(
        query: String?,
        category: ClipCategory?,
        pinnedOnly: Bool,
        expiringOnly: Bool,
        limit: Int
    ) throws -> [ClipItem] {
        var baseConditions: [String] = []
        var baseBindings: [String] = []

        if let category = category {
            baseConditions.append("(c.primary_category = ? OR EXISTS (SELECT 1 FROM clip_category_assignments ca WHERE ca.clip_id = c.id AND ca.category_slug = ?))")
            baseBindings.append(category.rawValue)
            baseBindings.append(category.rawValue)
        }

        if pinnedOnly {
            baseConditions.append("(c.is_pinned = 1 OR c.is_favorite = 1)")
        }

        if expiringOnly {
            baseConditions.append("(c.expires_at IS NOT NULL AND c.is_pinned = 0)")
        }

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Case 1: No search query — return filtered rows directly
        if trimmedQuery.isEmpty {
            var sql = "SELECT c.* FROM clips c "
            if !baseConditions.isEmpty {
                sql += "WHERE " + baseConditions.joined(separator: " AND ") + " "
            }
            sql += "ORDER BY c.is_pinned DESC, c.created_at DESC LIMIT \(max(1, limit));"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.statementFailed(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, val) in baseBindings.enumerated() {
                bindText(stmt, index: Int32(i + 1), value: val)
            }

            var items: [ClipItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = decodeClipRow(stmt) {
                    items.append(item)
                }
            }
            return items
        }

        // Case 2: Non-empty search query
        // 2a. Fast cryptographic blind FTS5 lookup for 3+ char word/prefix tokens
        var results: [ClipItem] = []
        var seenIDs = Set<UUID>()
        let blindMatchExpr = buildBlindFTSMatchExpression(for: trimmedQuery)

        if !blindMatchExpr.isEmpty {
            var ftsConditions = baseConditions
            var ftsBindings = baseBindings
            ftsConditions.append("clips_fts MATCH ?")
            ftsBindings.append(blindMatchExpr)

            var ftsSQL = "SELECT c.* FROM clips c JOIN clips_fts f ON f.clip_id = c.id "
            ftsSQL += "WHERE " + ftsConditions.joined(separator: " AND ") + " "
            ftsSQL += "ORDER BY c.is_pinned DESC, c.created_at DESC LIMIT \(max(1, limit));"

            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, ftsSQL, -1, &ftsStmt, nil) == SQLITE_OK {
                for (i, val) in ftsBindings.enumerated() {
                    bindText(ftsStmt, index: Int32(i + 1), value: val)
                }
                while sqlite3_step(ftsStmt) == SQLITE_ROW {
                    if let item = decodeClipRow(ftsStmt), clipMatchesQueryInMemory(item, query: trimmedQuery) {
                        if seenIDs.insert(item.id).inserted {
                            results.append(item)
                        }
                    }
                }
                sqlite3_finalize(ftsStmt)
            }
        }

        // 2b. Hybrid decrypted in-memory scan over recent items so arbitrary substrings ("lateHa"),
        // short 1-2 char queries, and symbol/hex queries ("#FF5733", "===", ".env") are 100% accurate
        if results.count < limit {
            let allCandidates = try fetchClipsInternal(
                query: nil,
                category: category,
                pinnedOnly: pinnedOnly,
                expiringOnly: expiringOnly,
                limit: max(limit, 300)
            )
            for candidate in allCandidates where !seenIDs.contains(candidate.id) {
                if clipMatchesQueryInMemory(candidate, query: trimmedQuery) {
                    seenIDs.insert(candidate.id)
                    results.append(candidate)
                    if results.count >= limit {
                        break
                    }
                }
            }
        }

        return results
    }

    private func buildBlindFTSMatchExpression(for rawQuery: String) -> String {
        let blindTokens = vault.blindIndexQueryTokens(for: rawQuery)
        guard !blindTokens.isEmpty else { return "" }
        return blindTokens.map { "\"\($0)\"" }.joined(separator: " AND ")
    }

    private func clipMatchesQueryInMemory(_ clip: ClipItem, query: String) -> Bool {
        let lowerQ = query.lowercased()
        let haystack = [
            clip.content.lowercased(),
            clip.primaryCategory.displayName.lowercased(),
            clip.primaryCategory.shortLabel.lowercased(),
            clip.detectedLanguage?.rawValue.lowercased() ?? "",
            clip.sourceApplication?.lowercased() ?? "",
            clip.urlHostname?.lowercased() ?? ""
        ].joined(separator: " ")

        if haystack.contains(lowerQ) {
            return true
        }

        // Multi-token check: all whitespace-separated query words appear somewhere in the clip or metadata
        let words = lowerQ.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1 && words.allSatisfy({ haystack.contains($0) }) {
            return true
        }

        // Punctuation-separated multi-token check (e.g. "Xcode: calculate" or "deploy, release")
        let alphaNumTokens = lowerQ.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if !alphaNumTokens.isEmpty && alphaNumTokens.allSatisfy({ haystack.contains($0) }) {
            // Also verify any non-ASCII symbols/emojis in the query (e.g. "🚀 deploy") are present
            let nonASCIISymbols = lowerQ.filter { !$0.isASCII && !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
            if nonASCIISymbols.allSatisfy({ haystack.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func fetchClipByIDInternal(_ clipID: UUID) -> ClipItem? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM clips WHERE id = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: clipID.uuidString)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return decodeClipRow(stmt)
        }
        return nil
    }

    private func decodeClipRow(_ stmt: OpaquePointer?) -> ClipItem? {
        guard let stmt = stmt,
              let idStr = columnText(stmt, 0),
              let id = UUID(uuidString: idStr),
              let encContent = columnBlob(stmt, 1),
              let encPreview = columnBlob(stmt, 2),
              let contentHash = columnText(stmt, 3),
              let primaryCatRaw = columnText(stmt, 4) else {
            return nil
        }

        guard let decryptedContent = try? vault.decryptString(encContent),
              let decryptedPreview = try? vault.decryptString(encPreview) else {
            return nil
        }

        let primaryCategory = ClipCategory(rawValue: primaryCatRaw) ?? .plainText
        let secJSON = columnText(stmt, 5) ?? "[]"
        let secondaryCategories = (try? JSONDecoder().decode([ClipCategory].self, from: Data(secJSON.utf8))) ?? []
        let detectedLang = columnText(stmt, 6).flatMap { ProgrammingLanguage(rawValue: $0) }
        let sourceApp = columnText(stmt, 7)
        let sourceBundle = columnText(stmt, 8)
        let sensitivity = SensitivityLevel(rawValue: Int(sqlite3_column_int(stmt, 9))) ?? .normal
        let isPinned = sqlite3_column_int(stmt, 10) != 0
        let isFavorite = sqlite3_column_int(stmt, 11) != 0
        let isEphemeral = sqlite3_column_int(stmt, 12) != 0
        let charCount = Int(sqlite3_column_int(stmt, 13))
        let lineCount = Int(sqlite3_column_int(stmt, 14))
        let byteSize = Int(sqlite3_column_int(stmt, 15))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16))
        let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 17))
        let lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 18))

        let expiresAt: Date?
        if sqlite3_column_type(stmt, 19) != SQLITE_NULL {
            expiresAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 19))
        } else {
            expiresAt = nil
        }

        let colorComponents = columnText(stmt, 20).flatMap {
            try? JSONDecoder().decode(ColorComponents.self, from: Data($0.utf8))
        }
        let urlHostname = decryptOptionalField(columnText(stmt, 21))
        let isSuspicious = sqlite3_column_int(stmt, 22) != 0
        let terminalWarning = decryptOptionalField(columnText(stmt, 23))
        let reasonsJSON = columnText(stmt, 24) ?? "[]"
        let reasons = (try? JSONDecoder().decode([String].self, from: Data(reasonsJSON.utf8))) ?? []
        let userOverrode = sqlite3_column_int(stmt, 25) != 0

        return ClipItem(
            id: id,
            content: decryptedContent,
            contentPreview: decryptedPreview,
            contentHash: contentHash,
            primaryCategory: primaryCategory,
            secondaryCategories: secondaryCategories,
            detectedLanguage: detectedLang,
            sourceApplication: sourceApp,
            sourceBundleID: sourceBundle,
            sensitivityLevel: sensitivity,
            isPinned: isPinned,
            isFavorite: isFavorite,
            isEphemeral: isEphemeral,
            characterCount: charCount,
            lineCount: lineCount,
            byteSize: byteSize,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastUsedAt: lastUsedAt,
            expiresAt: expiresAt,
            colorComponents: colorComponents,
            urlHostname: urlHostname,
            isSuspiciousDomain: isSuspicious,
            terminalSafetyWarning: terminalWarning,
            detectionReasons: reasons,
            userOverrodeCategory: userOverrode
        )
    }

    // MARK: - Mutations (Pin, Category Override, Delete, Expiration Purge)

    public func togglePin(clipID: UUID, isPinned: Bool) throws {
        queue.sync {
            let sql = "UPDATE clips SET is_pinned = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, isPinned ? 1 : 0)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, index: 3, value: clipID.uuidString)
            sqlite3_step(stmt)
        }
    }

    public func overrideCategory(clipID: UUID, newCategory: ClipCategory) throws {
        try queue.sync {
            let sql = "UPDATE clips SET primary_category = ?, user_overrode_category = 1, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bindText(stmt, index: 1, value: newCategory.rawValue)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, index: 3, value: clipID.uuidString)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if let updatedClip = fetchClipByIDInternal(clipID) {
                try updateCategoryAssignmentsInternal(for: updatedClip)
                if updatedClip.sensitivityLevel == .normal && !updatedClip.isEphemeral {
                    try indexClipInFTSInternal(updatedClip)
                }
            }
        }
    }

    public func markClipUsed(clipID: UUID) throws {
        queue.sync {
            let sql = "UPDATE clips SET last_used_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            bindText(stmt, index: 2, value: clipID.uuidString)
            sqlite3_step(stmt)
        }
    }

    public func deleteClip(clipID: UUID) throws {
        queue.sync {
            let delFTS = "DELETE FROM clips_fts WHERE clip_id = ?;"
            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, delFTS, -1, &ftsStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(ftsStmt) }
                bindText(ftsStmt, index: 1, value: clipID.uuidString)
                sqlite3_step(ftsStmt)
            }

            let delClip = "DELETE FROM clips WHERE id = ?;"
            var clipStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, delClip, -1, &clipStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(clipStmt) }
                bindText(clipStmt, index: 1, value: clipID.uuidString)
                sqlite3_step(clipStmt)
            }
        }
    }

    @discardableResult
    public func purgeExpiredClips(now: Date = Date()) throws -> Int {
        queue.sync {
            let ts = now.timeIntervalSince1970
            let selectSQL = "SELECT id FROM clips WHERE is_pinned = 0 AND expires_at IS NOT NULL AND expires_at <= ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)

            var expiredIDs: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = columnText(stmt, 0) {
                    expiredIDs.append(idStr)
                }
            }

            for idStr in expiredIDs {
                var ftsStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM clips_fts WHERE clip_id = ?;", -1, &ftsStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(ftsStmt) }
                    bindText(ftsStmt, index: 1, value: idStr)
                    sqlite3_step(ftsStmt)
                }

                var delStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM clips WHERE id = ?;", -1, &delStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(delStmt) }
                    bindText(delStmt, index: 1, value: idStr)
                    sqlite3_step(delStmt)
                }
            }

            return expiredIDs.count
        }
    }

    public func clearAllHistory(keepPinned: Bool = false) throws {
        try queue.sync {
            if keepPinned {
                try executeRawInternal("DELETE FROM clips_fts WHERE clip_id IN (SELECT id FROM clips WHERE is_pinned = 0);")
                try executeRawInternal("DELETE FROM clips WHERE is_pinned = 0;")
            } else {
                try executeRawInternal("DELETE FROM clips_fts;")
                try executeRawInternal("DELETE FROM clip_category_assignments;")
                try executeRawInternal("DELETE FROM clips;")
                try executeRawInternal("DELETE FROM excluded_events;")
            }
            try? executeRawInternal("PRAGMA wal_checkpoint(TRUNCATE);")
            try executeRawInternal("VACUUM;")
        }
    }

    // MARK: - Excluded Events (Transparent Audit Log without Secret Payload)

    public func recordExcludedEvent(_ event: ExcludedCaptureEvent) throws {
        queue.sync {
            let sql = """
            INSERT INTO excluded_events (id, timestamp, reason, secret_type, source_application, sensitivity_level)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: event.id.uuidString)
            sqlite3_bind_double(stmt, 2, event.timestamp.timeIntervalSince1970)
            bindText(stmt, index: 3, value: event.reason)
            bindText(stmt, index: 4, value: event.secretType)
            bindOptionalText(stmt, index: 5, value: event.sourceApplication)
            sqlite3_bind_int(stmt, 6, Int32(event.sensitivityLevel.rawValue))
            sqlite3_step(stmt)
        }
    }

    public func fetchExcludedEvents(limit: Int = 100) throws -> [ExcludedCaptureEvent] {
        queue.sync {
            let sql = "SELECT id, timestamp, reason, secret_type, source_application, sensitivity_level FROM excluded_events ORDER BY timestamp DESC LIMIT \(max(1, limit));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var events: [ExcludedCaptureEvent] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = columnText(stmt, 0),
                      let id = UUID(uuidString: idStr),
                      let reason = columnText(stmt, 2),
                      let secretType = columnText(stmt, 3) else { continue }
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let app = columnText(stmt, 4)
                let level = SensitivityLevel(rawValue: Int(sqlite3_column_int(stmt, 5))) ?? .sensitive
                events.append(ExcludedCaptureEvent(
                    id: id,
                    timestamp: ts,
                    reason: reason,
                    secretType: secretType,
                    sourceApplication: app,
                    sensitivityLevel: level
                ))
            }
            return events
        }
    }

    // MARK: - Application Exclusions

    public func fetchApplicationExclusions() throws -> [ApplicationExclusion] {
        queue.sync {
            let sql = "SELECT id, bundle_identifier, application_name, is_enabled, created_at FROM application_exclusions ORDER BY application_name ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var list: [ApplicationExclusion] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idStr = columnText(stmt, 0),
                      let id = UUID(uuidString: idStr),
                      let bundle = columnText(stmt, 1),
                      let name = columnText(stmt, 2) else { continue }
                let enabled = sqlite3_column_int(stmt, 3) != 0
                let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                list.append(ApplicationExclusion(
                    id: id,
                    bundleIdentifier: bundle,
                    applicationName: name,
                    isEnabled: enabled,
                    createdAt: created
                ))
            }
            return list
        }
    }

    public func saveApplicationExclusion(_ exclusion: ApplicationExclusion) throws {
        queue.sync {
            let sql = """
            INSERT OR REPLACE INTO application_exclusions (id, bundle_identifier, application_name, is_enabled, created_at)
            VALUES (?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: exclusion.id.uuidString)
            bindText(stmt, index: 2, value: exclusion.bundleIdentifier)
            bindText(stmt, index: 3, value: exclusion.applicationName)
            sqlite3_bind_int(stmt, 4, exclusion.isEnabled ? 1 : 0)
            sqlite3_bind_double(stmt, 5, exclusion.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func deleteApplicationExclusion(id: UUID) throws {
        queue.sync {
            let sql = "DELETE FROM application_exclusions WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: id.uuidString)
            sqlite3_step(stmt)
        }
    }

    public func updateClipContent(clipID: UUID, newContent: String) throws {
        try queue.sync {
            let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = String(trimmed.prefix(240)).replacingOccurrences(of: "\n", with: " ↵ ")
            let encContent = try vault.encryptString(newContent)
            let encPreview = try vault.encryptString(preview)
            let newHash = CryptoVault.sha256Hex(trimmed)
            let charCount = newContent.count
            let lineCount = max(1, newContent.components(separatedBy: .newlines).count)
            let byteSize = newContent.utf8.count

            let sql = """
            UPDATE clips
            SET encrypted_content = ?, encrypted_preview = ?, content_hash = ?,
                character_count = ?, line_count = ?, byte_size = ?, updated_at = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt, index: 1, data: encContent)
            bindBlob(stmt, index: 2, data: encPreview)
            bindText(stmt, index: 3, value: newHash)
            sqlite3_bind_int(stmt, 4, Int32(charCount))
            sqlite3_bind_int(stmt, 5, Int32(lineCount))
            sqlite3_bind_int(stmt, 6, Int32(byteSize))
            sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
            bindText(stmt, index: 8, value: clipID.uuidString)
            sqlite3_step(stmt)

            if let updatedClip = fetchClipByIDInternal(clipID),
               updatedClip.sensitivityLevel == .normal && !updatedClip.isEphemeral {
                try indexClipInFTSInternal(updatedClip)
            }
        }
    }

    public func updateStandardRetentionDays(_ days: Int) throws {
        queue.sync {
            let seconds = Double(max(1, days) * 86_400)
            let sql = "UPDATE clips SET expires_at = created_at + ? WHERE is_pinned = 0 AND is_ephemeral = 0;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, seconds)
            sqlite3_step(stmt)
        }
    }

    /// Checkpoints the WAL file into the main database file so on-disk inspections and backups see a single consolidated file.
    public func checkpointDatabase() {
        queue.sync {
            try? executeRawInternal("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    // MARK: - Preferences Storage

    public func loadPreferences() -> GhostPreferences {
        loadPreferencesWithTimestamp().preferences
    }

    public func loadPreferencesWithTimestamp() -> (preferences: GhostPreferences, updatedAt: TimeInterval) {
        queue.sync {
            let sql = "SELECT value, updated_at FROM preferences WHERE key = 'app_preferences' LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return (GhostPreferences(), 0)
            }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW,
               let json = columnText(stmt, 0),
               let prefs = try? JSONDecoder().decode(GhostPreferences.self, from: Data(json.utf8)) {
                let updatedAt = sqlite3_column_double(stmt, 1)
                return (prefs, updatedAt)
            }
            return (GhostPreferences(), 0)
        }
    }

    @discardableResult
    public func savePreferences(_ prefs: GhostPreferences) throws -> TimeInterval {
        try queue.sync {
            let data = try JSONEncoder().encode(prefs)
            guard let json = String(data: data, encoding: .utf8) else { return 0 }
            let now = Date().timeIntervalSince1970
            let sql = "INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES ('app_preferences', ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: json)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_step(stmt)
            return now
        }
    }

    // MARK: - Database Statistics

    public struct StorageStats: Sendable {
        public let totalClips: Int
        public let pinnedClips: Int
        public let excludedEventsCount: Int
        public let databaseSizeBytes: Int64
    }

    public func fetchStorageStats() -> StorageStats {
        queue.sync {
            let total = scalarInt("SELECT COUNT(*) FROM clips;")
            let pinned = scalarInt("SELECT COUNT(*) FROM clips WHERE is_pinned = 1;")
            let excluded = scalarInt("SELECT COUNT(*) FROM excluded_events;")
            let mainSize = (try? FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? Int64) ?? 0
            let walSize = (try? FileManager.default.attributesOfItem(atPath: databasePath + "-wal")[.size] as? Int64) ?? 0
            return StorageStats(
                totalClips: total,
                pinnedClips: pinned,
                excludedEventsCount: excluded,
                databaseSizeBytes: mainSize + walSize
            )
        }
    }

    // MARK: - Low-Level SQLite Helpers

    private func scalarInt(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func executeRaw(_ sql: String) throws {
        try queue.sync {
            try executeRawInternal(sql)
        }
    }

    private func executeRawInternal(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errMsg)
            throw StorageError.statementFailed(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value = value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer?, index: Int32, data: Data) {
        _ = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT_DESTRUCTOR)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cStr)
    }

    private func columnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    private func lastErrorMessage() -> String {
        guard let db = db, let cStr = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: cStr)
    }
}
