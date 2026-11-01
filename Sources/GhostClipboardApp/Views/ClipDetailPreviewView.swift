import SwiftUI
import AppKit
import GhostClipboardCore

public struct ClipDetailPreviewView: View {
    public let clip: ClipItem
    @ObservedObject public var coordinator: ClipboardCoordinator
    @Environment(\.colorScheme) private var scheme

    @State private var isRevealed: Bool = false
    @State private var showRenderedMarkdown: Bool = true
    @State private var showFormattedJSON: Bool = true
    @State private var now: Date = Date()
    @State private var lastActionFeedback: String? = nil

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(clip: ClipItem, coordinator: ClipboardCoordinator) {
        self.clip = clip
        self.coordinator = coordinator
        self._showFormattedJSON = State(initialValue: coordinator.preferences.autoFormatJSONPreview)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().overlay(GhostTheme.border(scheme))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if clip.isSensitiveOrEphemeral {
                        sensitivePreviewCard
                        if let jwt = coordinator.actionsEngine.decodeJWT(clip.content, now: now) {
                            jwtInspectorCard(jwt)
                        }
                    } else {
                        categorySpecificPreview
                        if let jwt = coordinator.actionsEngine.decodeJWT(clip.content, now: now) {
                            jwtInspectorCard(jwt)
                        }
                        if let tsInfo = coordinator.actionsEngine.parseTimestamp(clip.content) {
                            timestampInspectorCard(tsInfo)
                        }
                    }

                    metadataGridSection
                    developerActionsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GhostTheme.surface(scheme))
        .clipped()
        .onAppear {
            now = Date()
            showFormattedJSON = coordinator.preferences.autoFormatJSONPreview
        }
        .onChange(of: clip.id) { _ in
            isRevealed = false
            lastActionFeedback = nil
            showFormattedJSON = coordinator.preferences.autoFormatJSONPreview
        }
        .onChange(of: coordinator.preferences.autoFormatJSONPreview) { newValue in
            showFormattedJSON = newValue
        }
        .onChange(of: coordinator.preferences.requireAuthenticationToReveal) { req in
            if req {
                isRevealed = false
            }
        }
        .onReceive(timer) { tick in
            if clip.isEphemeral || !coordinator.ephemeralClips.isEmpty {
                now = tick
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: clip.primaryCategory.systemIconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(GhostTheme.accent)
                .frame(width: 24, height: 24)
                .background(GhostTheme.elevated(scheme))
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(clip.primaryCategory.displayName)
                        .font(GhostTheme.titleFont)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let lang = clip.detectedLanguage {
                        CategoryBadgeView(label: lang.rawValue, isHighlighted: true)
                            .fixedSize()
                    }

                    if clip.isPinned {
                        CategoryBadgeView(label: "PINNED", isHighlighted: false)
                            .fixedSize()
                    }
                }

                Text(headerSubtitle)
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Category override menu (Section 5.2)
            Menu {
                ForEach(ClipCategory.allCases) { category in
                    Button {
                        coordinator.overrideCategory(clip, to: category)
                    } label: {
                        Label(category.displayName, systemImage: category.systemIconName)
                    }
                }
            } label: {
                Label("Reclassify", systemImage: "tag")
                    .font(GhostTheme.metadataFont)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                coordinator.togglePin(clip)
            } label: {
                Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundColor(clip.isPinned ? GhostTheme.accent : GhostTheme.textSecondary(scheme))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(clip.isPinned ? "Unpin clip" : "Pin clip to prevent expiration")
            .disabled(clip.isEphemeral)

            Button {
                coordinator.copyToSystemClipboard(clip.content, markClipID: clip.id)
                lastActionFeedback = "Copied to clipboard"
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text("Copy")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(GhostTheme.darkBackground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(GhostTheme.accent)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(GhostTheme.background(scheme))
    }

    private var headerSubtitle: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let rel = formatter.localizedString(for: clip.createdAt, relativeTo: now)
        if let app = clip.sourceApplication {
            return "Captured \(rel) from \(app)"
        }
        return "Captured \(rel)"
    }

    // MARK: - Category-Specific Previews (Section 7.5.1 - 7.5.6)

    @ViewBuilder
    private var categorySpecificPreview: some View {
        switch clip.primaryCategory {
        case .hexColor:
            colorPreviewSection
        case .url:
            urlPreviewSection
        case .json:
            jsonPreviewSection
        case .markdown:
            markdownPreviewSection
        case .terminalCommand:
            terminalPreviewSection
        case .code:
            codePreviewSection
        case .otp, .credential:
            sensitivePreviewCard
        case .plainText:
            plainTextPreviewSection
        }
    }

    // 7.5.1 Code Preview
    private var codePreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(clip.detectedLanguage?.rawValue ?? "Code Snippet")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                    .lineLimit(1)
                Spacer()
                Text("\(clip.lineCount) lines • \(clip.characterCount) chars")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
            }

            let lines = clip.content.components(separatedBy: .newlines)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    // Line numbers column
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, _ in
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(GhostTheme.textMuted(scheme))
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.leading, 10)

