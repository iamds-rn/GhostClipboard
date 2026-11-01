import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
public final class ClipboardCoordinator: ObservableObject {

    // MARK: - Published State for UI

    @Published public private(set) var persistentClips: [ClipItem] = []
    @Published public private(set) var ephemeralClips: [ClipItem] = [] {
        didSet {
            updateEphemeralTimerLifecycle()
        }
    }
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
    @Published public private(set) var lastExternalApplication: NSRunningApplication? = nil
    @Published public private(set) var isSleepingOrScreenLocked: Bool = false
    @Published public private(set) var isBackgroundCoalesced: Bool = false

    // MARK: - Engines

    public let storage: SQLiteStorageEngine
    public let classifier = ContentClassificationEngine()
    public let securityEngine = SensitiveContentEngine()
    public let actionsEngine = DeveloperActionsEngine()

    // MARK: - Low-Power Coalesced Timers & Memory Pressure Source

    private var pasteboardTimer: DispatchSourceTimer?
    private var ephemeralCountdownTimer: DispatchSourceTimer?
    private var dbMaintenanceTimer: DispatchSourceTimer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    private var currentPollInterval: TimeInterval = 0.45
    private var isMonitoringRequested: Bool = false
    private var lastChangeCount: Int = 0
    private var internalWriteChangeCount: Int? = nil
    private var lastPreferencesUpdatedAt: TimeInterval = 0
    private var isInternalPreferencesMutation: Bool = false

    public var onMemoryPressureTrim: (() -> Void)? = nil

