import Foundation

public struct DeveloperActionResult: Equatable, Sendable {
    public let id: String
    public let title: String
    public let iconName: String
    public let transformedContent: String?
    public let summaryMessage: String
    public let isWarning: Bool

    public init(
        id: String,
        title: String,
        iconName: String,
        transformedContent: String? = nil,
        summaryMessage: String,
        isWarning: Bool = false
    ) {
        self.id = id
        self.title = title
        self.iconName = iconName
        self.transformedContent = transformedContent
        self.summaryMessage = summaryMessage
        self.isWarning = isWarning
    }
}

public final class DeveloperActionsEngine: Sendable {

    private let classifier = ContentClassificationEngine()

    public init() {}

    // MARK: - Contextual Actions for a Clip

    public func availableActions(for clip: ClipItem) -> [DeveloperActionResult] {
        var actions: [DeveloperActionResult] = []

        switch clip.primaryCategory {
        case .json:
            actions.append(contentsOf: jsonActions(for: clip.content))
        case .url:
            actions.append(contentsOf: urlActions(for: clip.content))
        case .hexColor:
            actions.append(contentsOf: colorActions(for: clip))
        case .code:
            actions.append(contentsOf: codeActions(for: clip.content))
        case .markdown:
            actions.append(contentsOf: markdownActions(for: clip.content))
        case .terminalCommand:
            actions.append(contentsOf: terminalActions(for: clip.content))
        case .otp, .credential, .plainText:
            actions.append(contentsOf: codeActions(for: clip.content))
        }

        return actions
    }

    // MARK: - 11.1 Code Actions

