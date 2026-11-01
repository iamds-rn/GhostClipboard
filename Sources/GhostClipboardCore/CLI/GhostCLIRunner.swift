import Foundation

public enum GhostCLIRunner {
    public static let knownCLISubcommands: Set<String> = [
        "status", "recent", "search", "list",
        "enable-cli", "disable-cli", "backup-key",
        "help", "--help", "-h",
        "version", "--version", "-v"
    ]

    public static func shouldDispatchCLI(from processArguments: [String]) -> Bool {
        if let executableName = (processArguments.first as NSString?)?.lastPathComponent,
           executableName.lowercased() == "ghostclipboard-cli" || executableName == "ghostclipboard" {
            return true
        }
        guard processArguments.count > 1 else { return false }
        let arg = processArguments[1]
        return knownCLISubcommands.contains(arg)
    }

    public static func runAndExit(arguments: [String], storage: SQLiteStorageEngine? = nil) -> Never {
        let exitCode = run(arguments: arguments, storage: storage)
        fflush(stdout)
        fflush(stderr)
        Foundation.exit(exitCode)
    }

    public static func run(arguments: [String], storage: SQLiteStorageEngine? = nil) -> Int32 {
        let resolvedStorage: SQLiteStorageEngine
        do {
            resolvedStorage = try storage ?? SQLiteStorageEngine()
        } catch {
            fputs("Error opening GhostClipboard database: \(error.localizedDescription)\n", stderr)
            return 1
        }

        let prefs = resolvedStorage.loadPreferences()
        guard let subcommand = arguments.first else {
            printUsage()
            return 0
        }

        switch subcommand {
        case "--help", "-h", "help":
            printUsage()
            return 0

        case "--version", "-v", "version":
            print("ghostclipboard 1.1.0 (GhostClipboard Local Privacy Engine)")
            return 0

        case "status":
            let stats = resolvedStorage.fetchStorageStats()
            let ramMB = Double(RuntimeMemoryMonitor.currentResidentMemoryBytes()) / (1024.0 * 1024.0)
            print("GhostClipboard Status")
            print("─────────────────────")
            print("Monitoring:          \(prefs.monitoringPaused ? "Paused" : "Active")")
            print("Global Shortcut:     \(prefs.hotkeyDisplayString)")
            print("Direct Paste (⌘V):   \(prefs.directPasteToActiveApp ? "Enabled" : "Disabled (Copy-Only)")")
            print("CLI Access Enabled:  \(prefs.enableCLIAccess ? "Yes" : "No (Enable in Settings → Developer Tools or run 'ghostclipboard enable-cli')")")
            print("Encryption:          AES-256-GCM + HMAC-SHA256 Blind FTS Index (Zero Plaintext On Disk)")
            print("Persisted Clips:     \(stats.totalClips) (\(stats.pinnedClips) pinned)")
            print("Blocked Secrets:     \(stats.excludedEventsCount)")
            print("Database Size:       \(formatBytes(stats.databaseSizeBytes))")
            print("Resident Memory:     \(String(format: "%.1f MB", ramMB))")
            print("Database Path:       \(resolvedStorage.databasePath)")
            return 0

        case "backup-key":
            let ok = CryptoVault.shared.backupMasterKeyToKeychain()
            if ok {
                print("Master AES-256 vault key backed up to macOS Keychain.")
                return 0
            } else {
                print("Master AES-256 vault key is active at \(CryptoVault.localKeyFileURL().path) (0600).")
                return 0
            }

        case "enable-cli":
            var updated = prefs
            updated.enableCLIAccess = true
            do {
                try resolvedStorage.savePreferences(updated)
                print("CLI access enabled.")
                return 0
            } catch {
                fputs("Failed to enable CLI access: \(error.localizedDescription)\n", stderr)
                return 1
            }

        case "disable-cli":
            var updated = prefs
            updated.enableCLIAccess = false
            do {
                try resolvedStorage.savePreferences(updated)
                print("CLI access disabled.")
                return 0
            } catch {
                fputs("Failed to disable CLI access: \(error.localizedDescription)\n", stderr)
                return 1
            }

        case "recent":
            guard checkCLIGate(prefs) else { return 2 }
            let limit = parseIntOption(in: arguments, flag: "--limit") ?? 10
            let jsonOutput = arguments.contains("--json")
            do {
                let clips = try resolvedStorage.fetchClips(limit: limit)
                outputClips(clips, asJSON: jsonOutput)
                return 0
            } catch {
                fputs("Failed to fetch recent clips: \(error.localizedDescription)\n", stderr)
                return 1
            }

        case "search":
            guard checkCLIGate(prefs) else { return 2 }
            let positionals = positionalArguments(in: Array(arguments.dropFirst()), optionsWithValues: ["--limit"])
            guard let query = positionals.first, !query.isEmpty else {
                fputs("Usage: ghostclipboard search <query> [--limit N] [--json]\n", stderr)
                return 1
            }
            let limit = parseIntOption(in: arguments, flag: "--limit") ?? 50
            let jsonOutput = arguments.contains("--json")
            do {
                let clips = try resolvedStorage.fetchClips(query: query, limit: limit)
                outputClips(clips, asJSON: jsonOutput)
                return 0
            } catch {
                fputs("Search failed: \(error.localizedDescription)\n", stderr)
                return 1
            }

        case "list":
            guard checkCLIGate(prefs) else { return 2 }
            let categorySlug = parseStringOption(in: arguments, flag: "--category")?.lowercased()
            let category = categorySlug.flatMap { slug -> ClipCategory? in
                if let exact = ClipCategory(rawValue: slug) { return exact }
                switch slug {
                case "links", "link": return .url
                case "colors", "color", "hex": return .hexColor
                case "terminal", "shell", "cmd": return .terminalCommand
                case "text", "plain": return .plainText
                case "md": return .markdown
                default: return nil
                }
            }
            if categorySlug != nil && category == nil {
                fputs("Unknown category '\(categorySlug!)'. Valid categories: code, url, hex_color, markdown, json, terminal_command, plain_text\n", stderr)
                return 1
            }
            let limit = parseIntOption(in: arguments, flag: "--limit") ?? 100
            let jsonOutput = arguments.contains("--json")
            do {
                let clips = try resolvedStorage.fetchClips(category: category, limit: limit)
                outputClips(clips, asJSON: jsonOutput)
                return 0
            } catch {
                fputs("List failed: \(error.localizedDescription)\n", stderr)
                return 1
            }

        default:
            fputs("Unknown command '\(subcommand)'. Run 'ghostclipboard --help' for usage.\n", stderr)
            return 1
        }
    }

