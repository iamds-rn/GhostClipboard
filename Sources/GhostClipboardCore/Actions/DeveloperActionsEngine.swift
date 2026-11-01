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

public struct DecodedJWT: Equatable, Sendable {
    public let headerJSON: String
    public let claimsJSON: String
    public let combinedFormatted: String
    public let algorithm: String?
    public let subject: String?
    public let issuer: String?
    public let issuedAt: Date?
    public let expiresAt: Date?
    public let isExpired: Bool?

    public init(
        headerJSON: String,
        claimsJSON: String,
        combinedFormatted: String,
        algorithm: String?,
        subject: String?,
        issuer: String?,
        issuedAt: Date?,
        expiresAt: Date?,
        isExpired: Bool?
    ) {
        self.headerJSON = headerJSON
        self.claimsJSON = claimsJSON
        self.combinedFormatted = combinedFormatted
        self.algorithm = algorithm
        self.subject = subject
        self.issuer = issuer
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.isExpired = isExpired
    }
}

public struct TimestampInfo: Equatable, Sendable {
    public let date: Date
    public let epochSeconds: Int64
    public let epochMilliseconds: Int64
    public let iso8601UTC: String
    public let humanUTC: String
    public let humanLocal: String

    public init(
        date: Date,
        epochSeconds: Int64,
        epochMilliseconds: Int64,
        iso8601UTC: String,
        humanUTC: String,
        humanLocal: String
    ) {
        self.date = date
        self.epochSeconds = epochSeconds
        self.epochMilliseconds = epochMilliseconds
        self.iso8601UTC = iso8601UTC
        self.humanUTC = humanUTC
        self.humanLocal = humanLocal
    }
}

public final class DeveloperActionsEngine: Sendable {

    private let classifier = ContentClassificationEngine()

    public init() {}

    // MARK: - Contextual Actions for a Clip

    public func availableActions(for clip: ClipItem) -> [DeveloperActionResult] {
        var actions: [DeveloperActionResult] = []

        // 1. Check JWT Inspector first (can appear in .credential, .plainText, or .code)
        if let jwt = decodeJWT(clip.content) {
            let expSummary: String
            if let isExp = jwt.isExpired {
                expSummary = isExp ? "EXPIRED JWT" : "Active JWT"
            } else {
                expSummary = "Decoded JWT"
            }
            actions.append(DeveloperActionResult(
                id: "jwt.decode",
                title: "Decode JWT (Header & Claims)",
                iconName: "key.viewfinder",
                transformedContent: jwt.combinedFormatted,
                summaryMessage: "\(expSummary) • alg: \(jwt.algorithm ?? "unknown") • sub: \(jwt.subject ?? "n/a")",
                isWarning: jwt.isExpired == true
            ))
        }

        // 2. Check Timestamp Inspector (10/13 digit Unix epoch or ISO-8601)
        if let ts = parseTimestamp(clip.content) {
            actions.append(DeveloperActionResult(
                id: "timestamp.to_iso8601",
                title: "Convert Timestamp to ISO-8601 UTC",
                iconName: "clock.badge.checkmark",
                transformedContent: ts.iso8601UTC,
                summaryMessage: "\(ts.humanUTC) • Local: \(ts.humanLocal)"
            ))
            actions.append(DeveloperActionResult(
                id: "timestamp.to_epoch",
                title: "Copy Unix Epoch Seconds (\(ts.epochSeconds))",
                iconName: "number.square",
                transformedContent: "\(ts.epochSeconds)",
                summaryMessage: "\(ts.epochSeconds)s (\(ts.epochMilliseconds)ms)"
            ))
        }

        // 3. Category-specific primary actions
        switch clip.primaryCategory {
        case .json:
            actions.append(contentsOf: jsonActions(for: clip.content))
            let fenced = formatAsMarkdownCodeFence(clip.content, language: nil, category: .json)
            actions.append(DeveloperActionResult(
                id: "code.copy_markdown_fence",
                title: "Copy as Markdown Code Fence (```json)",
                iconName: "curlybraces.square",
                transformedContent: fenced,
                summaryMessage: "Wrapped JSON in ```json fenced block"
            ))
        case .url:
            actions.append(contentsOf: urlActions(for: clip.content))
        case .hexColor:
            actions.append(contentsOf: colorActions(for: clip))
        case .code:
            actions.append(contentsOf: codeActions(for: clip.content, language: clip.detectedLanguage))
        case .markdown:
            actions.append(contentsOf: markdownActions(for: clip.content))
        case .terminalCommand:
            actions.append(contentsOf: terminalActions(for: clip.content))
        case .otp, .credential, .plainText:
            actions.append(contentsOf: codeActions(for: clip.content, language: clip.detectedLanguage))
        }

        // 4. Base64 Decode / Encode actions
        if decodeJWT(clip.content) == nil, let decodedB64 = base64Decode(clip.content) {
            actions.append(DeveloperActionResult(
                id: "base64.decode",
                title: "Base64 Decode to UTF-8",
                iconName: "lock.open.rotation",
                transformedContent: decodedB64,
                summaryMessage: "Decoded: \(String(decodedB64.prefix(80)))"
            ))
        }

        let trimmed = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.count <= 4096 {
            let encoded = base64Encode(trimmed)
            actions.append(DeveloperActionResult(
                id: "base64.encode",
                title: "Base64 Encode",
                iconName: "number.circle",
                transformedContent: encoded,
                summaryMessage: "Base64 (\(encoded.count) chars)"
            ))
        }

        return actions
    }

