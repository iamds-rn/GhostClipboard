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
    private let queue = DispatchQueue(label: "com.ghostclipboard.sqlite.queue", qos: .userInitiated)
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

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown open error"
            throw StorageError.openDatabaseFailed(msg)
        }
        sqlite3_busy_timeout(db, 3000)

        try configurePragmas()
        try migrateSchema()
        try seedDefaultCategoriesAndExclusions()
    }

    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Schema & Migrations (Section 10.1 & 10.2)

    private func configurePragmas() throws {
        try executeRaw("PRAGMA journal_mode = WAL;")
        try executeRaw("PRAGMA synchronous = NORMAL;")
        try executeRaw("PRAGMA foreign_keys = ON;")
        try executeRaw("PRAGMA secure_delete = ON;")
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

    // MARK: - Save & Update Clips

    /// Persists a clip. Note: Security rule 6.1 strictly forbids Level 2/3 sensitive secrets from being persisted in SQLite.
    public func saveClip(_ clip: ClipItem, ignoreDuplicates: Bool = true) throws {
        // Hard security invariant check: never persist Level 2 or Level 3 or ephemeral items to disk
        guard clip.sensitivityLevel == .normal && !clip.isEphemeral else {
            return
        }

        try queue.sync {
            if ignoreDuplicates, let existingID = try findClipIDByHashInternal(clip.contentHash) {
                try touchClipInternal(id: existingID, at: clip.createdAt)
                return
            }

            let encryptedContent = try vault.encryptString(clip.content)
            let encryptedPreview = try vault.encryptString(clip.contentPreview)

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
            bindOptionalText(stmt, index: 22, value: clip.urlHostname)
            sqlite3_bind_int(stmt, 23, clip.isSuspiciousDomain ? 1 : 0)
            bindOptionalText(stmt, index: 24, value: clip.terminalSafetyWarning)
            bindText(stmt, index: 25, value: reasonsJSON)
            sqlite3_bind_int(stmt, 26, clip.userOverrodeCategory ? 1 : 0)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StorageError.statementFailed(lastErrorMessage())
            }

            // Record category assignments
            try updateCategoryAssignmentsInternal(for: clip)

            // Index in FTS5 ONLY for Level 0 normal items
            if clip.sensitivityLevel == .normal && !clip.isEphemeral {
                try indexClipInFTSInternal(clip)
            }
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

    private func indexClipInFTSInternal(_ clip: ClipItem) throws {
        let delSQL = "DELETE FROM clips_fts WHERE clip_id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(delStmt) }
            bindText(delStmt, index: 1, value: clip.id.uuidString)
            sqlite3_step(delStmt)
        }

        let insSQL = """
        INSERT INTO clips_fts (clip_id, searchable_text, category, language, source_app, hostname)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insSQL, -1, &insStmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(insStmt) }
            bindText(insStmt, index: 1, value: clip.id.uuidString)
            bindText(insStmt, index: 2, value: clip.content)
            bindText(insStmt, index: 3, value: clip.primaryCategory.displayName)
            bindText(insStmt, index: 4, value: clip.detectedLanguage?.rawValue ?? "")
            bindText(insStmt, index: 5, value: clip.sourceApplication ?? "")
            bindText(insStmt, index: 6, value: clip.urlHostname ?? "")
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

    // MARK: - Fetch & Search Clips

    public func fetchClips(
        query: String? = nil,
        category: ClipCategory? = nil,
        pinnedOnly: Bool = false,
        expiringOnly: Bool = false,
        limit: Int = 200
    ) throws -> [ClipItem] {
        try queue.sync {
            var conditions: [String] = []
            var bindings: [String] = []

            if let category = category {
                conditions.append("(c.primary_category = ? OR EXISTS (SELECT 1 FROM clip_category_assignments ca WHERE ca.clip_id = c.id AND ca.category_slug = ?))")
                bindings.append(category.rawValue)
                bindings.append(category.rawValue)
            }

            if pinnedOnly {
                conditions.append("(c.is_pinned = 1 OR c.is_favorite = 1)")
            }

            if expiringOnly {
                conditions.append("(c.expires_at IS NOT NULL AND c.is_pinned = 0)")
            }

            let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var sql = "SELECT c.* FROM clips c "

            if !trimmedQuery.isEmpty {
                let sanitizedFTS = sanitizeFTSQuery(trimmedQuery)
                if !sanitizedFTS.isEmpty {
                    sql += "JOIN clips_fts f ON f.clip_id = c.id "
                    conditions.append("clips_fts MATCH ?")
                    bindings.append(sanitizedFTS)
                }
            }

            if !conditions.isEmpty {
                sql += "WHERE " + conditions.joined(separator: " AND ") + " "
            }

            sql += "ORDER BY c.is_pinned DESC, c.created_at DESC LIMIT \(max(1, limit));"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StorageError.statementFailed(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, val) in bindings.enumerated() {
                bindText(stmt, index: Int32(i + 1), value: val)
            }

            var items: [ClipItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = decodeClipRow(stmt) {
                    items.append(item)
                }
            }

            // Fallback substring filter if FTS tokenization didn't match special characters (like #FF5733 or symbols)
            if !trimmedQuery.isEmpty && items.isEmpty {
                let allRecent = try fetchClips(query: nil, category: category, pinnedOnly: pinnedOnly, expiringOnly: expiringOnly, limit: limit)
                let lowerQ = trimmedQuery.lowercased()
                return allRecent.filter { clip in
                    clip.content.lowercased().contains(lowerQ) ||
                    clip.primaryCategory.displayName.lowercased().contains(lowerQ) ||
                    (clip.detectedLanguage?.rawValue.lowercased().contains(lowerQ) ?? false) ||
                    (clip.sourceApplication?.lowercased().contains(lowerQ) ?? false) ||
                    (clip.urlHostname?.lowercased().contains(lowerQ) ?? false)
                }
            }

            return items
        }
    }

    private func sanitizeFTSQuery(_ raw: String) -> String {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
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
        let urlHostname = columnText(stmt, 21)
        let isSuspicious = sqlite3_column_int(stmt, 22) != 0
        let terminalWarning = columnText(stmt, 23)
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
        queue.sync {
            let sql = "UPDATE clips SET primary_category = ?, user_overrode_category = 1, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: newCategory.rawValue)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bindText(stmt, index: 3, value: clipID.uuidString)
            sqlite3_step(stmt)
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

            var ftsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE clips_fts SET searchable_text = ? WHERE clip_id = ?;", -1, &ftsStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(ftsStmt) }
                bindText(ftsStmt, index: 1, value: newContent)
                bindText(ftsStmt, index: 2, value: clipID.uuidString)
                sqlite3_step(ftsStmt)
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
            let size = (try? FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? Int64) ?? 0
            return StorageStats(
                totalClips: total,
                pinnedClips: pinned,
                excludedEventsCount: excluded,
                databaseSizeBytes: size
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
