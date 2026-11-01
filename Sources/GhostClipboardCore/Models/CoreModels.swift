import Foundation

// MARK: - Content Category

public enum ClipCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case code = "code"
    case hexColor = "hex_color"
    case url = "url"
    case otp = "otp"
    case credential = "credential"
    case markdown = "markdown"
    case json = "json"
    case terminalCommand = "terminal_command"
    case plainText = "plain_text"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .code: return "Code"
        case .hexColor: return "Colors"
        case .url: return "Links"
        case .otp: return "OTP"
        case .credential: return "Credentials"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .terminalCommand: return "Terminal"
        case .plainText: return "Plain Text"
        }
    }

    public var shortLabel: String {
        switch self {
        case .code: return "CODE"
        case .hexColor: return "COLOR"
        case .url: return "LINK"
        case .otp: return "OTP"
        case .credential: return "SECRET"
        case .markdown: return "MD"
        case .json: return "JSON"
        case .terminalCommand: return "SHELL"
        case .plainText: return "TEXT"
        }
    }

    public var systemIconName: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .hexColor: return "paintpalette"
        case .url: return "link"
        case .otp: return "key.horizontal"
        case .credential: return "lock.shield"
        case .markdown: return "doc.richtext"
        case .json: return "curlybraces"
        case .terminalCommand: return "terminal"
        case .plainText: return "doc.text"
        }
    }
}

// MARK: - Programming Languages

public enum ProgrammingLanguage: String, Codable, CaseIterable, Sendable {
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case python = "Python"
    case rust = "Rust"
    case go = "Go"
    case java = "Java"
    case c = "C"
    case cpp = "C++"
    case swift = "Swift"
    case kotlin = "Kotlin"
    case ruby = "Ruby"
    case php = "PHP"
    case sql = "SQL"
    case html = "HTML"
    case css = "CSS"
    case shell = "Shell"
    case powershell = "PowerShell"

    public var shortBadge: String {
        switch self {
        case .javascript: return "JS"
        case .typescript: return "TS"
        case .python: return "PY"
        case .rust: return "RS"
        case .go: return "GO"
        case .java: return "JAVA"
        case .c: return "C"
        case .cpp: return "C++"
        case .swift: return "SWIFT"
        case .kotlin: return "KT"
        case .ruby: return "RB"
        case .php: return "PHP"
        case .sql: return "SQL"
        case .html: return "HTML"
        case .css: return "CSS"
        case .shell: return "SH"
        case .powershell: return "PS1"
        }
    }
}

// MARK: - Sensitivity Level

/// Section 6.2 Sensitivity Levels
public enum SensitivityLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    /// Level 0 — Normal: Non-sensitive text, code, URLs, Markdown, colors, JSON. Default retention: 30 days.
    case normal = 0
    /// Level 1 — Potentially sensitive: Content with uncertain characteristics. Default: quarantine / short-lived policy.
    case potentiallySensitive = 1
    /// Level 2 — Sensitive: Recognized tokens, credentials, private keys, password-manager secrets. Default: zero persistent retention.
    case sensitive = 2
    /// Level 3 — Ephemeral secret: User-authorized temporary item (e.g. OTP or temporary token) retained in-memory for 120s.
    case ephemeralSecret = 3

    public static func < (lhs: SensitivityLevel, rhs: SensitivityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .normal: return "Level 0 — Normal"
        case .potentiallySensitive: return "Level 1 — Potentially Sensitive"
        case .sensitive: return "Level 2 — Sensitive (Blocked)"
        case .ephemeralSecret: return "Level 3 — Ephemeral Secret"
        }
    }

    public var badgeText: String {
        switch self {
        case .normal: return "Standard"
        case .potentiallySensitive: return "Quarantined"
        case .sensitive: return "Never Persisted"
        case .ephemeralSecret: return "Ephemeral"
        }
    }
}

// MARK: - Retention Policy Decision

public enum RetentionDisposition: String, Codable, Sendable {
    /// Persist encrypted in SQLite database with standard expiration (e.g. 30 days)
    case persistStandard = "persist_standard"
    /// Keep only in memory with short countdown (e.g. 120 seconds for ephemeral secrets or quarantined Level 1 items)
    case memoryOnlyEphemeral = "memory_only_ephemeral"
    /// Block immediately; never store in database or in-memory clip list (record non-sensitive telemetry count only)
    case discardImmediately = "discard_immediately"
}

// MARK: - Pasteboard Metadata

