import SwiftUI
import AppKit
import GhostClipboardCore

/// Section 7.6 Settings Tabs
public enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case capture = "Capture"
    case categories = "Categories"
    case security = "Security"
    case storage = "Storage"
    case developerTools = "Developer Tools"
    case about = "About"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "doc.on.clipboard"
        case .categories: return "square.grid.2x2"
        case .security: return "lock.shield"
        case .storage: return "internaldrive"
        case .developerTools: return "terminal"
        case .about: return "info.circle"
        }
    }
}

public struct SettingsWindowView: View {
    @ObservedObject public var coordinator: ClipboardCoordinator
    @Environment(\.colorScheme) private var scheme

    @State private var selectedTab: SettingsTab = .general
    @State private var newBundleID: String = ""
    @State private var newAppName: String = ""
    @State private var confirmClearHistory: Bool = false

    public init(coordinator: ClipboardCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left tab list
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = (selectedTab == tab)
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 13))
                                .foregroundColor(isSelected ? GhostTheme.accent : GhostTheme.textSecondary(scheme))
                                .frame(width: 18)
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                .foregroundColor(isSelected ? GhostTheme.textPrimary(scheme) : GhostTheme.textSecondary(scheme))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? GhostTheme.elevated(scheme) : Color.clear)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                if let banner = coordinator.lastStatusBanner {
                    Divider().overlay(GhostTheme.border(scheme))
                        .padding(.vertical, 4)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(GhostTheme.success)
                        Text(banner)
                            .font(GhostTheme.metadataFont)
                            .foregroundColor(GhostTheme.textSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GhostTheme.elevated(scheme))
                    .cornerRadius(6)
                }
            }
            .padding(12)
            .frame(width: 195)
            .background(GhostTheme.surface(scheme))

            Divider().overlay(GhostTheme.border(scheme))

            // Right settings detail pane
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general: generalTab
                    case .capture: captureTab
                    case .categories: categoriesTab
                    case .security: securityTab
                    case .storage: storageTab
                    case .developerTools: developerToolsTab
                    case .about: aboutTab
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GhostTheme.background(scheme))
        }
        .frame(width: 700, height: 500)
        .preferredColorScheme(coordinator.preferences.resolvedColorScheme)
    }

    // MARK: - 7.6.1 General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("General Preferences", subtitle: "Configure startup behavior, menu bar visibility, global shortcut, and theme.")

            Toggle("Launch GhostClipboard at login", isOn: $coordinator.preferences.launchAtLogin)
            Toggle("Show icon in macOS menu bar", isOn: $coordinator.preferences.showMenuBarIcon)

            HStack {
                Text("Global Floating Palette Shortcut")
                    .font(GhostTheme.bodyFont)
                Spacer()
                KeycapBadge("⌥ Space")
            }

            HStack {
                Text("Appearance Theme")
                    .font(GhostTheme.bodyFont)
                Spacer()
                Picker("", selection: $coordinator.preferences.themeMode) {
                    Text("Dark (Recommended)").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
    }

    // MARK: - 7.6.2 Capture

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Clipboard Capture Rules", subtitle: "Control which clipboard payloads are inspected and deduplicated.")

            Toggle("Capture plain text snippets", isOn: $coordinator.preferences.capturePlainText)
            Toggle("Capture rich text & Markdown", isOn: $coordinator.preferences.captureRichText)
            Toggle("Capture URLs & deep links", isOn: $coordinator.preferences.captureURLs)
            Toggle("Capture code & terminal commands", isOn: $coordinator.preferences.captureCode)
            Toggle("Ignore consecutive duplicate copies (update timestamp instead)", isOn: $coordinator.preferences.ignoreDuplicates)
            Toggle("Pause clipboard monitoring", isOn: $coordinator.preferences.monitoringPaused)

            Divider().overlay(GhostTheme.border(scheme))

            HStack {
                Text("Maximum item size limit")
                Spacer()
                Picker("", selection: $coordinator.preferences.maxItemSizeBytes) {
                    Text("256 KB").tag(262_144)
                    Text("1 MB (Default)").tag(1_048_576)
                    Text("5 MB").tag(5_242_880)
                }
                .frame(width: 160)
            }
        }
    }

    // MARK: - 7.6.3 Categories

    private var categoriesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Automatic Content Categories", subtitle: "GhostClipboard classifies clipboard content locally with zero external network calls. Toggle any category to enable or disable capturing it.")

            ForEach(ClipCategory.allCases) { category in
                let isEnabled = coordinator.preferences.isCategoryCaptureEnabled(category)
                let itemCount = coordinator.allVisibleClips.filter { $0.primaryCategory == category }.count

                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { coordinator.preferences.isCategoryCaptureEnabled(category) },
                        set: { newVal in coordinator.setCategoryCaptureEnabled(category, enabled: newVal) }
                    ))
                    .labelsHidden()

                    Image(systemName: category.systemIconName)
                        .foregroundColor(isEnabled ? GhostTheme.accent : GhostTheme.textMuted(scheme))
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(category.displayName)
                                .font(GhostTheme.bodyMedium)
                                .foregroundColor(isEnabled ? GhostTheme.textPrimary(scheme) : GhostTheme.textMuted(scheme))
                            CategoryBadgeView(label: category.shortLabel, isHighlighted: isEnabled)
                            Text("\(itemCount) items")
                                .font(GhostTheme.metadataFont)
                                .foregroundColor(GhostTheme.textMuted(scheme))
                        }
                        Text(categoryPolicyDescription(category))
                            .font(GhostTheme.metadataFont)
                            .foregroundColor(GhostTheme.textMuted(scheme))
                    }
                    Spacer()

                    Button("Test Sample") {
                        _ = coordinator.ingestClipboardContent(
                            sampleSnippet(for: category),
                            metadata: PasteboardMetadata(sourceAppName: "Settings Category Test")
                        )
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(GhostTheme.surface(scheme))
                .cornerRadius(6)
            }
        }
    }

    private func sampleSnippet(for cat: ClipCategory) -> String {
        switch cat {
        case .code: return "func greetDeveloper(_ name: String) -> String {\n    return \"Hello, \\(name)!\"\n}"
        case .hexColor: return "#65C99A"
        case .url: return "https://swift.org/documentation/?utm_source=test"
        case .otp: return "Your verification code is 749201. Do not share it."
        case .credential: return "sk-proj-test1234567890abcdefghijklmnopqrstuvwxyz1234"
        case .markdown: return "### Sprint Notes\n- [x] Verify category toggles\n- [ ] Ship release build"
        case .json: return #"{"feature":"categories","interactive":true,"count":9}"#
        case .terminalCommand: return "git status -sb && swift test"
        case .plainText: return "Quick plain text note captured from Settings."
        }
    }

    private func categoryPolicyDescription(_ cat: ClipCategory) -> String {
        switch cat {
        case .code: return "Recognizes 17 languages (Swift, TS, JS, Python, Rust, Go, C++, SQL, etc.)"
        case .hexColor: return "Recognizes #HEX, 0xHEX, rgb(), rgba(), hsl(), hsla() with color conversion"
        case .url: return "Extracts hostname, checks domain safety, strips tracking params"
        case .otp: return "Protected: Blocked by default; toggle on to allow ephemeral memory-only timer"
        case .credential: return "Protected: API keys, PEM keys, JWTs, and password-manager secrets are blocked by default"
        case .markdown: return "Headings, task lists, blockquotes, tables, and links with live preview"
        case .json: return "Structured JSON validation, pretty-print, key sorting, and minification"
        case .terminalCommand: return "Shell, Git, Docker, K8s, and PowerShell with destructive command warnings"
        case .plainText: return "Clean fallback category for general notes and text"
        }
    }

    // MARK: - 7.6.4 Security

    private var securityTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Sensitive Content Engine & Exclusions", subtitle: "Sensitive items are evaluated before persistence and blocked from entering the database.")

            Toggle("Never save detected passwords or concealed items (Recommended)", isOn: $coordinator.preferences.neverSavePasswords)
            Toggle("Never save detected API keys, JWTs, or private keys (Recommended)", isOn: $coordinator.preferences.neverSaveAPIKeys)
            Toggle("Never save detected OTP verification codes persistently", isOn: $coordinator.preferences.neverSaveOTPs)
            Toggle("Retain OTP codes in ephemeral memory (\(Int(coordinator.preferences.secretExpirationDurationSeconds))s countdown)", isOn: $coordinator.preferences.allowEphemeralOTP)
            Toggle("Quarantine high-entropy potentially sensitive tokens in memory only", isOn: $coordinator.preferences.quarantinePotentiallySensitive)
            Toggle("Require Touch ID / macOS authentication to reveal masked items", isOn: $coordinator.preferences.requireAuthenticationToReveal)

            HStack {
                Text("Ephemeral secret expiration countdown")
                Spacer()
                Picker("", selection: $coordinator.preferences.secretExpirationDurationSeconds) {
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                    Text("120 seconds (Default)").tag(120.0)
                    Text("300 seconds").tag(300.0)
                }
                .frame(width: 180)
            }

            Divider().overlay(GhostTheme.border(scheme))

            Text("EXCLUDED SOURCE APPLICATIONS")
                .font(GhostTheme.badgeFont)
                .foregroundColor(GhostTheme.textMuted(scheme))

            HStack(spacing: 8) {
                TextField("Bundle ID (e.g. com.1password.1password)", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                TextField("App Name", text: $newAppName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button("Add") {
                    let b = newBundleID.trimmingCharacters(in: .whitespaces)
                    let n = newAppName.trimmingCharacters(in: .whitespaces)
                    if !b.isEmpty {
                        coordinator.addApplicationExclusion(bundleID: b, appName: n.isEmpty ? b : n)
                        newBundleID = ""
                        newAppName = ""
                    }
                }
                .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ForEach(coordinator.applicationExclusions) { rule in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { newValue in coordinator.setApplicationExclusion(rule, isEnabled: newValue) }
                    ))
                    .labelsHidden()

                    Text(rule.applicationName)
                        .font(GhostTheme.bodyMedium)
                    Text("(\(rule.bundleIdentifier))")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.textMuted(scheme))
                    Spacer()
                    Button {
                        coordinator.removeApplicationExclusion(rule)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(GhostTheme.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(GhostTheme.surface(scheme))
                .cornerRadius(4)
            }
        }
    }

    // MARK: - 7.6.5 Storage

    private var storageTab: some View {
        let stats = coordinator.storage.fetchStorageStats()
        let formattedSize = ByteCountFormatter.string(fromByteCount: stats.databaseSizeBytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Encrypted Local Storage & Retention", subtitle: "All persisted clips are encrypted with AES-256-GCM using a key stored in the macOS Keychain.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Database Path: \(coordinator.storage.databasePath)")
                    .font(GhostTheme.codeFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                Text("Stored Clips: \(stats.totalClips) (\(stats.pinnedClips) pinned) • Ephemeral: \(coordinator.ephemeralClips.count) • Blocked Secrets: \(stats.excludedEventsCount) • Size: \(formattedSize)")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhostTheme.surface(scheme))
            .cornerRadius(6)

            HStack {
                Text("Default history retention period")
                Spacer()
                Picker("", selection: $coordinator.preferences.standardRetentionDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days (Default)").tag(30)
                    Text("90 days").tag(90)
                }
                .frame(width: 170)
            }

            Divider().overlay(GhostTheme.border(scheme))

            HStack(spacing: 12) {
                Button("Purge Expired Clips Now") {
                    coordinator.purgeExpiredClipsNow()
                }

                Button("Clear Unpinned History") {
                    coordinator.clearAllHistory(keepPinned: true)
                }

                Button("Destroy All History & Logs", role: .destructive) {
                    confirmClearHistory = true
                }
                .alert("Destroy All Clipboard History?", isPresented: $confirmClearHistory) {
                    Button("Cancel", role: .cancel) {}
                    Button("Destroy Everything", role: .destructive) {
                        coordinator.clearAllHistory(keepPinned: false)
                    }
                } message: {
                    Text("This permanently deletes all encrypted clips, FTS indexes, and audit logs from SQLite.")
                }
            }
        }
    }

    // MARK: - 7.6.6 Developer Tools

    private var developerToolsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Developer Tools & CLI Integration", subtitle: "Configure syntax highlighting, JSON formatting, and the 'ghostclipboard' command-line interface.")

            Toggle("Enable syntax highlighting in code & JSON previews", isOn: $coordinator.preferences.syntaxHighlightingEnabled)
            Toggle("Automatically pretty-print JSON in detail inspector", isOn: $coordinator.preferences.autoFormatJSONPreview)
            Toggle("Enable 'ghostclipboard' CLI access (Opt-in security gate)", isOn: $coordinator.preferences.enableCLIAccess)

            VStack(alignment: .leading, spacing: 6) {
                Text("CLI USAGE EXAMPLES")
                    .font(GhostTheme.badgeFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                Text("""
                $ ghostclipboard status
                $ ghostclipboard recent --limit 5
                $ ghostclipboard search "jwt"
                $ ghostclipboard list --category code
                """)
                .font(GhostTheme.codeFont)
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GhostTheme.surface(scheme))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - 7.6.7 About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(GhostTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("GhostClipboard 1.0")
                        .font(.system(size: 18, weight: .bold))
                    Text("Your clipboard remembers. Your secrets disappear.")
                        .font(GhostTheme.bodyFont)
                        .foregroundColor(GhostTheme.textSecondary(scheme))
                }
            }

            Divider().overlay(GhostTheme.border(scheme))

            Text("GhostClipboard is a privacy-first developer clipboard workspace for macOS. All classification, secret detection, and developer transformations run 100% locally on your Mac with zero external network calls or cloud telemetry.")
                .font(GhostTheme.bodyFont)
                .foregroundColor(GhostTheme.textSecondary(scheme))
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(GhostTheme.textPrimary(scheme))
            Text(subtitle)
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textMuted(scheme))
        }
    }
}