    /// True ONLY when `ephemeralClips` is non-empty and the 1.0s countdown timer is actively ticking.
    /// Zero idle wakeups occur when `ephemeralClips` is empty!
    public var isEphemeralTimerActive: Bool {
        ephemeralCountdownTimer != nil
    }

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
        setupMemoryPressureHandling()
        setupWorkspaceAndSleepWakeObservers()
        captureFrontmostExternalApplication()
    }

    deinit {
        pasteboardTimer?.cancel()
        ephemeralCountdownTimer?.cancel()
        dbMaintenanceTimer?.cancel()
        memoryPressureSource?.cancel()
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        for obs in appObservers {
            NotificationCenter.default.removeObserver(obs)
        }
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

        // Ensure hotkeyDisplayString stays synchronized with hotkeyKeyCode + hotkeyModifiers
        let expectedDisplay = ShortcutFormatter.displayString(keyCode: adjusted.hotkeyKeyCode, carbonModifiers: adjusted.hotkeyModifiers)
        if adjusted.hotkeyDisplayString != expectedDisplay {
            adjusted.hotkeyDisplayString = expectedDisplay
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
        } else if oldValue.hotkeyKeyCode != adjusted.hotkeyKeyCode || oldValue.hotkeyModifiers != adjusted.hotkeyModifiers {
            lastStatusBanner = "Global shortcut updated to \(adjusted.hotkeyDisplayString)"
        } else if oldValue.directPasteToActiveApp != adjusted.directPasteToActiveApp {
            lastStatusBanner = adjusted.directPasteToActiveApp ? "Direct paste into active app enabled" : "Direct paste disabled (Copy only)"
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

    // MARK: - Active External Application Tracking (For Direct Paste Synthesis)

    public func captureFrontmostExternalApplication() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let myBundleID = Bundle.main.bundleIdentifier ?? "com.ghostclipboard.macos"
        let frontBundle = front.bundleIdentifier ?? ""
        let frontName = front.localizedName ?? ""
        if frontBundle != myBundleID && frontName != "GhostClipboard" && front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = front
        }
    }

    // MARK: - Sleep/Wake & App Activation Observers + Memory Pressure Handling

    private func setupWorkspaceAndSleepWakeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter

        let activateObs = wsCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.ghostclipboard.macos"
                if app.bundleIdentifier != myBundleID &&
                   app.localizedName != "GhostClipboard" &&
                   app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.lastExternalApplication = app
                }
            }
        }

        let willSleepObs = wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }

        let screensSleepObs = wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }

        let didWakeObs = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake()
            }
        }

        let screensWakeObs = wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake()
            }
        }

        workspaceObservers = [activateObs, willSleepObs, screensSleepObs, didWakeObs, screensWakeObs]

        let appActiveObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isBackgroundCoalesced = false
                if self.isMonitoringRequested && !self.isSleepingOrScreenLocked {
                    self.configurePasteboardDispatchTimer(interval: self.currentPollInterval, leewayMs: 150)
                }
            }
        }

        let appResignObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isBackgroundCoalesced = true
                if self.isMonitoringRequested && !self.isSleepingOrScreenLocked {
                    self.configurePasteboardDispatchTimer(interval: max(self.currentPollInterval, 0.55), leewayMs: 400)
                }
            }
        }

        appObservers = [appActiveObs, appResignObs]
    }

    public func handleSystemWillSleep() {
        isSleepingOrScreenLocked = true
        pasteboardTimer?.cancel()
        pasteboardTimer = nil
        dbMaintenanceTimer?.cancel()
        dbMaintenanceTimer = nil
    }

    public func handleSystemDidWake() {
        isSleepingOrScreenLocked = false
        runRetentionCycle()
        if isMonitoringRequested {
            let leeway = isBackgroundCoalesced ? 400 : 150
            configurePasteboardDispatchTimer(interval: currentPollInterval, leewayMs: leeway)
            configureLowFrequencyDBMaintenanceTimer()
        }
    }

    private func setupMemoryPressureHandling() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.trimMemoryAndCachesNow()
            }
        }
        source.resume()
        self.memoryPressureSource = source
    }

    public func trimMemoryAndCachesNow() {
        BoundedContentCache.shared.evictAll()
        onMemoryPressureTrim?()
        storage.releaseMemory()
        if persistentClips.count > 50 {
            persistentClips = Array(persistentClips.prefix(50))
        }
        lastStatusBanner = "Trimmed caches & released idle SQLite memory"
    }

    public func runtimeEfficiencySnapshot() -> RuntimeEfficiencySnapshot {
        let stats = storage.fetchStorageStats()
        let regexStats = RegexCache.shared.stats
        let classStats = BoundedContentCache.shared.stats
        return RuntimeEfficiencySnapshot(
            residentMemoryBytes: RuntimeMemoryMonitor.currentResidentMemoryBytes(),
            databaseSizeBytes: stats.databaseSizeBytes,
            isEphemeralTimerActive: isEphemeralTimerActive,
            ephemeralClipCount: ephemeralClips.count,
            isPasteboardPollingPaused: preferences.monitoringPaused || isSleepingOrScreenLocked || pasteboardTimer == nil,
            isBackgroundCoalesced: isBackgroundCoalesced,
            regexCacheHits: regexStats.hits,
            regexCacheMisses: regexStats.misses,
            cachedRegexCount: regexStats.count,
            classificationCacheHits: classStats.hits
        )
    }

    // MARK: - Monitoring & Zero-Idle-Wake Timer Lifecycle

    public func startMonitoring(pollInterval: TimeInterval = 0.45) {
        currentPollInterval = pollInterval
        isMonitoringRequested = true
        lastChangeCount = NSPasteboard.general.changeCount

        configurePasteboardDispatchTimer(interval: pollInterval, leewayMs: isBackgroundCoalesced ? 400 : 150)
        configureLowFrequencyDBMaintenanceTimer()
        updateEphemeralTimerLifecycle()
    }

    public func stopMonitoring() {
        isMonitoringRequested = false
        pasteboardTimer?.cancel()
        pasteboardTimer = nil
        ephemeralCountdownTimer?.cancel()
        ephemeralCountdownTimer = nil
        dbMaintenanceTimer?.cancel()
        dbMaintenanceTimer = nil
    }

    private func configurePasteboardDispatchTimer(interval: TimeInterval, leewayMs: Int) {
        pasteboardTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(leewayMs)
        )
        timer.setEventHandler { [weak self] in
            self?.checkPasteboardIfNeeded()
        }
        timer.resume()
        pasteboardTimer = timer
    }

    private func configureLowFrequencyDBMaintenanceTimer() {
        dbMaintenanceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Low-frequency 10-minute timer with 60s kernel coalescing leeway for 30-day DB retention checks
        timer.schedule(
            deadline: .now() + 600,
            repeating: 600,
            leeway: .seconds(60)
        )
        timer.setEventHandler { [weak self] in
            self?.runRetentionCycle()
        }
        timer.resume()
        dbMaintenanceTimer = timer
    }

    /// Starts the 1.0s countdown timer ONLY when `ephemeralClips` is non-empty,
    /// and immediately cancels it the instant `ephemeralClips` becomes empty!
    private func updateEphemeralTimerLifecycle() {
        if ephemeralClips.isEmpty {
            if ephemeralCountdownTimer != nil {
                ephemeralCountdownTimer?.cancel()
                ephemeralCountdownTimer = nil
            }
        } else {
            if ephemeralCountdownTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
                timer.setEventHandler { [weak self] in
                    self?.tickEphemeralCountdown()
                }
                timer.resume()
                ephemeralCountdownTimer = timer
            }
        }
    }

    private func tickEphemeralCountdown(now: Date = Date()) {
        guard !ephemeralClips.isEmpty else {
            updateEphemeralTimerLifecycle()
            return
        }
        ephemeralClips.removeAll { $0.isExpired(at: now) }
    }

    // MARK: - Pasteboard Inspection (Section 4.1 Steps 1-4)

    public func checkPasteboardIfNeeded() {
        // Ultra-fast changeCount check with zero allocations when idle
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard !preferences.monitoringPaused else { return }

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

            var updated = ephemeralClips.filter { $0.contentHash != hash }
            updated.insert(ephemeralItem, at: 0)
            ephemeralClips = updated
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

    // MARK: - User Actions (Copy, Direct Paste, UUID Generator, Paste Stack, Pin, Delete, Clear)

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

    /// Copies the clip, dismisses the Floating Palette, reactivates the previous external app,
    /// and if `directPasteToActiveApp && AXIsProcessTrusted()` is true, synthesizes `⌘V` after 40ms.
    public func copyAndPasteFromPalette(
        _ text: String,
        markClipID: UUID? = nil,
        onDismiss: () -> Void
    ) {
        copyToSystemClipboard(text, markClipID: markClipID)
        let targetApp = lastExternalApplication
        let shouldDirectPaste = preferences.directPasteToActiveApp
        onDismiss()

        AccessibilityPasteHelper.reactivateAndPasteIfNeeded(
            previousApp: targetApp,
            directPasteEnabled: shouldDirectPaste
        ) { [weak self] pasted in
            if pasted {
                Task { @MainActor [weak self] in
                    self?.lastStatusBanner = "Copied & pasted into \(targetApp?.localizedName ?? "active app")"
                }
            }
        }
    }

    @discardableResult
    public func generateAndCopyUUID() -> String {
        let uuid = UUID().uuidString.lowercased()
        copyToSystemClipboard(uuid)
        _ = ingestClipboardContent(
            uuid,
            metadata: PasteboardMetadata(sourceAppName: "GhostClipboard UUID Generator")
        )
        lastStatusBanner = "Generated & copied UUID v4: \(uuid)"
        return uuid
    }

    @discardableResult
    public func copyMergedClips(pinnedOnly: Bool = false, limit: Int = 5, separator: String = "\n\n") -> String {
        let candidates = pinnedOnly
            ? persistentClips.filter { $0.isPinned }
            : Array(persistentClips.prefix(max(1, limit)))
        guard !candidates.isEmpty else {
            lastStatusBanner = pinnedOnly ? "No pinned clips to merge" : "No clips available to merge"
            return ""
        }
        let merged = candidates.map(\.content).joined(separator: separator)
        copyToSystemClipboard(merged)
        lastStatusBanner = "Merged & copied \(candidates.count) \(pinnedOnly ? "pinned" : "recent") clips"
        return merged
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
        BoundedContentCache.shared.evictAll()
        onMemoryPressureTrim?()
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