    // MARK: - 11.1 Code Actions & Markdown Code Fence

    public func codeActions(for text: String, language: ProgrammingLanguage? = nil) -> [DeveloperActionResult] {
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

        // 2. Copy as Markdown Code Fence (```lang ... ```)
        let fenceLang = markdownFenceTag(for: language, category: .code)
        let fenced = formatAsMarkdownCodeFence(trimmed, language: language, category: .code)
        results.append(DeveloperActionResult(
            id: "code.copy_markdown_fence",
            title: "Copy as Markdown Code Fence (```\(fenceLang))",
            iconName: "chevron.left.forwardslash.chevron.right",
            transformedContent: fenced,
            summaryMessage: "Wrapped snippet in ```\(fenceLang) ... ```"
        ))

        // 3. Strip leading line numbers (e.g. "1: ", "  12 | ", "1. ")
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

        // 4. Normalize indentation & strip trailing whitespace
        let normalized = normalizeCodeFormatting(text)
        results.append(DeveloperActionResult(
            id: "code.format_indentation",
            title: "Format Indentation & Strip Trailing Spaces",
            iconName: "text.alignleft",
            transformedContent: normalized,
            summaryMessage: "Dedent common leading spaces and strip trailing whitespace"
        ))

        // 5. Inspect line statistics
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

    public func formatAsMarkdownCodeFence(_ text: String, language: ProgrammingLanguage? = nil, category: ClipCategory = .code) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = markdownFenceTag(for: language, category: category)
        return "```\(tag)\n\(trimmed)\n```"
    }

    private func markdownFenceTag(for language: ProgrammingLanguage?, category: ClipCategory) -> String {
        if category == .json { return "json" }
        if category == .terminalCommand { return "bash" }
        guard let language = language else { return "" }
        switch language {
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .python: return "python"
        case .rust: return "rust"
        case .go: return "go"
        case .java: return "java"
        case .c: return "c"
        case .cpp: return "cpp"
        case .swift: return "swift"
        case .kotlin: return "kotlin"
        case .ruby: return "ruby"
        case .php: return "php"
        case .sql: return "sql"
        case .html: return "html"
        case .css: return "css"
        case .shell: return "bash"
        case .powershell: return "powershell"
        }
    }