                    Divider().overlay(GhostTheme.border(scheme))

                    // Highlighted code
                    if coordinator.preferences.syntaxHighlightingEnabled {
                        Text(SyntaxHighlighter.highlight(clip.content, language: clip.detectedLanguage, scheme: scheme))
                            .textSelection(.enabled)
                            .padding(.vertical, 10)
                            .padding(.trailing, 12)
                    } else {
                        Text(clip.content)
                            .font(GhostTheme.codeFont)
                            .foregroundColor(GhostTheme.textPrimary(scheme))
                            .textSelection(.enabled)
                            .padding(.vertical, 10)
                            .padding(.trailing, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    // 7.5.2 Color Preview
    private var colorPreviewSection: some View {
        let colorComp = clip.colorComponents ?? coordinator.classifier.parseColor(from: clip.content) ?? ColorComponents(red: 0.65, green: 0.72, blue: 1.0)
        let swiftColor = Color(red: colorComp.red, green: colorComp.green, blue: colorComp.blue, opacity: colorComp.alpha)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(swiftColor)
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(GhostTheme.border(scheme), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 6) {
                    colorValueRow(label: "HEX", value: colorComp.hexString)
                    colorValueRow(label: "RGB", value: colorComp.rgbString)
                    colorValueRow(label: "HSL", value: colorComp.hslString)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    private func colorValueRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(GhostTheme.badgeFont)
                .foregroundColor(GhostTheme.textMuted(scheme))
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(GhostTheme.codeFont)
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .lineLimit(1)
                .textSelection(.enabled)
            Button {
                coordinator.copyToSystemClipboard(value)
                lastActionFeedback = "Copied \(value)"
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(GhostTheme.textSecondary(scheme))
            }
            .buttonStyle(.plain)
        }
    }

    // 7.5.3 URL Preview
    private var urlPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if clip.isSuspiciousDomain {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(GhostTheme.warning)
                    Text("Domain safety warning: This URL uses an uncommon TLD, punycode, or embedded authority.")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GhostTheme.warning.opacity(0.12))
                .cornerRadius(4)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundColor(GhostTheme.accent)
                    Text(clip.urlHostname ?? "URL")
                        .font(GhostTheme.bodyMedium)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let url = URL(string: clip.content.trimmingCharacters(in: .whitespacesAndNewlines)),
                       let schemeStr = url.scheme?.lowercased(),
                       (schemeStr == "http" || schemeStr == "https") {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in Browser", systemImage: "arrow.up.right.square")
                                .font(GhostTheme.metadataFont)
                                .foregroundColor(GhostTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }

                Text(clip.content)
                    .font(GhostTheme.codeFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    // 7.5.4 Markdown Preview
    private var markdownPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Markdown Preview")
                    .font(GhostTheme.metadataFont)
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                    .lineLimit(1)
                Spacer()
                Picker("", selection: $showRenderedMarkdown) {
                    Text("Rendered").tag(true)
                    Text("Raw Source").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            VStack(alignment: .leading, spacing: 6) {
                if showRenderedMarkdown {
                    ForEach(Array(clip.content.components(separatedBy: .newlines).enumerated()), id: \.offset) { lineIndex, line in
                        renderedMarkdownLine(line, lineIndex: lineIndex)
                    }
                } else {
                    Text(clip.content)
                        .font(GhostTheme.codeFont)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private func renderedMarkdownLine(_ line: String, lineIndex: Int) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            Text(inlineMarkdown(String(trimmed.dropFirst(2))))
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        } else if trimmed.hasPrefix("## ") {
            Text(inlineMarkdown(String(trimmed.dropFirst(3))))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        } else if trimmed.hasPrefix("### ") {
            Text(inlineMarkdown(String(trimmed.dropFirst(4))))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(GhostTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
        } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            Button {
                toggleMarkdownCheckbox(at: lineIndex, currentlyChecked: true)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundColor(GhostTheme.success)
                    Text(inlineMarkdown(String(trimmed.dropFirst(6))))
                        .font(GhostTheme.bodyFont)
                        .foregroundColor(GhostTheme.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
        } else if trimmed.hasPrefix("- [ ] ") {
            Button {
                toggleMarkdownCheckbox(at: lineIndex, currentlyChecked: false)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "square")
                        .foregroundColor(GhostTheme.textMuted(scheme))
                    Text(inlineMarkdown(String(trimmed.dropFirst(6))))
                        .font(GhostTheme.bodyFont)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .foregroundColor(GhostTheme.accent)
                Text(inlineMarkdown(String(trimmed.dropFirst(2))))
                    .font(GhostTheme.bodyFont)
                    .foregroundColor(GhostTheme.textPrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if trimmed.hasPrefix("> ") {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(GhostTheme.accent)
                    .frame(width: 3)
                Text(inlineMarkdown(String(trimmed.dropFirst(2))))
                    .font(GhostTheme.bodyFont.italic())
                    .foregroundColor(GhostTheme.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(inlineMarkdown(line))
                .font(GhostTheme.bodyFont)
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private func toggleMarkdownCheckbox(at lineIndex: Int, currentlyChecked: Bool) {
        var lines = clip.content.components(separatedBy: .newlines)
        guard lineIndex >= 0 && lineIndex < lines.count else { return }
        if currentlyChecked {
            lines[lineIndex] = lines[lineIndex]
                .replacingOccurrences(of: "- [x] ", with: "- [ ] ")
                .replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        } else {
            lines[lineIndex] = lines[lineIndex]
                .replacingOccurrences(of: "- [ ] ", with: "- [x] ")
        }
        let updated = lines.joined(separator: "\n")
        coordinator.updateClipContent(clip, newContent: updated)
    }

    // 7.5.5 JSON Preview
    private var jsonPreviewSection: some View {
        let validation = coordinator.actionsEngine.validateJSON(clip.content)
        let displayedText: String = {
            if showFormattedJSON, let pretty = coordinator.actionsEngine.prettyPrintJSON(clip.content) {
                return pretty
            }
            return clip.content
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: validation.isValid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundColor(validation.isValid ? GhostTheme.success : GhostTheme.danger)
                    Text(validation.message)
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(validation.isValid ? GhostTheme.success : GhostTheme.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Toggle("Formatted", isOn: $showFormattedJSON)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(GhostTheme.metadataFont)
                    .fixedSize()
            }

            Group {
                if coordinator.preferences.syntaxHighlightingEnabled {
                    Text(SyntaxHighlighter.highlight(displayedText, language: .javascript, scheme: scheme))
                } else {
                    Text(displayedText)
                        .font(GhostTheme.codeFont)
                        .foregroundColor(GhostTheme.textPrimary(scheme))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    // Terminal Preview
    private var terminalPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = clip.terminalSafetyWarning ?? coordinator.classifier.evaluateTerminalSafety(clip.content) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(GhostTheme.danger)
                    Text(warning)
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GhostTheme.danger.opacity(0.12))
                .cornerRadius(4)
            }

            HStack(alignment: .top, spacing: 8) {
                Text("$")
                    .font(GhostTheme.codeFont)
                    .foregroundColor(GhostTheme.accent)
                Text(clip.content)
                    .font(GhostTheme.codeFont)
                    .foregroundColor(GhostTheme.textPrimary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    // Plain Text Preview
    private var plainTextPreviewSection: some View {
        Text(clip.content)
            .font(GhostTheme.bodyFont)
            .foregroundColor(GhostTheme.textPrimary(scheme))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
    }

    // 7.5.6 Sensitive Preview (Masked content, explicit reveal interaction, expiration countdown, no auto-reveal on hover)
    private var sensitivePreviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(GhostTheme.warning)
                Text(clip.sensitivityLevel.displayName)
                    .font(GhostTheme.bodyMedium)
                    .foregroundColor(GhostTheme.warning)
                    .lineLimit(1)
                Spacer()
                if let rem = clip.remainingSeconds(at: now) {
                    Text("Expires in \(Int(rem))s")
                        .font(GhostTheme.badgeFont)
                        .foregroundColor(GhostTheme.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(GhostTheme.danger.opacity(0.15))
                        .cornerRadius(4)
                        .fixedSize()
                }
            }

            Text(isRevealed ? clip.content : clip.maskedPreview)
                .font(GhostTheme.codeFont)
                .foregroundColor(GhostTheme.textPrimary(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GhostTheme.background(scheme))
                .cornerRadius(4)

            HStack {
                Button {
                    if isRevealed {
                        isRevealed = false
                    } else if coordinator.preferences.requireAuthenticationToReveal {
                        Task {
                            let ok = await CryptoVault.authenticateUser()
                            if ok { isRevealed = true }
                        }
                    } else {
                        isRevealed = true
                    }
                } label: {
                    Label(isRevealed ? "Conceal Secret" : "Explicitly Reveal", systemImage: isRevealed ? "eye.slash" : "eye")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    coordinator.deleteClip(clip)
                } label: {
                    Label("Purge Immediately", systemImage: "trash")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(GhostTheme.elevated(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(GhostTheme.warning.opacity(0.45), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Smart JWT Claims Inspector Card & Timestamp Card

    private func jwtInspectorCard(_ jwt: DecodedJWT) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.viewfinder")
                    .foregroundColor(GhostTheme.accent)
                Text("DECODED JWT INSPECTOR")
                    .font(GhostTheme.badgeFont)
                    .foregroundColor(GhostTheme.accent)
                    .lineLimit(1)

                if let alg = jwt.algorithm {
                    CategoryBadgeView(label: alg, isHighlighted: true)
                        .fixedSize()
                }

                if let isExp = jwt.isExpired {
                    Text(isExp ? "EXPIRED" : "VALID")
                        .font(GhostTheme.badgeFont)
                        .foregroundColor(isExp ? GhostTheme.danger : GhostTheme.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isExp ? GhostTheme.danger : GhostTheme.success).opacity(0.15))
                        .cornerRadius(4)
                        .fixedSize()
                }

                Spacer(minLength: 4)

                Button {
                    coordinator.copyToSystemClipboard(jwt.combinedFormatted, markClipID: clip.id)
                    lastActionFeedback = "Copied decoded JWT JSON"
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.accent)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    jwtCodeBlock(title: "HEADER", json: jwt.headerJSON)
                    jwtCodeBlock(title: "CLAIMS PAYLOAD", json: jwt.claimsJSON)
                }
                VStack(alignment: .leading, spacing: 10) {
                    jwtCodeBlock(title: "HEADER", json: jwt.headerJSON)
                    jwtCodeBlock(title: "CLAIMS PAYLOAD", json: jwt.claimsJSON)
                }
            }
        }
        .padding(12)
        .background(GhostTheme.background(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(GhostTheme.accent.opacity(0.4), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private func jwtCodeBlock(title: String, json: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(GhostTheme.badgeFont)
                .foregroundColor(GhostTheme.textMuted(scheme))
            Text(SyntaxHighlighter.highlight(json, language: .javascript, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GhostTheme.surface(scheme))
                .cornerRadius(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timestampInspectorCard(_ ts: TimestampInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundColor(GhostTheme.accent)
                Text("TIMESTAMP CONVERTER")
                    .font(GhostTheme.badgeFont)
                    .foregroundColor(GhostTheme.accent)
                    .lineLimit(1)
                Spacer()
                Button {
                    coordinator.copyToSystemClipboard(ts.iso8601UTC, markClipID: clip.id)
                    lastActionFeedback = "Copied \(ts.iso8601UTC)"
                } label: {
                    Label("Copy ISO-8601", systemImage: "doc.on.doc")
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.accent)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }

            metadataRow("UTC Time", value: ts.humanUTC)
            metadataRow("Local Time", value: ts.humanLocal)
            metadataRow("ISO-8601", value: ts.iso8601UTC)
            metadataRow("Unix Epoch", value: "\(ts.epochSeconds)s (\(ts.epochMilliseconds)ms)")
        }
        .padding(12)
        .background(GhostTheme.background(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(GhostTheme.accent.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Inspector Metadata Grid (Section 7.4)

    private var metadataGridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INSPECTOR METADATA")
                .font(GhostTheme.badgeFont)
                .foregroundColor(GhostTheme.textMuted(scheme))

            VStack(spacing: 6) {
                metadataRow("Source Application", value: clip.sourceApplication ?? "System Clipboard")
                metadataRow("Classification", value: ([clip.primaryCategory.displayName] + clip.secondaryCategories.map(\.displayName)).joined(separator: " • "))
                if let lang = clip.detectedLanguage {
                    metadataRow("Detected Language", value: lang.rawValue)
                }
                metadataRow("Dimensions", value: "\(clip.characterCount) chars • \(clip.lineCount) lines • \(clip.byteSize) bytes")
                metadataRow("Sensitivity Policy", value: clip.sensitivityLevel.displayName)
                metadataRow("Retention Policy", value: retentionDescription)
            }
            .padding(12)
            .background(GhostTheme.background(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    private var retentionDescription: String {
        if clip.isPinned {
            return "Pinned (Exempt from automatic expiration)"
        }
        if let rem = clip.remainingSeconds(at: now) {
            if rem < 3600 {
                return "Ephemeral — Deletes in \(Int(rem)) seconds"
            }
            let days = Int(ceil(rem / 86_400))
            return "Expires in \(days) day(s) (Encrypted at rest)"
        }
        return "Standard retention"
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textMuted(scheme))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(GhostTheme.metadataFont)
                .foregroundColor(GhostTheme.textSecondary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }

    // MARK: - Developer Actions Section (Section 11)

    private var developerActionsSection: some View {
        let actions = coordinator.actionsEngine.availableActions(for: clip)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("DEVELOPER ACTIONS")
                    .font(GhostTheme.badgeFont)
                    .foregroundColor(GhostTheme.textMuted(scheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let feedback = lastActionFeedback {
                    Text(feedback)
                        .font(GhostTheme.metadataFont)
                        .foregroundColor(GhostTheme.success)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }

            VStack(spacing: 6) {
                ForEach(actions, id: \.id) { action in
                    HStack(spacing: 10) {
                        Image(systemName: action.iconName)
                            .font(.system(size: 12))
                            .foregroundColor(action.isWarning ? GhostTheme.warning : GhostTheme.accent)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(GhostTheme.bodyMedium)
                                .foregroundColor(action.isWarning ? GhostTheme.warning : GhostTheme.textPrimary(scheme))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(action.summaryMessage)
                                .font(GhostTheme.metadataFont)
                                .foregroundColor(GhostTheme.textMuted(scheme))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let transformed = action.transformedContent {
                            Button {
                                coordinator.copyToSystemClipboard(transformed, markClipID: clip.id)
                                lastActionFeedback = "Applied & copied: \(action.title)"
                            } label: {
                                Text("Copy Result")
                                    .font(GhostTheme.metadataFont)
                                    .foregroundColor(GhostTheme.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(GhostTheme.elevated(scheme))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    .padding(10)
                    .background(GhostTheme.background(scheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(GhostTheme.border(scheme), lineWidth: 1)
                    )
                    .cornerRadius(6)
                }
            }
        }
    }
}
