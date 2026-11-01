import SwiftUI
import AppKit
import GhostClipboardCore

/// Section 8: Visual Design System
/// Precision developer utility tokens. No gradient hero sections, no rainbow category badges, no decorative AI sparkles.
public enum GhostTheme {
    // Dark Theme Tokens (Section 8.2)
    public static let darkBackground = Color(red: 0x10 / 255.0, green: 0x11 / 255.0, blue: 0x14 / 255.0) // #101114
    public static let darkSurface    = Color(red: 0x18 / 255.0, green: 0x1A / 255.0, blue: 0x20 / 255.0) // #181A20
    public static let darkElevated   = Color(red: 0x20 / 255.0, green: 0x23 / 255.0, blue: 0x2B / 255.0) // #20232B
    public static let darkBorder     = Color(red: 0x30 / 255.0, green: 0x34 / 255.0, blue: 0x3D / 255.0) // #30343D

    public static let darkTextPrimary   = Color(red: 0xF1 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0) // #F1F2F5
    public static let darkTextSecondary = Color(red: 0xA1 / 255.0, green: 0xA5 / 255.0, blue: 0xB0 / 255.0) // #A1A5B0
    public static let darkTextMuted     = Color(red: 0x72 / 255.0, green: 0x78 / 255.0, blue: 0x87 / 255.0) // #727887

    // Light Theme Tokens (Section 8.3)
    public static let lightBackground = Color(red: 0xF7 / 255.0, green: 0xF6 / 255.0, blue: 0xF2 / 255.0) // Warm off-white #F7F6F2
    public static let lightSurface    = Color(red: 0xEE / 255.0, green: 0xEF / 255.0, blue: 0xF2 / 255.0) // Neutral gray #EEEFF2
    public static let lightElevated   = Color(red: 0xE4 / 255.0, green: 0xE6 / 255.0, blue: 0xEB / 255.0) // #E4E6EB
    public static let lightBorder     = Color(red: 0xD4 / 255.0, green: 0xD7 / 255.0, blue: 0xDF / 255.0) // #D4D7DF

    public static let lightTextPrimary   = Color(red: 0x18 / 255.0, green: 0x1A / 255.0, blue: 0x1F / 255.0)
    public static let lightTextSecondary = Color(red: 0x4A / 255.0, green: 0x4F / 255.0, blue: 0x5C / 255.0)
    public static let lightTextMuted     = Color(red: 0x76 / 255.0, green: 0x7C / 255.0, blue: 0x8C / 255.0)

    // Semantic Accent & Status Tokens (Section 8.2)
    public static let accent  = Color(red: 0xA6 / 255.0, green: 0xB7 / 255.0, blue: 0xFF / 255.0) // #A6B7FF
    public static let accentStrong = Color(red: 0x52 / 255.0, green: 0x6D / 255.0, blue: 0xE8 / 255.0)
    public static let success = Color(red: 0x65 / 255.0, green: 0xC9 / 255.0, blue: 0x9A / 255.0) // #65C99A
    public static let warning = Color(red: 0xE8 / 255.0, green: 0xB6 / 255.0, blue: 0x6A / 255.0) // #E8B66A
    public static let danger  = Color(red: 0xE7 / 255.0, green: 0x7D / 255.0, blue: 0x83 / 255.0) // #E77D83

    // Typography (Section 8.4)
    public static let titleFont    = Font.system(size: 15, weight: .semibold, design: .default)
    public static let bodyFont     = Font.system(size: 13, weight: .regular, design: .default)
    public static let bodyMedium   = Font.system(size: 13, weight: .medium, design: .default)
    public static let metadataFont = Font.system(size: 11, weight: .regular, design: .default)
    public static let badgeFont    = Font.system(size: 10, weight: .semibold, design: .monospaced)
    public static let codeFont     = Font.system(size: 12, weight: .regular, design: .monospaced)

    // Dynamic resolvers based on ColorScheme
    public static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }

    public static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkSurface : lightSurface
    }

    public static func elevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkElevated : lightElevated
    }

    public static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBorder : lightBorder
    }

    public static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkTextPrimary : lightTextPrimary
    }

    public static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkTextSecondary : lightTextSecondary
    }

    public static func textMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkTextMuted : lightTextMuted
    }
}

public extension GhostPreferences {
    var resolvedColorScheme: ColorScheme? {
        switch themeMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

// MARK: - Syntax Highlighting Helper for Code & JSON Previews

public enum SyntaxHighlighter {
    public static func highlight(_ code: String, language: ProgrammingLanguage?, scheme: ColorScheme) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.font = .system(size: 12, weight: .regular, design: .monospaced)
        attributed.foregroundColor = GhostTheme.textPrimary(scheme)

        // Highlight strings, keywords, comments, numbers cleanly with restrained developer palette
        let keywordPattern = #"\b(?:func|let|var|struct|class|enum|protocol|extension|import|return|if|else|guard|switch|case|default|for|while|in|try|catch|throw|throws|async|await|public|private|internal|static|final|const|function|interface|type|export|from|def|None|True|False|self|fn|mut|pub|impl|match|use|package|go|defer|chan|select|WHERE|SELECT|FROM|INSERT|UPDATE|DELETE|JOIN|ORDER|GROUP|BY|CREATE|TABLE)\b"#

        applyPattern(keywordPattern, to: &attributed, in: code, color: GhostTheme.accent)
        applyPattern(#"\b[0-9]+(?:\.[0-9]+)?\b"#, to: &attributed, in: code, color: GhostTheme.warning)
        applyPattern(#""[^"\n]*""#, to: &attributed, in: code, color: GhostTheme.success)
        applyPattern(#"'[^'\n]*'"#, to: &attributed, in: code, color: GhostTheme.success)
        applyPattern(#"(?m)//.*$|#.*$"#, to: &attributed, in: code, color: GhostTheme.textMuted(scheme))

        return attributed
    }

    private static func applyPattern(_ pattern: String, to attributed: inout AttributedString, in source: String, color: Color) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)
        for match in matches.prefix(250) {
            if let swiftRange = Range(match.range, in: source),
               let attrRange = Range(swiftRange, in: attributed) {
                attributed[attrRange].foregroundColor = color
            }
        }
    }
}

// MARK: - Reusable Restrained Components

public struct KeycapBadge: View {
    public let text: String
    @Environment(\.colorScheme) private var scheme

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(GhostTheme.textSecondary(scheme))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(GhostTheme.elevated(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(4)
    }
}

public struct CategoryBadgeView: View {
    public let label: String
    public var isHighlighted: Bool = false
    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        Text(label)
            .font(GhostTheme.badgeFont)
            .foregroundColor(isHighlighted ? GhostTheme.accent : GhostTheme.textSecondary(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isHighlighted ? GhostTheme.accent.opacity(0.14) : GhostTheme.elevated(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHighlighted ? GhostTheme.accent.opacity(0.35) : GhostTheme.border(scheme), lineWidth: 1)
            )
            .cornerRadius(4)
    }
}