public struct PasteboardMetadata: Codable, Equatable, Sendable {
    public var types: [String]
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var isTransient: Bool
    public var isConcealed: Bool
    public var isAutoGenerated: Bool
    public var hasPasswordManagerMarker: Bool

    public init(
        types: [String] = [],
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isTransient: Bool = false,
        isConcealed: Bool = false,
        isAutoGenerated: Bool = false,
        hasPasswordManagerMarker: Bool = false
    ) {
        self.types = types
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isTransient = isTransient
        self.isConcealed = isConcealed
        self.isAutoGenerated = isAutoGenerated
        self.hasPasswordManagerMarker = hasPasswordManagerMarker
    }

    public static let transientType = "org.nspasteboard.TransientType"
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let autoGeneratedType = "org.nspasteboard.AutoGeneratedType"

    public static let knownPasswordManagerTypes: Set<String> = [
        "com.agilebits.onepassword",
        "de.kksoftware.keepassx",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords"
    ]

    public static let defaultExcludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.enpass.Enpass"
    ]
}

// MARK: - Color Info

public struct ColorComponents: Codable, Equatable, Sendable {
    public let red: Double      // 0...1
    public let green: Double    // 0...1
    public let blue: Double     // 0...1
    public let alpha: Double    // 0...1

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    public var hexString: String {
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        if alpha < 0.999 {
            let a = Int(round(alpha * 255))
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public var rgbString: String {
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        if alpha < 0.999 {
            return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, alpha)
        }
        return "rgb(\(r), \(g), \(b))"
    }

    public var hslString: String {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC
        var h: Double = 0
        let l: Double = (maxC + minC) / 2.0
        let s: Double = delta == 0 ? 0 : delta / (1.0 - abs(2.0 * l - 1.0))

        if delta != 0 {
            if maxC == red {
                h = 60.0 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == green {
                h = 60.0 * (((blue - red) / delta) + 2.0)
            } else {
                h = 60.0 * (((red - green) / delta) + 4.0)
            }
        }
        if h < 0 { h += 360.0 }

        let hInt = Int(round(h))
        let sInt = Int(round(s * 100))
        let lInt = Int(round(l * 100))
        if alpha < 0.999 {
            return String(format: "hsla(%d, %d%%, %d%%, %.2f)", hInt, sInt, lInt, alpha)
        }
        return "hsl(\(hInt), \(sInt)%, \(lInt)%)"
    }
}

// MARK: - Classification Result

public struct ClassificationResult: Codable, Equatable, Sendable {
    public var primaryCategory: ClipCategory
    public var secondaryCategories: [ClipCategory]
    public var detectedLanguage: ProgrammingLanguage?
    public var confidence: Double
    public var colorComponents: ColorComponents?
    public var urlHostname: String?
    public var isSuspiciousDomain: Bool
    public var terminalSafetyWarning: String?
    public var jsonIsValid: Bool

    public init(
        primaryCategory: ClipCategory,
        secondaryCategories: [ClipCategory] = [],
        detectedLanguage: ProgrammingLanguage? = nil,
        confidence: Double = 1.0,
        colorComponents: ColorComponents? = nil,
        urlHostname: String? = nil,
        isSuspiciousDomain: Bool = false,
        terminalSafetyWarning: String? = nil,
        jsonIsValid: Bool = false
    ) {
        self.primaryCategory = primaryCategory
        self.secondaryCategories = secondaryCategories
        self.detectedLanguage = detectedLanguage
        self.confidence = confidence
        self.colorComponents = colorComponents
        self.urlHostname = urlHostname
        self.isSuspiciousDomain = isSuspiciousDomain
        self.terminalSafetyWarning = terminalSafetyWarning
        self.jsonIsValid = jsonIsValid
    }
}

// MARK: - Security Evaluation Result

public struct SecurityEvaluation: Codable, Equatable, Sendable {
    public var sensitivityLevel: SensitivityLevel
    public var disposition: RetentionDisposition
    public var detectionReasons: [String]
    public var detectedSecretType: String?
    public var expirationSeconds: TimeInterval?

    public init(
        sensitivityLevel: SensitivityLevel,
        disposition: RetentionDisposition,
        detectionReasons: [String] = [],
        detectedSecretType: String? = nil,
        expirationSeconds: TimeInterval? = nil
    ) {
        self.sensitivityLevel = sensitivityLevel
        self.disposition = disposition
        self.detectionReasons = detectionReasons
        self.detectedSecretType = detectedSecretType
        self.expirationSeconds = expirationSeconds
    }
}

// MARK: - Clip Item

public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var contentPreview: String
    public var contentHash: String
    public var primaryCategory: ClipCategory
    public var secondaryCategories: [ClipCategory]
    public var detectedLanguage: ProgrammingLanguage?
    public var sourceApplication: String?
    public var sourceBundleID: String?
    public var sensitivityLevel: SensitivityLevel
    public var isPinned: Bool
    public var isFavorite: Bool
    public var isEphemeral: Bool
    public var characterCount: Int
    public var lineCount: Int
    public var byteSize: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date
    public var expiresAt: Date?
    public var colorComponents: ColorComponents?
    public var urlHostname: String?
    public var isSuspiciousDomain: Bool
    public var terminalSafetyWarning: String?
    public var detectionReasons: [String]
    public var userOverrodeCategory: Bool

    public init(
        id: UUID = UUID(),
        content: String,
        contentPreview: String? = nil,
        contentHash: String,
        primaryCategory: ClipCategory,
        secondaryCategories: [ClipCategory] = [],
        detectedLanguage: ProgrammingLanguage? = nil,
        sourceApplication: String? = nil,
        sourceBundleID: String? = nil,
        sensitivityLevel: SensitivityLevel = .normal,
        isPinned: Bool = false,
        isFavorite: Bool = false,
        isEphemeral: Bool = false,
        characterCount: Int? = nil,
        lineCount: Int? = nil,
        byteSize: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date = Date(),
        expiresAt: Date? = nil,
        colorComponents: ColorComponents? = nil,
        urlHostname: String? = nil,
        isSuspiciousDomain: Bool = false,
        terminalSafetyWarning: String? = nil,
        detectionReasons: [String] = [],
        userOverrodeCategory: Bool = false
    ) {
        self.id = id
        self.content = content
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPreview = String(trimmed.prefix(240)).replacingOccurrences(of: "\n", with: " ↵ ")
        self.contentPreview = contentPreview ?? defaultPreview
        self.contentHash = contentHash
        self.primaryCategory = primaryCategory
        self.secondaryCategories = secondaryCategories
        self.detectedLanguage = detectedLanguage
        self.sourceApplication = sourceApplication
        self.sourceBundleID = sourceBundleID
        self.sensitivityLevel = sensitivityLevel
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.isEphemeral = isEphemeral
        self.characterCount = characterCount ?? content.count
        self.lineCount = lineCount ?? max(1, content.components(separatedBy: .newlines).count)
        self.byteSize = byteSize ?? content.utf8.count
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.colorComponents = colorComponents
        self.urlHostname = urlHostname
        self.isSuspiciousDomain = isSuspiciousDomain
        self.terminalSafetyWarning = terminalSafetyWarning
        self.detectionReasons = detectionReasons
        self.userOverrodeCategory = userOverrodeCategory
    }

    public var isSensitiveOrEphemeral: Bool {
        sensitivityLevel != .normal || isEphemeral || primaryCategory == .otp || primaryCategory == .credential
    }

    public var maskedPreview: String {
        let len = min(max(content.count, 8), 24)
        if content.count > 6 {
            let prefix = content.prefix(2)
            let suffix = content.suffix(2)
            return "\(prefix)\(String(repeating: "•", count: len - 4))\(suffix)"
        }
        return String(repeating: "•", count: len)
    }

    public func remainingSeconds(at date: Date = Date()) -> TimeInterval? {
        guard let expiresAt = expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(date))
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard !isPinned, let expiresAt = expiresAt else { return false }
        return date >= expiresAt
    }
}

