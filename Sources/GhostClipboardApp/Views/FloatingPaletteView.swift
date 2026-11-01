import SwiftUI
import AppKit
import GhostClipboardCore

/// Section 7.3.3 Category Strip Tabs
public enum PaletteTab: String, CaseIterable, Identifiable {
    case all = "All"
    case code = "Code"
    case links = "Links"
    case colors = "Colors"
    case markdown = "Markdown"
    case json = "JSON"
    case temporary = "Temporary"
    case saved = "Saved"

    public var id: String { rawValue }
}

public struct FloatingPaletteView: View {
    @ObservedObject public var coordinator: ClipboardCoordinator
    public var onOpenFullHistory: () -> Void
    public var onOpenSettings: () -> Void
    public var onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @FocusState private var isSearchFocused: Bool

    @State private var selectedTab: PaletteTab = .all
    @State private var selectedIndex: Int = 0
    @State private var showActionMenu: Bool = false
    @State private var now: Date = Date()
    @State private var keyMonitor: Any? = nil

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let commandNumberKeyCodeToIndex: [UInt16: Int] = [
        18: 0, // ⌘1
        19: 1, // ⌘2
        20: 2, // ⌘3
        21: 3, // ⌘4
        23: 4, // ⌘5
        22: 5, // ⌘6
        26: 6, // ⌘7
        28: 7, // ⌘8
        25: 8  // ⌘9
    ]

    public init(
        coordinator: ClipboardCoordinator,
        onOpenFullHistory: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.onOpenFullHistory = onOpenFullHistory
        self.onOpenSettings = onOpenSettings
        self.onDismiss = onDismiss
    }

    private var filteredClips: [ClipItem] {
        let base = coordinator.allVisibleClips
        switch selectedTab {
        case .all:
            return base
        case .code:
            return base.filter { $0.primaryCategory == .code || $0.primaryCategory == .terminalCommand }
        case .links:
            return base.filter { $0.primaryCategory == .url }
        case .colors:
            return base.filter { $0.primaryCategory == .hexColor }
        case .markdown:
            return base.filter { $0.primaryCategory == .markdown }
        case .json:
            return base.filter { $0.primaryCategory == .json }
        case .temporary:
            return base.filter { $0.isEphemeral || $0.sensitivityLevel != .normal }
        case .saved:
            return base.filter { $0.isPinned || $0.isFavorite }
        }
    }

    private var selectedClip: ClipItem? {
        let clips = filteredClips
        guard !clips.isEmpty, selectedIndex >= 0, selectedIndex < clips.count else {
            return clips.first
        }
        return clips[selectedIndex]
    }

    private var primaryReturnLabel: String {
        coordinator.preferences.directPasteToActiveApp ? "Copy & Paste" : "Copy"
    }

