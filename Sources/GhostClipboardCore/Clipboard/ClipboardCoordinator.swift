import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
public final class ClipboardCoordinator: ObservableObject {

    // MARK: - Published State for UI

    @Published public private(set) var persistentClips: [ClipItem] = []
    @Published public private(set) var ephemeralClips: [ClipItem] = []
    @Published public private(set) var excludedEvents: [ExcludedCaptureEvent] = []
    @Published public private(set) var applicationExclusions: [ApplicationExclusion] = []
    @Published public var preferences: GhostPreferences {
        didSet {
            handlePreferencesChange(from: oldValue, to: preferences)
        }
    }
    @Published public var searchQuery: String = ""
    @Published public var selectedCategoryFilter: ClipCategory? = nil
    @Published public var lastStatusBanner: String? = nil

    // MARK: - Engines

    public let storage: SQLiteStorageEngine
    public let classifier = ContentClassificationEngine()
    public let securityEngine = SensitiveContentEngine()
    public let actionsEngine = DeveloperActionsEngine()

    private var pasteboardTimer: Timer?
    private var expirationTimer: Timer?
    private var lastChangeCount: Int = 0
    private var internalWriteChangeCount: Int? = nil
    private var lastPreferencesUpdatedAt: TimeInterval = 0
    private var isInternalPreferencesMutation: Bool = false

    public init(storage: SQLiteStorageEngine? = nil) {
        let resolvedStorage = (try? (storage ?? SQLiteStorageEngine())) ?? {
            let fallbackURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghost_fallback.sqlite3")
            return try! SQLiteStorageEngine(databaseURL: fallbackURL)
        }()
        self.storage = resolvedStorage
        let loaded = resolvedStorage.loadPreferencesWithTimestamp()
        self.preferences = loaded.preferences
        self.lastPreferencesUpdatedAt = loaded.updatedAt
        reloadAllData()
    }

    // MARK: - Reactive Preferences Side-Effects & Multi-Process Sync