    private static func checkCLIGate(_ prefs: GhostPreferences) -> Bool {
        guard prefs.enableCLIAccess else {
            fputs("Error: CLI access is disabled by default for security.\nEnable it in GhostClipboard Settings → Developer Tools, or run 'ghostclipboard enable-cli'.\n", stderr)
            return false
        }
        guard !prefs.isAppLocked else {
            fputs("Error: GhostClipboard is currently locked. Unlock the application first.\n", stderr)
            return false
        }
        return true
    }

    private static func outputClips(_ clips: [ClipItem], asJSON: Bool) {
        // Section 12.2: Never expose protected/sensitive items unless unlocked; filter to Level 0 normal clips
        let safeClips = clips.filter { $0.sensitivityLevel == .normal && !$0.isEphemeral }

        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(safeClips),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if safeClips.isEmpty {
            print("No matching clips found.")
            return
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let now = Date()

        for (idx, clip) in safeClips.enumerated() {
            let rel = formatter.localizedString(for: clip.createdAt, relativeTo: now)
            let lang = clip.detectedLanguage.map { " (\($0.shortBadge))" } ?? ""
            let app = clip.sourceApplication.map { " • \($0)" } ?? ""
            let pin = clip.isPinned ? " [PINNED]" : ""
            print("[\(idx + 1)] [\(clip.primaryCategory.shortLabel)\(lang)]\(pin) \(rel)\(app)")
            print("    \(clip.contentPreview)")
        }
    }

    private static func positionalArguments(in args: [String], optionsWithValues: Set<String>) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            if optionsWithValues.contains(token) {
                i += 2
                continue
            }
            if token.hasPrefix("-") {
                i += 1
                continue
            }
            result.append(token)
            i += 1
        }
        return result
    }

    private static func parseStringOption(in args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func parseIntOption(in args: [String], flag: String) -> Int? {
        guard let val = parseStringOption(in: args, flag: flag) else { return nil }
        return Int(val)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    public static func printUsage() {
        print("""
        GhostClipboard CLI — Your clipboard remembers. Your secrets disappear.

        USAGE:
          ghostclipboard <subcommand> [options]

        SUBCOMMANDS:
          status                      Show monitoring, encryption, and database status
          recent [--limit N] [--json] Show recent normal clipboard items
          search <query> [--json]     Full-text search across clipboard history
          list --category <cat>       List clips by category (code, url, hex_color, markdown, json, terminal_command, plain_text)
          enable-cli                  Enable CLI access gate in preferences
          disable-cli                 Disable CLI access gate in preferences
          help                        Show this help message
        """)
    }
}