    public var body: some View {
        GeometryReader { proxy in
            let leftWidth = max(240, min(330, floor(proxy.size.width * 0.48)))
            let rightWidth = max(240, proxy.size.width - leftWidth - 1)

            VStack(spacing: 0) {
                headerBar
                Divider().overlay(GhostTheme.border(scheme))

                categoryStrip
                Divider().overlay(GhostTheme.border(scheme))

                mainSplitContent(leftWidth: leftWidth, rightWidth: rightWidth)
                    .frame(maxHeight: .infinity)
                Divider().overlay(GhostTheme.border(scheme))

                footerBar
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        // Section 7.3.1: Default 640x480, min 520, max 760
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 760, minHeight: 420, idealHeight: 480, maxHeight: 600)
        .background(GhostTheme.background(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(GhostTheme.border(scheme), lineWidth: 1)
        )
        .cornerRadius(10)
        .clipped()
        .preferredColorScheme(coordinator.preferences.resolvedColorScheme)
        .onAppear {
            now = Date()
            isSearchFocused = true
            selectedIndex = 0
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: coordinator.searchQuery) { _ in
            selectedIndex = 0
            coordinator.reloadClips()
        }
        .onChange(of: selectedTab) { _ in
            selectedIndex = 0
        }
        .onReceive(timer) { tick in
            if !coordinator.ephemeralClips.isEmpty {
                now = tick
            }
        }
        .sheet(isPresented: $showActionMenu) {
            if let clip = selectedClip {
                actionMenuSheet(for: clip)
            }
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is FloatingPalettePanel else {
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // Instant ⌘1 – ⌘9 quick-select shortcuts
            if flags == .command, let targetIdx = Self.commandNumberKeyCodeToIndex[event.keyCode] {
                guard !showActionMenu else { return event }
                let clips = filteredClips
                if targetIdx < clips.count {
                    selectedIndex = targetIdx
                    let clip = clips[targetIdx]
                    coordinator.copyAndPasteFromPalette(clip.content, markClipID: clip.id, onDismiss: onDismiss)
                    return nil
                }
            }

            switch event.keyCode {
            case 126: // Up Arrow
                guard !showActionMenu else { return event }
                if selectedIndex > 0 {
                    selectedIndex -= 1
                }
                return nil

            case 125: // Down Arrow
                guard !showActionMenu else { return event }
                let count = filteredClips.count
                if selectedIndex + 1 < count {
                    selectedIndex += 1
                }
                return nil

            case 53: // Escape
                if showActionMenu {
                    showActionMenu = false
                } else {
                    onDismiss()
                }
                return nil

            case 36, 76: // Return or Keypad Enter
                guard !showActionMenu, let clip = selectedClip else { return event }
                let payload = flags.contains(.command)
                    ? clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    : clip.content
                coordinator.copyAndPasteFromPalette(payload, markClipID: clip.id, onDismiss: onDismiss)
                return nil

            case 40: // 'K' key
                if flags.contains(.command), selectedClip != nil {
                    showActionMenu.toggle()
                    return nil
                }
                return event

            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - 7.3.2 Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(GhostTheme.accent)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(GhostTheme.textMuted(scheme))

            TextField("Search clipboard history, languages, hosts, or colors…", text: $coordinator.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .focused($isSearchFocused)
                .onSubmit {
                    if let clip = selectedClip {
                        coordinator.copyAndPasteFromPalette(clip.content, markClipID: clip.id, onDismiss: onDismiss)
                    }
                }

            if !coordinator.searchQuery.isEmpty {
                Button {
                    coordinator.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(GhostTheme.textMuted(scheme))
                }
                .buttonStyle(.plain)
            }

            // Quick Generate UUID v4 button
            Button {
                _ = coordinator.generateAndCopyUUID()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "number.square")
                        .font(.system(size: 11))
                    Text("UUID v4")
                        .font(GhostTheme.metadataFont)
                        .lineLimit(1)
                }
                .foregroundColor(GhostTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(GhostTheme.elevated(scheme))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Generate a fresh UUID v4 and copy to clipboard")

            // Monitoring status indicator
            Button {
                coordinator.preferences.monitoringPaused.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(coordinator.preferences.monitoringPaused ? GhostTheme.warning : GhostTheme.success)
                        .frame(width: 7, height: 7)
                    Text(coordinator.preferences.monitoringPaused ? "Paused" : "Capturing")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.textSecondary(scheme))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(GhostTheme.elevated(scheme))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Toggle live clipboard monitoring")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(GhostTheme.surface(scheme))
    }

    // MARK: - 7.3.3 Category Strip

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PaletteTab.allCases) { tab in
                    let isSelected = (selectedTab == tab)
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? GhostTheme.darkBackground : GhostTheme.textSecondary(scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(isSelected ? GhostTheme.accent : GhostTheme.elevated(scheme))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(GhostTheme.background(scheme))
    }

    // MARK: - 7.3.4 Results List & Quick Compact Preview

    private func mainSplitContent(leftWidth: CGFloat, rightWidth: CGFloat) -> some View {
        let clips = filteredClips
        return HStack(spacing: 0) {
            if clips.isEmpty {
                emptyStateView
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(clips.enumerated()), id: \.element.id) { idx, clip in
                                paletteRow(clip: clip, index: idx, isSelected: idx == selectedIndex)
                                    .id(clip.id)
                                    .onTapGesture {
                                        selectedIndex = idx
                                    }
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded {
                                            coordinator.copyAndPasteFromPalette(clip.content, markClipID: clip.id, onDismiss: onDismiss)
                                        }
                                    )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: selectedIndex) { newIdx in
                        if newIdx >= 0 && newIdx < clips.count {
                            withAnimation(.easeOut(duration: 0.12)) {
                                scrollProxy.scrollTo(clips[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }
                .frame(width: leftWidth)
                .clipped()

                Divider().overlay(GhostTheme.border(scheme))

                // Right quick preview pane
                if let current = selectedClip {
                    compactInspectorPane(for: current)
                        .frame(width: rightWidth)
                        .clipped()
                }
            }
        }
    }

    private func paletteRow(clip: ClipItem, index: Int, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            // Color swatch or category icon
            if clip.primaryCategory == .hexColor, let col = clip.colorComponents {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: col.red, green: col.green, blue: col.blue, opacity: col.alpha))
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(GhostTheme.border(scheme), lineWidth: 1))
            } else {
                Image(systemName: clip.primaryCategory.systemIconName)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? GhostTheme.accent : GhostTheme.textSecondary(scheme))
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(clip.isSensitiveOrEphemeral ? clip.maskedPreview : clip.contentPreview)
                        .font(clip.primaryCategory == .code || clip.primaryCategory == .json || clip.primaryCategory == .terminalCommand ? GhostTheme.codeFont : GhostTheme.bodyFont)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if index < 9 {
                        KeycapBadge("⌘\(index + 1)")
                            .fixedSize()
                    }
                }

                HStack(spacing: 6) {
                    CategoryBadgeView(
                        label: clip.detectedLanguage?.shortBadge ?? clip.primaryCategory.shortLabel,
                        isHighlighted: isSelected
                    )
                    .fixedSize()

                    if let app = clip.sourceApplication {
                        Text(app)
                            .font(GhostTheme.metadataFont)
                            .foregroundColor(GhostTheme.textMuted(scheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }

                    Spacer(minLength: 4)

                    if let rem = clip.remainingSeconds(at: now), rem < 3600 {
                        Text("\(Int(rem))s")
                            .font(GhostTheme.badgeFont)
                            .foregroundColor(GhostTheme.warning)
                            .fixedSize()
                    } else {
                        Text(shortRelativeTime(clip.createdAt))
                            .font(GhostTheme.metadataFont)
                            .foregroundColor(GhostTheme.textMuted(scheme))
                            .fixedSize()
                    }

                    if clip.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(GhostTheme.accent)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? GhostTheme.elevated(scheme) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? GhostTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func compactInspectorPane(for clip: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(clip.primaryCategory.displayName.uppercased())
                    .font(GhostTheme.badgeFont)
                    .foregroundColor(GhostTheme.accent)
                    .lineLimit(1)
                if let lang = clip.detectedLanguage {
                    Text("• \(lang.rawValue)")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.textSecondary(scheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Button {
                    showActionMenu = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Actions")
                            .font(GhostTheme.metadataFont)
                        KeycapBadge("⌘K")
                    }
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(GhostTheme.surface(scheme))

            Divider().overlay(GhostTheme.border(scheme))

            ScrollView {
                let previewText: String = {
                    if clip.primaryCategory == .json && coordinator.preferences.autoFormatJSONPreview,
                       let pretty = coordinator.actionsEngine.prettyPrintJSON(clip.content) {
                        return pretty
                    }
                    return clip.content
                }()

                VStack(alignment: .leading, spacing: 10) {
                    if clip.isSensitiveOrEphemeral {
                        Text(clip.maskedPreview)
                            .font(GhostTheme.codeFont)
                            .foregroundColor(GhostTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if (clip.primaryCategory == .code || clip.primaryCategory == .json) && coordinator.preferences.syntaxHighlightingEnabled {
                        Text(SyntaxHighlighter.highlight(previewText, language: clip.detectedLanguage, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text(previewText)
                            .font(GhostTheme.codeFont)
                            .foregroundColor(GhostTheme.textPrimary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(GhostTheme.border(scheme))

            // Quick primary action bar
            HStack(spacing: 8) {
                Button {
                    coordinator.copyAndPasteFromPalette(clip.content, markClipID: clip.id, onDismiss: onDismiss)
                } label: {
                    HStack(spacing: 4) {
                        Text(primaryReturnLabel)
                            .lineLimit(1)
                        KeycapBadge("↩")
                    }
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textPrimary(scheme))
                }
                .buttonStyle(.plain)
                .fixedSize()

                Button {
                    let plain = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    coordinator.copyAndPasteFromPalette(plain, markClipID: clip.id, onDismiss: onDismiss)
                } label: {
                    HStack(spacing: 4) {
                        Text("Plain")
                            .lineLimit(1)
                        KeycapBadge("⌘↩")
                    }
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                }
                .buttonStyle(.plain)
                .fixedSize()

                Spacer(minLength: 4)

                Button {
                    onOpenFullHistory()
                } label: {
                    Label("Workspace", systemImage: "macwindow")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.accent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(GhostTheme.surface(scheme))
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24))
                .foregroundColor(GhostTheme.textMuted(scheme))
            Text("No matching clipboard items")
                .font(GhostTheme.bodyMedium)
                .foregroundColor(GhostTheme.textSecondary(scheme))
            Text("Copy code, URLs, JSON, Markdown, or colors to capture automatically.")
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textMuted(scheme))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 7.3.5 Footer Bar & Keyboard Navigation

    private var footerBar: some View {
        let clips = filteredClips
        return ViewThatFits(in: .horizontal) {
            footerRowContent(clipsCount: clips.count, showQuickPickHint: true)
            footerRowContent(clipsCount: clips.count, showQuickPickHint: false)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(GhostTheme.surface(scheme))
    }

    private func footerRowContent(clipsCount: Int, showQuickPickHint: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    if selectedIndex > 0 { selectedIndex -= 1 }
                } label: { KeycapBadge("↑") }
                .buttonStyle(.plain)
                .keyboardShortcut(.upArrow, modifiers: [])

                Button {
                    if selectedIndex + 1 < clipsCount { selectedIndex += 1 }
                } label: { KeycapBadge("↓") }
                .buttonStyle(.plain)
                .keyboardShortcut(.downArrow, modifiers: [])

                Text("Navigate")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
            }
            .fixedSize()

            HStack(spacing: 4) {
                Button {
                    if let clip = selectedClip {
                        coordinator.copyAndPasteFromPalette(clip.content, markClipID: clip.id, onDismiss: onDismiss)
                    }
                } label: { KeycapBadge("↩") }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])

                Text(primaryReturnLabel)
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
            }
            .fixedSize()

            if showQuickPickHint {
                HStack(spacing: 4) {
                    KeycapBadge("⌘1–9")
                    Text("Quick Pick")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.textMuted(scheme))
                        .lineLimit(1)
                }
                .fixedSize()
            }

            HStack(spacing: 4) {
                Button {
                    showActionMenu.toggle()
                } label: { KeycapBadge("⌘K") }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: [.command])

                Text("Actions")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
            }
            .fixedSize()

            Spacer(minLength: 6)

            // Active Global Hotkey & Privacy status
            HStack(spacing: 6) {
                KeycapBadge(coordinator.preferences.hotkeyDisplayString)
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(GhostTheme.success)
                Text("Blind FTS • \(clipsCount) items")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                    .lineLimit(1)
            }
            .fixedSize()

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundColor(GhostTheme.textSecondary(scheme))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    // MARK: - Cmd+K Developer Action Menu Sheet

    private func actionMenuSheet(for clip: ClipItem) -> some View {
        let actions = coordinator.actionsEngine.availableActions(for: clip)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Developer Actions — \(clip.primaryCategory.displayName)")
                    .font(GhostTheme.titleFont)
                    .foregroundColor(GhostTheme.textPrimary(scheme))
                    .lineLimit(1)
                Spacer()
                Button("Close (Esc)") {
                    showActionMenu = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(GhostTheme.surface(scheme))

            Divider().overlay(GhostTheme.border(scheme))

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(actions, id: \.id) { action in
                        Button {
                            if let transformed = action.transformedContent {
                                coordinator.copyAndPasteFromPalette(transformed, markClipID: clip.id) {
                                    showActionMenu = false
                                    onDismiss()
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.iconName)
                                    .foregroundColor(action.isWarning ? GhostTheme.warning : GhostTheme.accent)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title)
                                        .font(GhostTheme.bodyMedium)
                                        .foregroundColor(GhostTheme.textPrimary(scheme))
                                        .lineLimit(1)
                                    Text(action.summaryMessage)
                                        .font(GhostTheme.metadataFont)
                                        .foregroundColor(GhostTheme.textMuted(scheme))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if action.transformedContent != nil {
                                    KeycapBadge("Copy")
                                        .fixedSize()
                                }
                            }
                            .padding(10)
                            .background(GhostTheme.elevated(scheme))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 500, height: 350)
        .background(GhostTheme.background(scheme))
        .clipped()
    }

    private func shortRelativeTime(_ date: Date) -> String {
        let diff = max(0, Int(now.timeIntervalSince(date)))
        if diff < 60 { return "\(diff)s" }
        if diff < 3600 { return "\(diff / 60)m" }
        if diff < 86_400 { return "\(diff / 3600)h" }
        return "\(diff / 86_400)d"
    }
}