    private func handlePreferencesChange(from oldValue: GhostPreferences, to newValue: GhostPreferences) {
        guard !isInternalPreferencesMutation, oldValue != newValue else { return }

        // Couple neverSaveOTPs and allowEphemeralOTP when only one was toggled in UI
        var adjusted = newValue
        if oldValue.neverSaveOTPs != newValue.neverSaveOTPs && oldValue.allowEphemeralOTP == newValue.allowEphemeralOTP {
            adjusted.allowEphemeralOTP = !newValue.neverSaveOTPs
        } else if oldValue.allowEphemeralOTP != newValue.allowEphemeralOTP && oldValue.neverSaveOTPs == newValue.neverSaveOTPs {
            adjusted.neverSaveOTPs = !newValue.allowEphemeralOTP
        }

        // Sync capture toggles with disabledCategories so Capture tab and Categories tab stay in lockstep
        if oldValue.capturePlainText != adjusted.capturePlainText {
            if adjusted.capturePlainText { adjusted.disabledCategories.removeAll { $0 == .plainText } }
            else if !adjusted.disabledCategories.contains(.plainText) { adjusted.disabledCategories.append(.plainText) }
        }
        if oldValue.captureRichText != adjusted.captureRichText {
            if adjusted.captureRichText { adjusted.disabledCategories.removeAll { $0 == .markdown } }
            else if !adjusted.disabledCategories.contains(.markdown) { adjusted.disabledCategories.append(.markdown) }
        }
        if oldValue.captureURLs != adjusted.captureURLs {
            if adjusted.captureURLs { adjusted.disabledCategories.removeAll { $0 == .url } }
            else if !adjusted.disabledCategories.contains(.url) { adjusted.disabledCategories.append(.url) }
        }
        if oldValue.captureCode != adjusted.captureCode {
            if adjusted.captureCode {
                adjusted.disabledCategories.removeAll { $0 == .code || $0 == .terminalCommand }
            } else {
                if !adjusted.disabledCategories.contains(.code) { adjusted.disabledCategories.append(.code) }
                if !adjusted.disabledCategories.contains(.terminalCommand) { adjusted.disabledCategories.append(.terminalCommand) }
            }
        }

        if adjusted != newValue {
            isInternalPreferencesMutation = true
            self.preferences = adjusted
            isInternalPreferencesMutation = false
        }

        if let ts = try? storage.savePreferences(adjusted) {
            lastPreferencesUpdatedAt = ts
        }

        if oldValue.monitoringPaused != adjusted.monitoringPaused {
            lastChangeCount = NSPasteboard.general.changeCount
            lastStatusBanner = adjusted.monitoringPaused ? "Clipboard monitoring paused" : "Clipboard monitoring active"
        } else if oldValue.launchAtLogin != adjusted.launchAtLogin {
            applyLaunchAtLogin(adjusted.launchAtLogin)
        } else if oldValue.showMenuBarIcon != adjusted.showMenuBarIcon {
            lastStatusBanner = adjusted.showMenuBarIcon ? "Menu bar icon shown" : "Menu bar icon hidden"
        } else if oldValue.themeMode != adjusted.themeMode {
            lastStatusBanner = "Appearance theme set to \(adjusted.themeMode.capitalized)"
        } else if oldValue.standardRetentionDays != adjusted.standardRetentionDays {
            try? storage.updateStandardRetentionDays(adjusted.standardRetentionDays)
            runRetentionCycle()
            reloadClips()
            lastStatusBanner = "Retention period updated to \(adjusted.standardRetentionDays) days"
        } else if oldValue.secretExpirationDurationSeconds != adjusted.secretExpirationDurationSeconds {
            let newDuration = adjusted.secretExpirationDurationSeconds
            for idx in ephemeralClips.indices {
                ephemeralClips[idx].expiresAt = ephemeralClips[idx].createdAt.addingTimeInterval(newDuration)
            }
            runRetentionCycle()
            lastStatusBanner = "Ephemeral secret timer set to \(Int(newDuration))s"
        } else if oldValue.neverSaveOTPs != adjusted.neverSaveOTPs || oldValue.allowEphemeralOTP != adjusted.allowEphemeralOTP {
            if adjusted.neverSaveOTPs && !adjusted.allowEphemeralOTP {
                ephemeralClips.removeAll { $0.primaryCategory == .otp }
                lastStatusBanner = "OTP codes set to block immediately"
            } else {
                lastStatusBanner = "OTP codes set to ephemeral memory (\(Int(adjusted.secretExpirationDurationSeconds))s)"
            }
        } else if oldValue.neverSaveAPIKeys != adjusted.neverSaveAPIKeys {
            if adjusted.neverSaveAPIKeys {
                ephemeralClips.removeAll { $0.primaryCategory == .credential }
                lastStatusBanner = "API keys & tokens set to block immediately"
            } else {
                lastStatusBanner = "API keys & tokens set to ephemeral memory"
            }
        } else if oldValue.neverSavePasswords != adjusted.neverSavePasswords {
            if adjusted.neverSavePasswords {
                ephemeralClips.removeAll { $0.primaryCategory == .credential }
                lastStatusBanner = "Passwords & concealed items set to block immediately"
            } else {
                lastStatusBanner = "Passwords set to ephemeral memory"
            }
        } else if oldValue.quarantinePotentiallySensitive != adjusted.quarantinePotentiallySensitive {
            lastStatusBanner = adjusted.quarantinePotentiallySensitive ? "High-entropy token quarantine enabled" : "High-entropy token quarantine disabled"
        } else if oldValue.requireAuthenticationToReveal != adjusted.requireAuthenticationToReveal {
            lastStatusBanner = adjusted.requireAuthenticationToReveal ? "Authentication required to reveal secrets" : "Direct reveal enabled for masked items"
        } else if oldValue.enableCLIAccess != adjusted.enableCLIAccess {
            lastStatusBanner = adjusted.enableCLIAccess ? "CLI access enabled" : "CLI access disabled"
        } else if oldValue.syntaxHighlightingEnabled != adjusted.syntaxHighlightingEnabled {
            lastStatusBanner = adjusted.syntaxHighlightingEnabled ? "Syntax highlighting enabled" : "Syntax highlighting disabled"
        } else if oldValue.autoFormatJSONPreview != adjusted.autoFormatJSONPreview {
            lastStatusBanner = adjusted.autoFormatJSONPreview ? "Auto-format JSON preview enabled" : "Auto-format JSON preview disabled"
        } else if oldValue.capturePlainText != adjusted.capturePlainText ||
                  oldValue.captureRichText != adjusted.captureRichText ||
                  oldValue.captureURLs != adjusted.captureURLs ||
                  oldValue.captureCode != adjusted.captureCode ||
                  oldValue.disabledCategories != adjusted.disabledCategories ||
                  oldValue.ignoreDuplicates != adjusted.ignoreDuplicates ||
                  oldValue.maxItemSizeBytes != adjusted.maxItemSizeBytes {
            lastStatusBanner = "Clipboard capture rules updated"
        }
    }

