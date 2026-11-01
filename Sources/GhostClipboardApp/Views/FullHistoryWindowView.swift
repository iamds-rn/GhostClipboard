import SwiftUI
import AppKit
import GhostClipboardCore

/// Section 7.4 Left Sidebar Navigation Items
public enum WorkspaceSidebarItem: String, CaseIterable, Identifiable {
    case allClips = "All clips"
    case recent = "Recent"
    case code = "Code"
    case links = "Links"
    case colors = "Colors"
    case markdown = "Markdown"
    case json = "JSON"
    case savedSnippets = "Saved snippets"
    case expiring = "Expiring"
    case excluded = "Excluded"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .allClips: return "tray.full"
        case .recent: return "clock"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .links: return "link"
        case .colors: return "paintpalette"
        case .markdown: return "doc.richtext"
        case .json: return "curlybraces"
        case .savedSnippets: return "pin"
        case .expiring: return "timer"
        case .excluded: return "shield.slash"
        }
    }
}

public enum ClipSortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest First"
    case lastUsed = "Recently Used"
    case size = "Largest Size"

    public var id: String { rawValue }
}

public struct FullHistoryWindowView: View {
    @ObservedObject public var coordinator: ClipboardCoordinator
    public var onOpenSettings: () -> Void
    public var onTogglePalette: (() -> Void)?

    @Environment(\.colorScheme) private var scheme

    @State private var selectedSidebar: WorkspaceSidebarItem = .allClips
    @State private var selectedClipID: UUID? = nil
    @State private var sortOrder: ClipSortOrder = .newest
    @State private var showOnboardingSheet: Bool = false
    @State private var manualSnippetText: String = ""
    @State private var showAddSnippetPopover: Bool = false

    public init(
        coordinator: ClipboardCoordinator,
        onOpenSettings: @escaping () -> Void,
        onTogglePalette: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onOpenSettings = onOpenSettings
        self.onTogglePalette = onTogglePalette
    }