    public func stripLineNumbers(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let pattern = #"^\s*[0-9]+(?:\s*[:|\t]\s?|\.\s+)"#
        let transformed = lines.map { line -> String in
            RegexCache.shared.replace(line, pattern: pattern, with: "")
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
            return RegexCache.shared.replace(withoutIndent, pattern: #"\s+$"#, with: "")
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
        result = RegexCache.shared.replace(result, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)")
        result = RegexCache.shared.replace(result, pattern: #"(?m)^#{1,6}\s+"#, with: "")
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func convertMarkdownLinksToHTML(_ text: String) -> String {
        RegexCache.shared.replace(
            text,
            pattern: #"\[([^\]]+)\]\((https?://[^)]+)\)"#,
            with: #"<a href="$2">$1</a>"#
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

    // MARK: - 11.6 Terminal Actions & cURL -> Code Converters

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

        if let fetchCode = convertCurlToJSFetch(text) {
            actions.append(DeveloperActionResult(
                id: "curl.to_fetch",
                title: "Convert cURL to JS fetch()",
                iconName: "network",
                transformedContent: fetchCode,
                summaryMessage: "JavaScript async fetch() request snippet"
            ))
        }

        if let swiftCode = convertCurlToSwiftURLRequest(text) {
            actions.append(DeveloperActionResult(
                id: "curl.to_swift",
                title: "Convert cURL to Swift URLRequest",
                iconName: "swift",
                transformedContent: swiftCode,
                summaryMessage: "Swift Foundation URLRequest + URLSession snippet"
            ))
        }

        let fenced = formatAsMarkdownCodeFence(singleLine, language: .shell, category: .terminalCommand)
        actions.append(DeveloperActionResult(
            id: "code.copy_markdown_fence",
            title: "Copy as Markdown Code Fence (```bash)",
            iconName: "chevron.left.forwardslash.chevron.right",
            transformedContent: fenced,
            summaryMessage: "Wrapped command in ```bash fenced block"
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

    // MARK: - 11.7 JWT Decoder & Base64 Tools

    public func decodeJWT(_ text: String, now: Date = Date()) -> DecodedJWT? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("authorization:") {
            cleaned = String(cleaned.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.lowercased().hasPrefix("bearer ") {
            cleaned = String(cleaned.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }

        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0].hasPrefix("eyJ"),
              parts[1].hasPrefix("eyJ"),
              let headerData = decodeBase64URLToData(parts[0]),
              let claimsData = decodeBase64URLToData(parts[1]),
              let headerObj = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claimsObj = (try? JSONSerialization.jsonObject(with: claimsData)) as? [String: Any] else {
            return nil
        }

        let headerPretty = formatJSONObject(headerObj) ?? "{}"
        let claimsPretty = formatJSONObject(claimsObj) ?? "{}"
        let combinedObj: [String: Any] = [
            "header": headerObj,
            "claims": claimsObj,
            "signature": parts[2]
        ]
        let combinedPretty = formatJSONObject(combinedObj) ?? "{\n  \"header\": \(headerPretty),\n  \"claims\": \(claimsPretty)\n}"

        let alg = headerObj["alg"] as? String
        let sub = claimsObj["sub"] as? String
        let iss = claimsObj["iss"] as? String
        let iatDate = (claimsObj["iat"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let expDate = (claimsObj["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let isExpired = expDate.map { now >= $0 }

        return DecodedJWT(
            headerJSON: headerPretty,
            claimsJSON: claimsPretty,
            combinedFormatted: combinedPretty,
            algorithm: alg,
            subject: sub,
            issuer: iss,
            issuedAt: iatDate,
            expiresAt: expDate,
            isExpired: isExpired
        )
    }

    public func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    public func base64Decode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              RegexCache.shared.matches(trimmed, pattern: #"^[A-Za-z0-9+/_-]+={0,2}$"#) else {
            return nil
        }
        // Avoid treating plain English words without digits/padding/uppercase mix as Base64 unless padded or >= 12 chars
        if !trimmed.hasSuffix("=") && trimmed.count < 12 && trimmed.allSatisfy({ $0.isLetter }) {
            return nil
        }
        guard let data = decodeBase64URLToData(trimmed),
              !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Verify printable UTF-8 (no control characters except newline/tab/carriage return)
        let isPrintable = decoded.unicodeScalars.allSatisfy { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 || (scalar.value >= 32 && scalar.value != 127)
        }
        return isPrintable ? decoded : nil
    }

    private func decodeBase64URLToData(_ input: String) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private func formatJSONObject(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 11.8 cURL -> JS fetch() & Swift URLRequest Converters

    private struct ParsedCurlCommand {
        var url: String
        var method: String
        var headers: [(String, String)]
        var body: String?
    }

    private func parseCurlCommand(_ text: String) -> ParsedCurlCommand? {
        let normalized = text
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let strippedPrompt = normalized.hasPrefix("$ ") ? String(normalized.dropFirst(2)).trimmingCharacters(in: .whitespaces) : normalized
        guard strippedPrompt.hasPrefix("curl ") || strippedPrompt.hasPrefix("curl\t") else {
            return nil
        }

        let tokens = tokenizeShellCommand(strippedPrompt)
        guard tokens.count >= 2 else { return nil }

        var url: String? = nil
        var explicitMethod: String? = nil
        var headers: [(String, String)] = []
        var body: String? = nil

        var i = 1
        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case "-X", "--request":
                if i + 1 < tokens.count {
                    explicitMethod = tokens[i + 1].uppercased()
                    i += 2
                    continue
                }
            case "-H", "--header":
                if i + 1 < tokens.count {
                    let rawHeader = tokens[i + 1]
                    if let colonIdx = rawHeader.firstIndex(of: ":") {
                        let key = rawHeader[..<colonIdx].trimmingCharacters(in: .whitespaces)
                        let val = rawHeader[rawHeader.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                        headers.append((key, val))
                    }
                    i += 2
                    continue
                }
            case "-d", "--data", "--data-raw", "--data-binary":
                if i + 1 < tokens.count {
                    body = tokens[i + 1]
                    i += 2
                    continue
                }
            default:
                if token.hasPrefix("http://") || token.hasPrefix("https://") {
                    url = token
                } else if !token.hasPrefix("-") && url == nil && token.contains(".") {
                    url = "https://" + token
                }
            }
            i += 1
        }

        guard let resolvedURL = url else { return nil }
        let resolvedMethod = explicitMethod ?? (body != nil ? "POST" : "GET")
        return ParsedCurlCommand(url: resolvedURL, method: resolvedMethod, headers: headers, body: body)
    }

    public func convertCurlToJSFetch(_ text: String) -> String? {
        guard let parsed = parseCurlCommand(text) else { return nil }
        var optionsLines: [String] = []
        optionsLines.append("  method: \"\(parsed.method)\"")

        if !parsed.headers.isEmpty {
            let headerPairs = parsed.headers.map { k, v in
                "    \"\(escapeDoubleQuotes(k))\": \"\(escapeDoubleQuotes(v))\""
            }.joined(separator: ",\n")
            optionsLines.append("  headers: {\n\(headerPairs)\n  }")
        }

        if let body = parsed.body {
            optionsLines.append("  body: \(jsBodyLiteral(body))")
        }

        let optionsBlock = optionsLines.joined(separator: ",\n")
        return """
        const response = await fetch("\(escapeDoubleQuotes(parsed.url))", {
        \(optionsBlock)
        });
        const data = await response.json();
        """
    }

    public func convertCurlToSwiftURLRequest(_ text: String) -> String? {
        guard let parsed = parseCurlCommand(text) else { return nil }
        var lines: [String] = [
            "guard let url = URL(string: \"\(escapeDoubleQuotes(parsed.url))\") else { return }",
            "var request = URLRequest(url: url)",
            "request.httpMethod = \"\(parsed.method)\""
        ]

        for (k, v) in parsed.headers {
            lines.append("request.setValue(\"\(escapeDoubleQuotes(v))\", forHTTPHeaderField: \"\(escapeDoubleQuotes(k))\")")
        }

        if let body = parsed.body {
            lines.append("request.httpBody = #\"\(body)\"#.data(using: .utf8)")
        }

        lines.append("let (data, response) = try await URLSession.shared.data(for: request)")
        return lines.joined(separator: "\n")
    }

    private func jsBodyLiteral(_ rawBody: String) -> String {
        if let pretty = prettyPrintJSON(rawBody, sortKeys: false) {
            let indented = pretty
                .components(separatedBy: .newlines)
                .enumerated()
                .map { idx, line in idx == 0 ? line : "  " + line }
                .joined(separator: "\n")
            return "JSON.stringify(\(indented))"
        }
        return "\"\(escapeDoubleQuotes(rawBody))\""
    }

    private func escapeDoubleQuotes(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func tokenizeShellCommand(_ cmd: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false

        for ch in cmd {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && !inSingleQuote {
                escaped = true
                continue
            }
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }
            if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }
            if (ch == " " || ch == "\t" || ch == "\n") && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: - 11.9 Timestamp & ISO-8601 Converter

    public func parseTimestamp(_ text: String) -> TimestampInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

        var resolvedDate: Date? = nil

        // 1. 10-digit Unix seconds or 13-digit Unix milliseconds
        if RegexCache.shared.matches(trimmed, pattern: #"^[0-9]{10}$"#),
           let secs = Double(trimmed),
           secs >= 946_684_800 && secs <= 4_102_444_800 {
            resolvedDate = Date(timeIntervalSince1970: secs)
        } else if RegexCache.shared.matches(trimmed, pattern: #"^[0-9]{13}$"#),
                  let ms = Double(trimmed),
                  ms >= 946_684_800_000 && ms <= 4_102_444_800_000 {
            resolvedDate = Date(timeIntervalSince1970: ms / 1000.0)
        } else if RegexCache.shared.matches(trimmed, pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\s][0-9]{2}:[0-9]{2}:[0-9]{2}"#) {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFormatter.date(from: trimmed) {
                resolvedDate = d
            } else {
                let fallbackISO = ISO8601DateFormatter()
                fallbackISO.formatOptions = [.withInternetDateTime]
                resolvedDate = fallbackISO.date(from: trimmed)
            }
        }

        guard let date = resolvedDate else { return nil }
        let epochSecs = Int64(date.timeIntervalSince1970.rounded())
        let epochMs = Int64((date.timeIntervalSince1970 * 1000.0).rounded())

        let isoOut = ISO8601DateFormatter()
        isoOut.timeZone = TimeZone(secondsFromGMT: 0)
        isoOut.formatOptions = [.withInternetDateTime]
        let isoString = isoOut.string(from: date)

        let utcFormatter = DateFormatter()
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        utcFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        let humanUTC = utcFormatter.string(from: date)

        let localFormatter = DateFormatter()
        localFormatter.timeZone = .current
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let humanLocal = localFormatter.string(from: date)

        return TimestampInfo(
            date: date,
            epochSeconds: epochSecs,
            epochMilliseconds: epochMs,
            iso8601UTC: isoString,
            humanUTC: humanUTC,
            humanLocal: humanLocal
        )
    }
}