    public func syncExternalPreferencesIfNeeded() {
        let loaded = storage.loadPreferencesWithTimestamp()
        if loaded.updatedAt > lastPreferencesUpdatedAt + 0.0001 {
            lastPreferencesUpdatedAt = loaded.updatedAt
            if loaded.preferences != preferences {
                isInternalPreferencesMutation = true
                preferences = loaded.preferences
                isInternalPreferencesMutation = false
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if Bundle.main.bundlePath.hasSuffix(".app") {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // SMAppService may require signed bundle in /Applications; fall back to LaunchAgent plist
                updateLaunchAgentPlist(enabled: enabled)
            }
        }
        lastStatusBanner = enabled ? "Launch at login enabled" : "Launch at login disabled"
    }

    private func updateLaunchAgentPlist(enabled: Bool) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDir.appendingPathComponent("com.ghostclipboard.macos.plist", isDirectory: false)
        if enabled {
            guard let execPath = Bundle.main.executablePath else { return }
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.ghostclipboard.macos</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    // MARK: - Monitoring Lifecycle

    public func startMonitoring(pollInterval: TimeInterval = 0.45) {
        lastChangeCount = NSPasteboard.general.changeCount

        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboardIfNeeded()
            }
        }

        expirationTimer?.invalidate()
        expirationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runRetentionCycle()
            }
        }
    }

    public func stopMonitoring() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
    }

    // MARK: - Pasteboard Inspection (Section 4.1 Steps 1-4)

    public func checkPasteboardIfNeeded() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard !preferences.monitoringPaused else {
            lastChangeCount = currentCount
            return
        }
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Ignore self-initiated clipboard writes
        if let internalCount = internalWriteChangeCount, internalCount == currentCount {
            return
        }

        guard let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let types = (pb.types ?? []).map { $0.rawValue }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let metadata = PasteboardMetadata(
            types: types,
            sourceBundleID: frontApp?.bundleIdentifier,
            sourceAppName: frontApp?.localizedName,
            isTransient: types.contains(PasteboardMetadata.transientType),
            isConcealed: types.contains(PasteboardMetadata.concealedType),
            isAutoGenerated: types.contains(PasteboardMetadata.autoGeneratedType),
            hasPasswordManagerMarker: !Set(types).isDisjoint(with: PasteboardMetadata.knownPasswordManagerTypes)
        )

        _ = ingestClipboardContent(text, metadata: metadata)
    }

    // MARK: - Core Ingestion Pipeline (COPY -> DETECT -> CLASSIFY -> PROTECT -> PERSIST/EXPIRE)

    @discardableResult
    public func ingestClipboardContent(
        _ content: String,
        metadata: PasteboardMetadata = PasteboardMetadata(),
        now: Date = Date()
    ) -> RetentionDisposition {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .discardImmediately }

        // Check max size limit
        if content.utf8.count > preferences.maxItemSizeBytes {
            lastStatusBanner = "Skipped capture: item exceeds maximum size limit"
            return .discardImmediately
        }

        let activeExcludedBundles: Set<String>
        if applicationExclusions.isEmpty {
            activeExcludedBundles = PasteboardMetadata.defaultExcludedBundleIDs
        } else {
            activeExcludedBundles = Set(
                applicationExclusions
                    .filter { $0.isEnabled }
                    .map { $0.bundleIdentifier }
            )
        }

        // STEP 1: Security Evaluation BEFORE any storage or classification persistence
        let securityEval = securityEngine.evaluate(
            content: content,
            metadata: metadata,
            preferences: preferences,
            excludedBundleIDs: activeExcludedBundles
        )

        // STEP 2: Handle Discard Immediately (Level 2 Secrets, Excluded Apps, Concealed Passwords)
        if securityEval.disposition == .discardImmediately {
            let event = ExcludedCaptureEvent(
                timestamp: now,
                reason: securityEval.detectionReasons.first ?? "Blocked by Sensitive Content Engine",
                secretType: securityEval.detectedSecretType ?? "Protected Secret",
                sourceApplication: metadata.sourceAppName ?? metadata.sourceBundleID,
                sensitivityLevel: securityEval.sensitivityLevel
            )
            try? storage.recordExcludedEvent(event)
            excludedEvents = (try? storage.fetchExcludedEvents()) ?? excludedEvents
            lastStatusBanner = "Protected: \(event.secretType) excluded from history"
            return .discardImmediately
        }

        // STEP 3: Classify Content
        let classification = classifier.classify(
            content: content,
            metadata: metadata,
            securityEvaluation: securityEval
        )

        // Respect category capture toggles
        if !preferences.isCategoryCaptureEnabled(classification.primaryCategory) {
            lastStatusBanner = "Skipped capture: \(classification.primaryCategory.displayName) capture is disabled"
            return .discardImmediately
        }

        let hash = CryptoVault.sha256Hex(trimmed)

        // STEP 4: Ephemeral Memory-Only Handling (Level 1 Quarantined or Level 3 Ephemeral OTP/Secret)
        if securityEval.disposition == .memoryOnlyEphemeral {
            let expDuration = securityEval.expirationSeconds ?? preferences.secretExpirationDurationSeconds
            let ephemeralItem = ClipItem(
                content: content,
                contentHash: hash,
                primaryCategory: classification.primaryCategory,
                secondaryCategories: classification.secondaryCategories,
                detectedLanguage: classification.detectedLanguage,
                sourceApplication: metadata.sourceAppName,
                sourceBundleID: metadata.sourceBundleID,
                sensitivityLevel: securityEval.sensitivityLevel,
                isPinned: false,
                isFavorite: false,
                isEphemeral: true,
                createdAt: now,
                updatedAt: now,
                lastUsedAt: now,
                expiresAt: now.addingTimeInterval(expDuration),
                colorComponents: classification.colorComponents,
                urlHostname: classification.urlHostname,
                isSuspiciousDomain: classification.isSuspiciousDomain,
                terminalSafetyWarning: classification.terminalSafetyWarning,
                detectionReasons: securityEval.detectionReasons
            )

            ephemeralClips.removeAll { $0.contentHash == hash }
            ephemeralClips.insert(ephemeralItem, at: 0)
            lastStatusBanner = "Ephemeral item captured (auto-expires in \(Int(expDuration))s)"
            return .memoryOnlyEphemeral
        }

        // STEP 5: Standard Encrypted SQLite Persistence (Level 0 Normal Content)
        let expDate = now.addingTimeInterval(TimeInterval(preferences.standardRetentionDays * 86_400))
        let clip = ClipItem(
            content: content,
            contentHash: hash,
            primaryCategory: classification.primaryCategory,
            secondaryCategories: classification.secondaryCategories,
            detectedLanguage: classification.detectedLanguage,
            sourceApplication: metadata.sourceAppName,
            sourceBundleID: metadata.sourceBundleID,
            sensitivityLevel: .normal,
            isPinned: false,
            isFavorite: false,
            isEphemeral: false,
            createdAt: now,
            updatedAt: now,
            lastUsedAt: now,
            expiresAt: expDate,
            colorComponents: classification.colorComponents,
            urlHostname: classification.urlHostname,
            isSuspiciousDomain: classification.isSuspiciousDomain,
            terminalSafetyWarning: classification.terminalSafetyWarning,
            detectionReasons: []
        )

        try? storage.saveClip(clip, ignoreDuplicates: preferences.ignoreDuplicates)
        reloadClips()
        return .persistStandard
    }

    // MARK: - Retention & Expiration Engine (Section 4.1 Step 7 & Section 6.3)

    public func runRetentionCycle(now: Date = Date()) {
        syncExternalPreferencesIfNeeded()

        // 1. Purge expired in-memory ephemeral items immediately
        let beforeCount = ephemeralClips.count
        ephemeralClips.removeAll { $0.isExpired(at: now) }
        let removedEphemeral = beforeCount - ephemeralClips.count

        // 2. Purge expired persistent items from SQLite
        let removedDB = (try? storage.purgeExpiredClips(now: now)) ?? 0

        if removedEphemeral > 0 || removedDB > 0 {
            reloadClips()
        }
    }

    @discardableResult
    public func purgeExpiredClipsNow(now: Date = Date()) -> Int {
        let beforeCount = ephemeralClips.count
        ephemeralClips.removeAll { $0.isExpired(at: now) }
        let removedEphemeral = beforeCount - ephemeralClips.count
        let removedDB = (try? storage.purgeExpiredClips(now: now)) ?? 0
        let total = removedEphemeral + removedDB
        reloadAllData()
        lastStatusBanner = total > 0 ? "Purged \(total) expired clip(s)" : "No expired clips to purge (0 removed)"
        objectWillChange.send()
        return total
    }

    // MARK: - Querying & Filtering for Palette and Full Window

    public var allVisibleClips: [ClipItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Filter ephemeral clips
        let filteredEphemeral = ephemeralClips.filter { clip in
            if let cat = selectedCategoryFilter, clip.primaryCategory != cat && !clip.secondaryCategories.contains(cat) {
                return false
            }
            if !query.isEmpty {
                // Ephemeral secrets are not indexed by content if Level 3, only match category/source app
                return clip.primaryCategory.displayName.lowercased().contains(query) ||
                       (clip.sourceApplication?.lowercased().contains(query) ?? false)
            }
            return true
        }

        return filteredEphemeral + persistentClips
    }

    public func reloadAllData() {
        reloadClips()
        excludedEvents = (try? storage.fetchExcludedEvents()) ?? []
        applicationExclusions = (try? storage.fetchApplicationExclusions()) ?? []
    }

    public func reloadClips() {
        persistentClips = (try? storage.fetchClips(
            query: searchQuery,
            category: selectedCategoryFilter,
            limit: 250
        )) ?? []
    }

    // MARK: - User Actions (Copy, Paste, Pin, Delete, Clear)

    public func copyToSystemClipboard(_ text: String, markClipID: UUID? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        internalWriteChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount

        if let id = markClipID {
            try? storage.markClipUsed(clipID: id)
            reloadClips()
        }
        lastStatusBanner = "Copied to clipboard"
    }

    public func clearSystemClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        internalWriteChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        lastStatusBanner = "System clipboard cleared"
    }

    public func togglePin(_ clip: ClipItem) {
        guard !clip.isEphemeral else { return }
        let newPin = !clip.isPinned
        try? storage.togglePin(clipID: clip.id, isPinned: newPin)
        reloadClips()
        lastStatusBanner = newPin ? "Clip pinned" : "Clip unpinned"
    }

    public func overrideCategory(_ clip: ClipItem, to category: ClipCategory) {
        if clip.isEphemeral {
            if let idx = ephemeralClips.firstIndex(where: { $0.id == clip.id }) {
                ephemeralClips[idx].primaryCategory = category
                ephemeralClips[idx].userOverrodeCategory = true
            }
        } else {
            try? storage.overrideCategory(clipID: clip.id, newCategory: category)
            reloadClips()
        }
        lastStatusBanner = "Reclassified clip as \(category.displayName)"
    }

    public func updateClipContent(_ clip: ClipItem, newContent: String) {
        if clip.isEphemeral {
            if let idx = ephemeralClips.firstIndex(where: { $0.id == clip.id }) {
                ephemeralClips[idx].content = newContent
                let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                ephemeralClips[idx].contentPreview = String(trimmed.prefix(240)).replacingOccurrences(of: "\n", with: " ↵ ")
            }
        } else {
            try? storage.updateClipContent(clipID: clip.id, newContent: newContent)
            reloadClips()
        }
        lastStatusBanner = "Updated clip content"
    }

    public func deleteClip(_ clip: ClipItem) {
        if clip.isEphemeral {
            ephemeralClips.removeAll { $0.id == clip.id }
        } else {
            try? storage.deleteClip(clipID: clip.id)
            reloadClips()
        }
        lastStatusBanner = "Deleted clip"
    }

    public func clearAllHistory(keepPinned: Bool = false) {
        ephemeralClips.removeAll()
        try? storage.clearAllHistory(keepPinned: keepPinned)
        reloadAllData()
        lastStatusBanner = keepPinned ? "Cleared unpinned history" : "All clipboard history & logs purged"
        objectWillChange.send()
    }

    public func addApplicationExclusion(bundleID: String, appName: String) {
        let rule = ApplicationExclusion(bundleIdentifier: bundleID, applicationName: appName, isEnabled: true)
        try? storage.saveApplicationExclusion(rule)
        applicationExclusions = (try? storage.fetchApplicationExclusions()) ?? []
        lastStatusBanner = "Added exclusion for \(appName)"
    }

    public func toggleApplicationExclusion(_ exclusion: ApplicationExclusion) {
        setApplicationExclusion(exclusion, isEnabled: !exclusion.isEnabled)
    }

    public func setApplicationExclusion(_ exclusion: ApplicationExclusion, isEnabled: Bool) {
        var updated = exclusion
        updated.isEnabled = isEnabled
        try? storage.saveApplicationExclusion(updated)
        applicationExclusions = (try? storage.fetchApplicationExclusions()) ?? []
        lastStatusBanner = isEnabled ? "Enabled exclusion for \(exclusion.applicationName)" : "Disabled exclusion for \(exclusion.applicationName)"
    }

    public func removeApplicationExclusion(_ exclusion: ApplicationExclusion) {
        try? storage.deleteApplicationExclusion(id: exclusion.id)
        applicationExclusions = (try? storage.fetchApplicationExclusions()) ?? []
        lastStatusBanner = "Removed exclusion for \(exclusion.applicationName)"
    }

    public func setCategoryCaptureEnabled(_ category: ClipCategory, enabled: Bool) {
        var updated = preferences
        updated.setCategoryCaptureEnabled(category, enabled: enabled)
        preferences = updated
        lastStatusBanner = enabled ? "Enabled \(category.displayName) capture" : "Disabled \(category.displayName) capture"
    }

    // MARK: - Seed Representative Developer Clips for First Launch / Demo

    public func seedSampleDeveloperClipsIfEmpty() {
        let stats = storage.fetchStorageStats()
        guard stats.totalClips == 0 else { return }

        let now = Date()
        let samples: [(String, String, String, TimeInterval)] = [
            (
                """
                export interface ClipboardRetentionPolicy {
                  readonly sensitivityLevel: 0 | 1 | 2 | 3;
                  readonly ttlSeconds: number | null;
                  readonly encryptedAtRest: boolean;
                }

                export function evaluatePolicy(level: ClipboardRetentionPolicy['sensitivityLevel']): ClipboardRetentionPolicy {
                  switch (level) {
                    case 0: return { sensitivityLevel: 0, ttlSeconds: 2592000, encryptedAtRest: true };
                    case 3: return { sensitivityLevel: 3, ttlSeconds: 120, encryptedAtRest: false };
                    default: return { sensitivityLevel: level, ttlSeconds: 0, encryptedAtRest: false };
                  }
                }
                """,
                "com.microsoft.VSCode",
                "Visual Studio Code",
                -180
            ),
            (
                """
                {
                  "service": "ghostclipboard-engine",
                  "version": "1.0.0",
                  "localProcessingOnly": true,
                  "encryption": {
                    "algorithm": "AES-256-GCM",
                    "keyStore": "AppleKeychain"
                  },
                  "excludedPasteboardTypes": [
                    "org.nspasteboard.ConcealedType",
                    "org.nspasteboard.TransientType"
                  ]
                }
                """,
                "com.apple.dt.Xcode",
                "Xcode",
                -420
            ),
            (
                "https://developer.apple.com/documentation/appkit/nspasteboard?utm_source=newsletter&utm_medium=email&fbclid=IwAR123456",
                "com.apple.Safari",
                "Safari",
                -900
            ),
            (
                "#A6B7FF",
                "com.figma.Desktop",
                "Figma",
                -1500
            ),
            (
                "docker compose -f docker-compose.prod.yml up -d --build && docker logs -f api-gateway",
                "com.googlecode.iterm2",
                "iTerm2",
                -2400
            ),
            (
                """
                ### Release Readiness Checklist
                - [x] Pre-persistence `SensitiveContentEngine` gate verified
                - [x] AES-256-GCM payload encryption enabled on `clips` table
                - [x] Ephemeral 120-second memory-only countdown timer tested
                - [ ] Finalize [CLI documentation](https://docs.ghostclipboard.dev/cli)
                """,
                "md.obsidian",
                "Obsidian",
                -3600
            )
        ]

        for (content, bundle, appName, offset) in samples {
            let meta = PasteboardMetadata(sourceBundleID: bundle, sourceAppName: appName)
            _ = ingestClipboardContent(content, metadata: meta, now: now.addingTimeInterval(offset))
        }

        // Also record one sample excluded event so the user can immediately inspect how GhostClipboard blocks secrets
        let sampleBlocked = ExcludedCaptureEvent(
            timestamp: now.addingTimeInterval(-60),
            reason: "Matches OpenAI secret key prefix (sk-)",
            secretType: "OpenAI API Key",
            sourceApplication: "iTerm2",
            sensitivityLevel: .sensitive
        )
        try? storage.recordExcludedEvent(sampleBlocked)
        reloadAllData()
    }
}