    private var displayedClips: [ClipItem] {
        let base = coordinator.allVisibleClips
        let filtered: [ClipItem]
        switch selectedSidebar {
        case .allClips:
            filtered = base
        case .recent:
            let cutoff = Date().addingTimeInterval(-86_400)
            filtered = base.filter { $0.createdAt >= cutoff }
        case .code:
            filtered = base.filter { $0.primaryCategory == .code || $0.primaryCategory == .terminalCommand }
        case .links:
            filtered = base.filter { $0.primaryCategory == .url }
        case .colors:
            filtered = base.filter { $0.primaryCategory == .hexColor }
        case .markdown:
            filtered = base.filter { $0.primaryCategory == .markdown }
        case .json:
            filtered = base.filter { $0.primaryCategory == .json }
        case .savedSnippets:
            filtered = base.filter { $0.isPinned || $0.isFavorite }
        case .expiring:
            filtered = base.filter { $0.isEphemeral || ($0.expiresAt != nil && !$0.isPinned) }
        case .excluded:
            filtered = []
        }

        switch sortOrder {
        case .newest:
            return filtered.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                return $0.createdAt > $1.createdAt
            }
        case .lastUsed:
            return filtered.sorted { $0.lastUsedAt > $1.lastUsedAt }
        case .size:
            return filtered.sorted { $0.byteSize > $1.byteSize }
        }
    }

    private var selectedClip: ClipItem? {
        let clips = displayedClips
        if let id = selectedClipID, let match = clips.first(where: { $0.id == id }) {
            return match
        }
        return clips.first
    }

    public var body: some View {
        GeometryReader { proxy in
            let totalWidth = max(proxy.size.width, 600)
            let sidebarWidth = max(195, min(230, floor(totalWidth * 0.21)))
            let middleWidth = max(260, min(360, floor(totalWidth * 0.31)))
            let detailWidth = max(260, totalWidth - sidebarWidth - middleWidth - 2)
            let excludedWidth = max(380, totalWidth - sidebarWidth - 1)

            ZStack {
                HStack(spacing: 0) {
                    leftSidebar
                        .frame(width: sidebarWidth, height: proxy.size.height)
                        .clipped()

                    Divider().overlay(GhostTheme.border(scheme))

                    if selectedSidebar == .excluded {
                        securityAndExcludedCenterView
                            .frame(width: excludedWidth, height: proxy.size.height)
                            .clipped()
                    } else {
                        middleClipListColumn
                            .frame(width: middleWidth, height: proxy.size.height)
                            .clipped()

                        Divider().overlay(GhostTheme.border(scheme))

                        rightInspectorColumn
                            .frame(width: detailWidth, height: proxy.size.height)
                            .clipped()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(GhostTheme.background(scheme))
                .clipped()
                .blur(radius: coordinator.preferences.isAppLocked ? 12 : 0)
                .disabled(coordinator.preferences.isAppLocked)

                if coordinator.preferences.isAppLocked {
                    lockedOverlayView
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(minWidth: 760, idealWidth: 1100, maxWidth: .infinity, minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .preferredColorScheme(coordinator.preferences.resolvedColorScheme)
        .onAppear {
            if !coordinator.preferences.hasCompletedOnboarding {
                showOnboardingSheet = true
            }
        }
        .sheet(isPresented: $showOnboardingSheet) {
            OnboardingFlowView(coordinator: coordinator) {
                coordinator.preferences.hasCompletedOnboarding = true
                showOnboardingSheet = false
            }
        }
    }

    // MARK: - Left Sidebar (Section 7.4)

    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App Title & Tagline Header
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(GhostTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GhostClipboard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("Local Privacy Engine")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(GhostTheme.textMuted(scheme))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                Button {
                    onTogglePalette?()
                } label: {
                    KeycapBadge(coordinator.preferences.hotkeyDisplayString)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Toggle Floating Palette (\(coordinator.preferences.hotkeyDisplayString))")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(GhostTheme.border(scheme))

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WORKSPACE")
                        .font(GhostTheme.badgeFont)
                        .foregroundColor(GhostTheme.textMuted(scheme))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach([WorkspaceSidebarItem.allClips, .recent, .savedSnippets]) { item in
                        sidebarRow(item)
                    }

                    Text("CATEGORIES")
                        .font(GhostTheme.badgeFont)
                        .foregroundColor(GhostTheme.textMuted(scheme))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    ForEach([WorkspaceSidebarItem.code, .links, .colors, .markdown, .json]) { item in
                        sidebarRow(item)
                    }

                    Text("SECURITY & RETENTION")
                        .font(GhostTheme.badgeFont)
                        .foregroundColor(GhostTheme.textMuted(scheme))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    ForEach([WorkspaceSidebarItem.expiring, .excluded]) { item in
                        sidebarRow(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
            Divider().overlay(GhostTheme.border(scheme))

            // Sidebar Footer Controls
            VStack(alignment: .leading, spacing: 8) {
                if let banner = coordinator.lastStatusBanner {
                    Text(banner)
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button {
                        coordinator.preferences.monitoringPaused.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(coordinator.preferences.monitoringPaused ? GhostTheme.warning : GhostTheme.success)
                                .frame(width: 7, height: 7)
                            Text(coordinator.preferences.monitoringPaused ? "Monitoring Paused" : "Monitoring Active")
                                .font(GhostTheme.metadataFont)
                                .foregroundColor(GhostTheme.textSecondary(scheme))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 4)

                    Button {
                        coordinator.preferences.isAppLocked = true
                    } label: {
                        Image(systemName: "lock")
                            .font(.system(size: 12))
                            .foregroundColor(GhostTheme.textSecondary(scheme))
                    }
                    .buttonStyle(.plain)
                    .help("Lock GhostClipboard")

                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(GhostTheme.textSecondary(scheme))
                    }
                    .buttonStyle(.plain)
                    .help("Open Settings")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(GhostTheme.surface(scheme))
        }
        .background(GhostTheme.surface(scheme))
    }

    private func sidebarRow(_ item: WorkspaceSidebarItem) -> some View {
        let isSelected = (selectedSidebar == item)
        let count = badgeCount(for: item)

        return Button {
            selectedSidebar = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? GhostTheme.accent : GhostTheme.textSecondary(scheme))
                    .frame(width: 18)

                Text(item.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? GhostTheme.textPrimary(scheme) : GhostTheme.textSecondary(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if count > 0 {
                    Text("\(count)")
                        .font(GhostTheme.badgeFont)
                        .foregroundColor(item == .excluded ? GhostTheme.warning : GhostTheme.textMuted(scheme))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(GhostTheme.elevated(scheme))
                        .cornerRadius(4)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? GhostTheme.elevated(scheme) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func badgeCount(for item: WorkspaceSidebarItem) -> Int {
        let all = coordinator.allVisibleClips
        switch item {
        case .allClips: return all.count
        case .recent:
            let cutoff = Date().addingTimeInterval(-86_400)
            return all.filter { $0.createdAt >= cutoff }.count
        case .code: return all.filter { $0.primaryCategory == .code || $0.primaryCategory == .terminalCommand }.count
        case .links: return all.filter { $0.primaryCategory == .url }.count
        case .colors: return all.filter { $0.primaryCategory == .hexColor }.count
        case .markdown: return all.filter { $0.primaryCategory == .markdown }.count
        case .json: return all.filter { $0.primaryCategory == .json }.count
        case .savedSnippets: return all.filter { $0.isPinned || $0.isFavorite }.count
        case .expiring: return all.filter { $0.isEphemeral || ($0.expiresAt != nil && !$0.isPinned) }.count
        case .excluded: return coordinator.excludedEvents.count
        }
    }

    // MARK: - Middle Clip List Column

    private var middleClipListColumn: some View {
        let clips = displayedClips
        return VStack(spacing: 0) {
            // Search & Sort Toolbar
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(GhostTheme.textMuted(scheme))

                    TextField("Search \(selectedSidebar.rawValue.lowercased())…", text: $coordinator.searchQuery)
                        .textFieldStyle(.plain)
                        .font(GhostTheme.bodyFont)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .onChange(of: coordinator.searchQuery) { _ in
                            coordinator.reloadClips()
                        }

                    if !coordinator.searchQuery.isEmpty {
                        Button {
                            coordinator.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(GhostTheme.textMuted(scheme))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showAddSnippetPopover.toggle()
                    } label: {
                        Image(systemName: "plus.square")
                            .font(.system(size: 13))
                            .foregroundColor(GhostTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Test or ingest clip snippet manually")
                    .popover(isPresented: $showAddSnippetPopover) {
                        manualIngestPopover
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(GhostTheme.elevated(scheme))
                .cornerRadius(6)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text("\(clips.count) items")
                            .font(GhostTheme.metadataFont)
                            .foregroundColor(GhostTheme.textMuted(scheme))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        uuidQuickButton
                        pasteStackMenu
                        sortPickerControl
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("\(clips.count) items")
                                .font(GhostTheme.metadataFont)
                                .foregroundColor(GhostTheme.textMuted(scheme))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            uuidQuickButton
                            pasteStackMenu
                        }
                        HStack {
                            Text("Sort:")
                                .font(GhostTheme.metadataFont)
                                .foregroundColor(GhostTheme.textMuted(scheme))
                            sortPickerControl
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(GhostTheme.surface(scheme))

            Divider().overlay(GhostTheme.border(scheme))

            if clips.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: selectedSidebar.iconName)
                        .font(.system(size: 24))
                        .foregroundColor(GhostTheme.textMuted(scheme))
                    Text("No clips in \(selectedSidebar.rawValue)")
                        .font(GhostTheme.bodyMedium)
                        .foregroundColor(GhostTheme.textSecondary(scheme))
                        .multilineTextAlignment(.center)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(clips) { clip in
                            let isSelected = (selectedClip?.id == clip.id)
                            historyClipCard(clip: clip, isSelected: isSelected)
                                .onTapGesture {
                                    selectedClipID = clip.id
                                }
                                .contextMenu {
                                    Button("Copy to Clipboard") {
                                        coordinator.copyToSystemClipboard(clip.content, markClipID: clip.id)
                                    }
                                    Button(clip.isPinned ? "Unpin Clip" : "Pin Clip") {
                                        coordinator.togglePin(clip)
                                    }
                                    Divider()
                                    Button("Delete Clip", role: .destructive) {
                                        coordinator.deleteClip(clip)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(GhostTheme.background(scheme))
    }

    private var uuidQuickButton: some View {
        Button {
            _ = coordinator.generateAndCopyUUID()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "number.square")
                    .font(.system(size: 11))
                Text("UUID")
                    .font(GhostTheme.metadataFont)
                    .lineLimit(1)
            }
            .foregroundColor(GhostTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(GhostTheme.elevated(scheme))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Generate a fresh UUID v4 and copy to clipboard")
    }

    private var pasteStackMenu: some View {
        Menu {
            Button("Copy Merged Pinned Clips") {
                _ = coordinator.copyMergedClips(pinnedOnly: true)
            }
            Button("Copy Merged Top 5 Recent Clips") {
                _ = coordinator.copyMergedClips(pinnedOnly: false, limit: 5)
            }
            Button("Copy Merged Top 3 (Single-Line Space Separated)") {
                _ = coordinator.copyMergedClips(pinnedOnly: false, limit: 3, separator: " ")
            }
        } label: {
            Label("Stack", systemImage: "square.stack.3d.up")
                .font(GhostTheme.metadataFont)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Paste Stack: Merge multiple pinned or recent clips")
    }

    private var sortPickerControl: some View {
        Picker("", selection: $sortOrder) {
            ForEach(ClipSortOrder.allCases) { order in
                Text(order.rawValue).tag(order)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 112)
    }

    private func historyClipCard(clip: ClipItem, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if clip.primaryCategory == .hexColor, let col = clip.colorComponents {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: col.red, green: col.green, blue: col.blue, opacity: col.alpha))
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: clip.primaryCategory.systemIconName)
                        .font(.system(size: 11))
                        .foregroundColor(GhostTheme.accent)
                }

                CategoryBadgeView(
                    label: clip.detectedLanguage?.shortBadge ?? clip.primaryCategory.shortLabel,
                    isHighlighted: isSelected
                )
                .fixedSize()

                if clip.isEphemeral {
                    CategoryBadgeView(label: "EPHEMERAL", isHighlighted: false)
                        .fixedSize()
                }

                if let app = clip.sourceApplication {
                    Text(app)
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.textMuted(scheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }

                Spacer(minLength: 4)

                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(GhostTheme.accent)
                }

                Text(clip.createdAt, style: .relative)
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Text(clip.isSensitiveOrEphemeral ? clip.maskedPreview : clip.contentPreview)
                .font(clip.primaryCategory == .code || clip.primaryCategory == .json || clip.primaryCategory == .terminalCommand ? GhostTheme.codeFont : GhostTheme.bodyFont)
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? GhostTheme.elevated(scheme) : GhostTheme.surface(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? GhostTheme.accent.opacity(0.6) : GhostTheme.border(scheme), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Right Inspector Column

    @ViewBuilder
    private var rightInspectorColumn: some View {
        if let clip = selectedClip {
            ClipDetailPreviewView(clip: clip, coordinator: coordinator)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 26))
                    .foregroundColor(GhostTheme.textMuted(scheme))
                Text("Select a clip to inspect contents and developer actions")
                    .font(GhostTheme.bodyFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GhostTheme.surface(scheme))
        }
    }

    // MARK: - Section 7.2.5 Security & Excluded Center View

    private var securityAndExcludedCenterView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Security & Retention Center")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                    Text("Your clipboard remembers. Your secrets disappear. Sensitive items are evaluated before persistence and never touch the SQLite history database.")
                        .font(GhostTheme.bodyFont)
                        .foregroundColor(GhostTheme.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Active Security Posture Cards
                HStack(spacing: 12) {
                    securityStatCard(
                        title: "Blocked Secrets",
                        value: "\(coordinator.excludedEvents.count)",
                        subtitle: "Zero bytes written to disk",
                        icon: "shield.lefthalf.filled",
                        color: GhostTheme.success
                    )
                    securityStatCard(
                        title: "Ephemeral Memory Items",
                        value: "\(coordinator.ephemeralClips.count)",
                        subtitle: "Auto-purged after \(Int(coordinator.preferences.secretExpirationDurationSeconds))s",
                        icon: "timer",
                        color: GhostTheme.warning
                    )
                    securityStatCard(
                        title: "Excluded Applications",
                        value: "\(coordinator.applicationExclusions.filter(\.isEnabled).count)",
                        subtitle: "Password managers & vaults",
                        icon: "app.badge.checkmark",
                        color: GhostTheme.accent
                    )
                }

                // Excluded Capture Audit Log (Never contains secret values!)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("EXCLUDED CAPTURE EVENTS (NON-SENSITIVE AUDIT LOG)")
                            .font(GhostTheme.badgeFont)
                            .foregroundColor(GhostTheme.textMuted(scheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Button("Clear System Clipboard Now") {
                            coordinator.clearSystemClipboard()
                        }
                        .font(GhostTheme.metadataFont)
                        .fixedSize()
                    }

                    if coordinator.excludedEvents.isEmpty {
                        Text("No sensitive captures have been blocked yet.")
                            .font(GhostTheme.bodyFont)
                            .foregroundColor(GhostTheme.textMuted(scheme))
                            .padding(16)
                    } else {
                        ForEach(coordinator.excludedEvents) { event in
                            HStack(spacing: 12) {
                                Image(systemName: "lock.slash.fill")
                                    .foregroundColor(GhostTheme.danger)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(event.secretType)
                                            .font(GhostTheme.bodyMedium)
                                            .foregroundColor(GhostTheme.textPrimary(scheme))
                                            .lineLimit(1)
                                        CategoryBadgeView(label: event.sensitivityLevel.badgeText)
                                            .fixedSize()
                                    }
                                    Text("\(event.reason) • Source: \(event.sourceApplication ?? "System")")
                                        .font(GhostTheme.metadataFont)
                                        .foregroundColor(GhostTheme.textMuted(scheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                Text(event.timestamp, style: .relative)
                                    .font(GhostTheme.metadataFont)
                                    .foregroundColor(GhostTheme.textMuted(scheme))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .padding(12)
                            .background(GhostTheme.surface(scheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
                            )
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GhostTheme.background(scheme))
    }

    private func securityStatCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .lineLimit(1)
            Text(subtitle)
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textMuted(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GhostTheme.surface(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(GhostTheme.border(scheme), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Manual Ingest Popover (For Testing Classification & Sensitivity Rules Directly)

    private var manualIngestPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Simulate / Ingest Clipboard Content")
                .font(GhostTheme.titleFont)
            Text("Paste or type any code, URL, JSON, color, or secret key to test GhostClipboard's local classifier and pre-persistence security engine.")
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textSecondary(scheme))

            TextEditor(text: $manualSnippetText)
                .font(GhostTheme.codeFont)
                .frame(width: 360, height: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(GhostTheme.border(scheme), lineWidth: 1))

            HStack {
                Button("Cancel") {
                    showAddSnippetPopover = false
                }
                Spacer()
                Button("Evaluate & Capture") {
                    _ = coordinator.ingestClipboardContent(
                        manualSnippetText,
                        metadata: PasteboardMetadata(sourceAppName: "Manual Workspace Input")
                    )
                    manualSnippetText = ""
                    showAddSnippetPopover = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualSnippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    // MARK: - Locked Application Overlay

    private var lockedOverlayView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 36))
                .foregroundColor(GhostTheme.accent)
            Text("GhostClipboard is Locked")
                .font(GhostTheme.titleFont)
                .foregroundColor(GhostTheme.textPrimary(scheme))
            Text("Authenticate with Touch ID or your macOS password to unlock your clipboard workspace.")
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textSecondary(scheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                Task {
                    let ok = await CryptoVault.authenticateUser(reason: "Unlock GhostClipboard workspace")
                    if ok {
                        coordinator.preferences.isAppLocked = false
                    }
                }
            } label: {
                Text("Unlock Workspace")
                    .font(GhostTheme.bodyMedium)
                    .foregroundColor(GhostTheme.darkBackground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(GhostTheme.accent)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .background(GhostTheme.surface(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(GhostTheme.border(scheme), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}