// MARK: - Excluded Event Log (Non-sensitive audit record)

/// Transparently shows the user what was excluded/blocked without storing the secret content itself.
public struct ExcludedCaptureEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let reason: String
    public let secretType: String
    public let sourceApplication: String?
    public let sensitivityLevel: SensitivityLevel

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        reason: String,
        secretType: String,
        sourceApplication: String? = nil,
        sensitivityLevel: SensitivityLevel = .sensitive
    ) {
        self.id = id
        self.timestamp = timestamp
        self.reason = reason
        self.secretType = secretType
        self.sourceApplication = sourceApplication
        self.sensitivityLevel = sensitivityLevel
    }
}

// MARK: - Application Exclusion Rule

public struct ApplicationExclusion: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var bundleIdentifier: String
    public var applicationName: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        applicationName: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

// MARK: - Security & Capture Settings

public struct GhostPreferences: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    public var showMenuBarIcon: Bool
    public var themeMode: String // "dark", "light", "system"
    public var globalShortcutKeyCode: UInt32 // Option+Space default = 49 with optionKey
    public var globalShortcutModifiers: UInt32

    // Capture settings
    public var capturePlainText: Bool
    public var captureRichText: Bool
    public var captureURLs: Bool
    public var captureCode: Bool
    public var ignoreDuplicates: Bool
    public var maxItemSizeBytes: Int
    public var monitoringPaused: Bool

    // Security settings
    public var neverSavePasswords: Bool
    public var neverSaveOTPs: Bool
    public var neverSaveAPIKeys: Bool
    public var allowEphemeralOTP: Bool
    public var quarantinePotentiallySensitive: Bool
    public var autoDeleteEphemeralItems: Bool
    public var secretExpirationDurationSeconds: TimeInterval
    public var standardRetentionDays: Int
    public var requireAuthenticationToReveal: Bool
    public var isAppLocked: Bool

    // Developer settings
    public var enableCLIAccess: Bool
    public var syntaxHighlightingEnabled: Bool
    public var autoFormatJSONPreview: Bool
    public var hasCompletedOnboarding: Bool
    public var disabledCategories: [ClipCategory]

    public init(
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true,
        themeMode: String = "dark",
        globalShortcutKeyCode: UInt32 = 49,
        globalShortcutModifiers: UInt32 = 2048,
        capturePlainText: Bool = true,
        captureRichText: Bool = true,
        captureURLs: Bool = true,
        captureCode: Bool = true,
        ignoreDuplicates: Bool = true,
        maxItemSizeBytes: Int = 1_048_576, // 1 MB
        monitoringPaused: Bool = false,
        neverSavePasswords: Bool = true,
        neverSaveOTPs: Bool = true,
        neverSaveAPIKeys: Bool = true,
        allowEphemeralOTP: Bool = false,
        quarantinePotentiallySensitive: Bool = true,
        autoDeleteEphemeralItems: Bool = true,
        secretExpirationDurationSeconds: TimeInterval = 120,
        standardRetentionDays: Int = 30,
        requireAuthenticationToReveal: Bool = true,
        isAppLocked: Bool = false,
        enableCLIAccess: Bool = false,
        syntaxHighlightingEnabled: Bool = true,
        autoFormatJSONPreview: Bool = true,
        hasCompletedOnboarding: Bool = false,
        disabledCategories: [ClipCategory] = []
    ) {
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.themeMode = themeMode
        self.globalShortcutKeyCode = globalShortcutKeyCode
        self.globalShortcutModifiers = globalShortcutModifiers
        self.capturePlainText = capturePlainText
        self.captureRichText = captureRichText
        self.captureURLs = captureURLs
        self.captureCode = captureCode
        self.ignoreDuplicates = ignoreDuplicates
        self.maxItemSizeBytes = maxItemSizeBytes
        self.monitoringPaused = monitoringPaused
        self.neverSavePasswords = neverSavePasswords
        self.neverSaveOTPs = neverSaveOTPs
        self.neverSaveAPIKeys = neverSaveAPIKeys
        self.allowEphemeralOTP = allowEphemeralOTP
        self.quarantinePotentiallySensitive = quarantinePotentiallySensitive
        self.autoDeleteEphemeralItems = autoDeleteEphemeralItems
        self.secretExpirationDurationSeconds = secretExpirationDurationSeconds
        self.standardRetentionDays = standardRetentionDays
        self.requireAuthenticationToReveal = requireAuthenticationToReveal
        self.isAppLocked = isAppLocked
        self.enableCLIAccess = enableCLIAccess
        self.syntaxHighlightingEnabled = syntaxHighlightingEnabled
        self.autoFormatJSONPreview = autoFormatJSONPreview
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.disabledCategories = disabledCategories
    }

    enum CodingKeys: String, CodingKey {
        case launchAtLogin, showMenuBarIcon, themeMode, globalShortcutKeyCode, globalShortcutModifiers
        case capturePlainText, captureRichText, captureURLs, captureCode, ignoreDuplicates, maxItemSizeBytes, monitoringPaused
        case neverSavePasswords, neverSaveOTPs, neverSaveAPIKeys, allowEphemeralOTP, quarantinePotentiallySensitive
        case autoDeleteEphemeralItems, secretExpirationDurationSeconds, standardRetentionDays, requireAuthenticationToReveal, isAppLocked
        case enableCLIAccess, syntaxHighlightingEnabled, autoFormatJSONPreview, hasCompletedOnboarding, disabledCategories
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        self.themeMode = try c.decodeIfPresent(String.self, forKey: .themeMode) ?? "dark"
        self.globalShortcutKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .globalShortcutKeyCode) ?? 49
        self.globalShortcutModifiers = try c.decodeIfPresent(UInt32.self, forKey: .globalShortcutModifiers) ?? 2048
        self.capturePlainText = try c.decodeIfPresent(Bool.self, forKey: .capturePlainText) ?? true
        self.captureRichText = try c.decodeIfPresent(Bool.self, forKey: .captureRichText) ?? true
        self.captureURLs = try c.decodeIfPresent(Bool.self, forKey: .captureURLs) ?? true
        self.captureCode = try c.decodeIfPresent(Bool.self, forKey: .captureCode) ?? true
        self.ignoreDuplicates = try c.decodeIfPresent(Bool.self, forKey: .ignoreDuplicates) ?? true
        self.maxItemSizeBytes = try c.decodeIfPresent(Int.self, forKey: .maxItemSizeBytes) ?? 1_048_576
        self.monitoringPaused = try c.decodeIfPresent(Bool.self, forKey: .monitoringPaused) ?? false
        self.neverSavePasswords = try c.decodeIfPresent(Bool.self, forKey: .neverSavePasswords) ?? true
        self.neverSaveOTPs = try c.decodeIfPresent(Bool.self, forKey: .neverSaveOTPs) ?? true
        self.neverSaveAPIKeys = try c.decodeIfPresent(Bool.self, forKey: .neverSaveAPIKeys) ?? true
        self.allowEphemeralOTP = try c.decodeIfPresent(Bool.self, forKey: .allowEphemeralOTP) ?? false
        self.quarantinePotentiallySensitive = try c.decodeIfPresent(Bool.self, forKey: .quarantinePotentiallySensitive) ?? true
        self.autoDeleteEphemeralItems = try c.decodeIfPresent(Bool.self, forKey: .autoDeleteEphemeralItems) ?? true
        self.secretExpirationDurationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .secretExpirationDurationSeconds) ?? 120
        self.standardRetentionDays = try c.decodeIfPresent(Int.self, forKey: .standardRetentionDays) ?? 30
        self.requireAuthenticationToReveal = try c.decodeIfPresent(Bool.self, forKey: .requireAuthenticationToReveal) ?? true
        self.isAppLocked = try c.decodeIfPresent(Bool.self, forKey: .isAppLocked) ?? false
        self.enableCLIAccess = try c.decodeIfPresent(Bool.self, forKey: .enableCLIAccess) ?? false
        self.syntaxHighlightingEnabled = try c.decodeIfPresent(Bool.self, forKey: .syntaxHighlightingEnabled) ?? true
        self.autoFormatJSONPreview = try c.decodeIfPresent(Bool.self, forKey: .autoFormatJSONPreview) ?? true
        self.hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        self.disabledCategories = try c.decodeIfPresent([ClipCategory].self, forKey: .disabledCategories) ?? []
    }

    public func isCategoryCaptureEnabled(_ category: ClipCategory) -> Bool {
        if disabledCategories.contains(category) {
            return false
        }
        switch category {
        case .plainText:
            return capturePlainText
        case .markdown:
            return captureRichText
        case .url:
            return captureURLs
        case .code, .terminalCommand:
            return captureCode
        case .hexColor, .json:
            return true
        case .otp:
            return allowEphemeralOTP || !neverSaveOTPs
        case .credential:
            return !neverSaveAPIKeys || !neverSavePasswords
        }
    }

    public mutating func setCategoryCaptureEnabled(_ category: ClipCategory, enabled: Bool) {
        if enabled {
            disabledCategories.removeAll { $0 == category }
        } else if !disabledCategories.contains(category) && category != .otp && category != .credential {
            disabledCategories.append(category)
        }

        switch category {
        case .plainText:
            capturePlainText = enabled
        case .markdown:
            captureRichText = enabled
        case .url:
            captureURLs = enabled
        case .code:
            captureCode = enabled
            if enabled {
                disabledCategories.removeAll { $0 == .terminalCommand }
            }
        case .terminalCommand:
            if enabled && !captureCode {
                captureCode = true
            }
        case .hexColor, .json:
            break
        case .otp:
            allowEphemeralOTP = enabled
            neverSaveOTPs = !enabled
        case .credential:
            neverSaveAPIKeys = !enabled
        }
    }
}