// MARK: - Section 7.7 Five-Screen Onboarding Flow

public struct OnboardingFlowView: View {
    @ObservedObject public var coordinator: ClipboardCoordinator
    public var onFinish: () -> Void
    @Environment(\.colorScheme) private var scheme

    @State private var currentStep: Int = 0

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Step indicator bar
            HStack(spacing: 6) {
                ForEach(0..<5, id: \.self) { step in
                    Capsule()
                        .fill(step <= currentStep ? GhostTheme.accent : GhostTheme.border(scheme))
                        .frame(height: 4)
                }
            }
            .padding(20)

            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                switch currentStep {
                case 0:
                    onboardingStepView(
                        icon: "shield.lefthalf.filled",
                        title: "1. Your clipboard remembers. Your secrets disappear.",
                        subtitle: "GhostClipboard captures useful code, links, colors, JSON, and Markdown while automatically blocking passwords, API keys, and credentials before they ever touch disk."
                    )
                case 1:
                    VStack(alignment: .leading, spacing: 12) {
                        onboardingStepView(
                            icon: "lock.shield",
                            title: "2. Choose your sensitive-content posture",
                            subtitle: "By default, GhostClipboard refuses to persist passwords, API keys, and OTP codes."
                        )
                        Toggle("Never save detected passwords (Recommended)", isOn: $coordinator.preferences.neverSavePasswords)
                        Toggle("Never save API keys, bearer tokens, or private keys", isOn: $coordinator.preferences.neverSaveAPIKeys)
                        Toggle("Never save OTP verification codes persistently", isOn: $coordinator.preferences.neverSaveOTPs)
                        Toggle("Retain OTP codes in ephemeral memory (120s countdown)", isOn: $coordinator.preferences.allowEphemeralOTP)
                    }
                case 2:
                    onboardingStepView(
                        icon: "command",
                        title: "3. Summon the Floating Palette anywhere",
                        subtitle: "Press Option + Space (⌥Space) at any time to open the compact floating clipboard palette, filter by category, or run developer actions with ⌘K."
                    )
                case 3:
                    onboardingStepView(
                        icon: "app.badge.checkmark",
                        title: "4. Password Manager & App Exclusions",
                        subtitle: "1Password, Bitwarden, KeePassXC, Dashlane, LastPass, and Apple Keychain/Passwords are automatically excluded, along with NSPasteboard ConcealedType markers."
                    )
                default:
                    onboardingStepView(
                        icon: "checkmark.seal.fill",
                        title: "5. Test Capture Ready",
                        subtitle: "Your local AES-256-GCM encrypted SQLite store is initialized. Copy any snippet or inspect the sample developer clips in your workspace."
                    )
                }
            }
            .padding(.horizontal, 28)

            Spacer()

            Divider().overlay(GhostTheme.border(scheme))

            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                }
                Spacer()
                if currentStep < 4 {
                    Button("Continue") {
                        currentStep += 1
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enter GhostClipboard Workspace") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .background(GhostTheme.surface(scheme))
        }
        .frame(width: 540, height: 380)
        .background(GhostTheme.background(scheme))
        .preferredColorScheme(coordinator.preferences.resolvedColorScheme)
    }

    private func onboardingStepView(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(GhostTheme.accent)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(GhostTheme.textPrimary(scheme))
            Text(subtitle)
                .font(GhostTheme.bodyFont)
                .foregroundColor(GhostTheme.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