    public func codeActions(for text: String) -> [DeveloperActionResult] {
        var results: [DeveloperActionResult] = []

        // 1. Copy plain text (trimmed)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        results.append(DeveloperActionResult(
            id: "code.copy_plain",
            title: "Copy Trimmed Plain Text",
            iconName: "doc.on.doc",
            transformedContent: trimmed,
            summaryMessage: "Trimmed leading/trailing whitespace (\(trimmed.count) chars)"
        ))

        // 2. Strip leading line numbers (e.g. "1: ", "  12 | ", "1. ")
        let strippedLines = stripLineNumbers(from: text)
        if strippedLines != text {
            results.append(DeveloperActionResult(
                id: "code.strip_line_numbers",
                title: "Strip Line Numbers",
                iconName: "list.number",
                transformedContent: strippedLines,
                summaryMessage: "Removed line number prefixes from snippet"
            ))
        }

        // 3. Normalize indentation & strip trailing whitespace
        let normalized = normalizeCodeFormatting(text)
        results.append(DeveloperActionResult(
            id: "code.format_indentation",
            title: "Format Indentation & Strip Trailing Spaces",
            iconName: "text.alignleft",
            transformedContent: normalized,
            summaryMessage: "Dedent common leading spaces and strip trailing whitespace"
        ))

        // 4. Inspect line statistics
        let stats = inspectLineStatistics(text)
        results.append(DeveloperActionResult(
            id: "code.line_stats",
            title: "Inspect Line Statistics",
            iconName: "chart.bar.doc.horizontal",
            transformedContent: nil,
            summaryMessage: stats
        ))

        return results
    }

    public func stripLineNumbers(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let regex = try? NSRegularExpression(pattern: #"^\s*[0-9]+(?:\s*[:|\t]\s?|\.\s+)"#) else {
            return text
        }
        let transformed = lines.map { line -> String in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
        }
        return transformed.joined(separator: "\n")
    }

    public func normalizeCodeFormatting(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let minIndent = nonEmptyLines.map { line -> Int in
            line.prefix(while: { $0 == " " }).count
        }.min() ?? 0

        let dedented = lines.map { line -> String in
            let withoutIndent = line.count >= minIndent ? String(line.dropFirst(minIndent)) : line
            return withoutIndent.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        return dedented.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    public func inspectLineStatistics(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let bytes = text.utf8.count
        return "\(lines.count) lines (\(nonEmpty) non-empty) • \(words) words • \(text.count) chars • \(bytes) bytes"
    }

    // MARK: - 11.2 JSON Actions

    public func jsonActions(for text: String) -> [DeveloperActionResult] {
        var results: [DeveloperActionResult] = []
        let validation = validateJSON(text)

        results.append(DeveloperActionResult(
            id: "json.validate",
            title: validation.isValid ? "Valid JSON" : "Invalid JSON",
            iconName: validation.isValid ? "checkmark.seal" : "exclamationmark.triangle",
            transformedContent: nil,
            summaryMessage: validation.message,
            isWarning: !validation.isValid
        ))

        if let pretty = prettyPrintJSON(text, sortKeys: false) {
            results.append(DeveloperActionResult(
                id: "json.pretty",
                title: "Pretty-Print JSON",
                iconName: "text.alignleft",
                transformedContent: pretty,
                summaryMessage: "Formatted with 2-space indentation"
            ))
        }

        if let sorted = prettyPrintJSON(text, sortKeys: true) {
            results.append(DeveloperActionResult(
                id: "json.sort_keys",
                title: "Sort Keys Alphabetically",
                iconName: "arrow.up.arrow.down",
                transformedContent: sorted,
                summaryMessage: "Sorted all JSON object keys alphabetically"
            ))
        }

        if let minified = minifyJSON(text) {
            results.append(DeveloperActionResult(
                id: "json.minify",
                title: "Minify JSON",
                iconName: "arrow.down.right.and.arrow.up.left",
                transformedContent: minified,
                summaryMessage: "Minified to \(minified.count) characters"
            ))
        }

        let keys = extractJSONKeys(text)
        if !keys.isEmpty {
            results.append(DeveloperActionResult(
                id: "json.copy_keys",
                title: "Copy Top-Level Keys (\(keys.count))",
                iconName: "key",
                transformedContent: keys.joined(separator: ", "),
                summaryMessage: "Keys: \(keys.prefix(8).joined(separator: ", "))"
            ))
        }

        return results
    }

    public func prettyPrintJSON(_ text: String, sortKeys: Bool = false) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes]
        if sortKeys {
            options.insert(.sortedKeys)
        }
        guard let outData = try? JSONSerialization.data(withJSONObject: obj, options: options),
              let formatted = String(data: outData, encoding: .utf8) else {
            return nil
        }
        return formatted
    }

    public func minifyJSON(_ text: String) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let outData = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let minified = String(data: outData, encoding: .utf8) else {
            return nil
        }
        return minified
    }

    public func validateJSON(_ text: String) -> (isValid: Bool, message: String) {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            return (false, "Invalid UTF-8 encoding")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let dict = obj as? [String: Any] {
                return (true, "Valid JSON Object with \(dict.count) top-level keys")
            } else if let arr = obj as? [Any] {
                return (true, "Valid JSON Array with \(arr.count) elements")
            }
            return (true, "Valid JSON fragment")
        } catch let error as NSError {
            return (false, error.localizedDescription)
        }
    }

    public func extractJSONKeys(_ text: String) -> [String] {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return dict.keys.sorted()
    }

    // MARK: - 11.3 Markdown Actions

    public func markdownActions(for text: String) -> [DeveloperActionResult] {
        var actions: [DeveloperActionResult] = []

        actions.append(DeveloperActionResult(
            id: "md.copy_raw",
            title: "Copy Raw Markdown",
            iconName: "doc.plaintext",
            transformedContent: text,
            summaryMessage: "Raw Markdown source (\(text.count) chars)"
        ))

        let plain = stripMarkdownFormatting(text)
        actions.append(DeveloperActionResult(
            id: "md.copy_plain",
            title: "Copy Stripped Plain Text",
            iconName: "text.justifyleft",
            transformedContent: plain,
            summaryMessage: "Removed Markdown formatting syntax"
        ))

        let htmlLinks = convertMarkdownLinksToHTML(text)
        if htmlLinks != text {
            actions.append(DeveloperActionResult(
                id: "md.convert_links_html",
                title: "Convert Links to HTML <a> Tags",
                iconName: "chevron.left.forwardslash.chevron.right",
                transformedContent: htmlLinks,
                summaryMessage: "Converted [label](url) links to HTML anchor tags"
            ))
        }

        let headings = extractMarkdownHeadings(text)
        if !headings.isEmpty {
            actions.append(DeveloperActionResult(
                id: "md.inspect_headings",
                title: "Copy Document Outline (\(headings.count) headings)",
                iconName: "list.bullet.indent",
                transformedContent: headings.joined(separator: "\n"),
                summaryMessage: headings.prefix(4).joined(separator: " • ")
            ))
        }

        return actions
    }

    public func stripMarkdownFormatting(_ text: String) -> String {
        var result = text
        // Convert [label](url) -> label (url)
        if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = linkRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1 ($2)")
        }
        // Strip heading hashes
        if let headingRegex = try? NSRegularExpression(pattern: #"(?m)^#{1,6}\s+"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = headingRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Strip bold/italic/code markers
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func convertMarkdownLinksToHTML(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^)]+)\)"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: #"<a href="$2">$1</a>"#
        )
    }

    public func extractMarkdownHeadings(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") }
    }

    // MARK: - 11.4 URL Actions

    public static let trackingParameters: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "fbclid", "gclid", "dclid", "msclkid", "twclid", "igshid", "mc_cid", "mc_eid",
        "_hsenc", "_hsmi", "hsCtaTracking", "vero_id", "oly_enc_id", "oly_anon_id", "rb_clickid", "s_kwcid"
    ]

    public func urlActions(for text: String) -> [DeveloperActionResult] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var actions: [DeveloperActionResult] = []

        let cleaned = removeTrackingParameters(from: trimmed)
        if cleaned != trimmed {
            actions.append(DeveloperActionResult(
                id: "url.clean_tracking",
                title: "Remove Tracking Parameters",
                iconName: "sparkles.rectangle.stack",
                transformedContent: cleaned,
                summaryMessage: "Clean URL: \(cleaned)"
            ))
        }

        if let components = URLComponents(string: trimmed) {
            if let host = components.host, !host.isEmpty {
                actions.append(DeveloperActionResult(
                    id: "url.copy_host",
                    title: "Copy Hostname (\(host))",
                    iconName: "globe",
                    transformedContent: host,
                    summaryMessage: "Hostname: \(host)"
                ))
            }
            if !components.path.isEmpty && components.path != "/" {
                actions.append(DeveloperActionResult(
                    id: "url.copy_path",
                    title: "Copy Path (\(components.path))",
                    iconName: "point.topleft.down.curvedto.point.bottomright.up",
                    transformedContent: components.path,
                    summaryMessage: "Path: \(components.path)"
                ))
            }
            let summary = inspectURLComponents(components)
            actions.append(DeveloperActionResult(
                id: "url.inspect",
                title: "Inspect URL Components",
                iconName: "magnifyingglass",
                transformedContent: nil,
                summaryMessage: summary
            ))
        }

        return actions
    }

    public func removeTrackingParameters(from urlString: String) -> String {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let items = components.queryItems, !items.isEmpty else {
            return urlString
        }

        let filtered = items.filter { item in
            let lower = item.name.lowercased()
            return !Self.trackingParameters.contains(lower) && !lower.hasPrefix("utm_")
        }

        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }

    private func inspectURLComponents(_ components: URLComponents) -> String {
        var parts: [String] = []
        if let scheme = components.scheme { parts.append("scheme: \(scheme)") }
        if let host = components.host { parts.append("host: \(host)") }
        if let port = components.port { parts.append("port: \(port)") }
        if !components.path.isEmpty { parts.append("path: \(components.path)") }
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            parts.append("query params: \(queryItems.count)")
        }
        return parts.joined(separator: " • ")
    }

    // MARK: - 11.5 Color Actions

    public func colorActions(for clip: ClipItem) -> [DeveloperActionResult] {
        guard let color = clip.colorComponents ?? classifier.parseColor(from: clip.content) else {
            return []
        }

        return [
            DeveloperActionResult(
                id: "color.copy_hex",
                title: "Copy HEX (\(color.hexString))",
                iconName: "number",
                transformedContent: color.hexString,
                summaryMessage: color.hexString
            ),
            DeveloperActionResult(
                id: "color.copy_rgb",
                title: "Copy RGB (\(color.rgbString))",
                iconName: "slider.horizontal.3",
                transformedContent: color.rgbString,
                summaryMessage: color.rgbString
            ),
            DeveloperActionResult(
                id: "color.copy_hsl",
                title: "Copy HSL (\(color.hslString))",
                iconName: "circle.lefthalf.filled",
                transformedContent: color.hslString,
                summaryMessage: color.hslString
            )
        ]
    }

    // MARK: - 11.6 Terminal Actions

    public func terminalActions(for text: String) -> [DeveloperActionResult] {
        var actions: [DeveloperActionResult] = []

        if let warning = classifier.evaluateTerminalSafety(text) {
            actions.append(DeveloperActionResult(
                id: "terminal.safety_warning",
                title: "Safety Warning",
                iconName: "exclamationmark.triangle.fill",
                transformedContent: nil,
                summaryMessage: warning,
                isWarning: true
            ))
        }

        // Single-line command flatten (joins backslash line continuations)
        let singleLine = text
            .replacingOccurrences(of: "\\\n", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line -> String in
                if line.hasPrefix("$ ") { return String(line.dropFirst(2)) }
                return line
            }
            .joined(separator: " && ")

        actions.append(DeveloperActionResult(
            id: "terminal.copy_clean",
            title: "Copy Executable Command (Strip $ Prompt)",
            iconName: "terminal",
            transformedContent: singleLine,
            summaryMessage: singleLine
        ))

        let structure = inspectCommandStructure(text)
        actions.append(DeveloperActionResult(
            id: "terminal.inspect",
            title: "Inspect Command Structure",
            iconName: "info.circle",
            transformedContent: nil,
            summaryMessage: structure
        ))

        return actions
    }

    public func inspectCommandStructure(_ text: String) -> String {
        let pipeCount = text.components(separatedBy: "|").count - 1
        let chainCount = text.components(separatedBy: "&&").count - 1
        let usesSudo = text.contains("sudo ")
        var details: [String] = []
        if usesSudo { details.append("Requires elevated privileges (sudo)") }
        if pipeCount > 0 { details.append("\(pipeCount) pipeline stage(s)") }
        if chainCount > 0 { details.append("\(chainCount + 1) chained commands") }
        if details.isEmpty { details.append("Standard single command execution") }
        return details.joined(separator: " • ")
    }
}
