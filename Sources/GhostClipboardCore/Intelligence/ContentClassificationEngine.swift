import Foundation

public final class ContentClassificationEngine: Sendable {

    private let sensitiveEngine = SensitiveContentEngine()

    public init() {}

    // MARK: - Classify Clipboard Content

    public func classify(
        content: String,
        metadata: PasteboardMetadata = PasteboardMetadata(),
        securityEvaluation: SecurityEvaluation? = nil
    ) -> ClassificationResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ClassificationResult(primaryCategory: .plainText, confidence: 1.0)
        }

        // 1. Check security / OTP / Credential categories first
        let eval = securityEvaluation ?? sensitiveEngine.evaluate(content: content, metadata: metadata)
        if eval.detectedSecretType?.contains("OTP") == true || sensitiveEngine.detectOTP(in: trimmed, metadata: metadata) != nil {
            return ClassificationResult(
                primaryCategory: .otp,
                secondaryCategories: [.plainText],
                confidence: 0.98
            )
        }
        if eval.sensitivityLevel == .sensitive || sensitiveEngine.detectKnownCredentialOrKey(in: trimmed) != nil {
            return ClassificationResult(
                primaryCategory: .credential,
                secondaryCategories: [.plainText],
                confidence: 0.99
            )
        }

        // 2. Check Color Formats (#FFF, #FFFFFF, #FFFFFFFF, 0xFFFFFF, rgb(), rgba(), hsl(), hsla())
        if let color = parseColor(from: trimmed) {
            return ClassificationResult(
                primaryCategory: .hexColor,
                secondaryCategories: [.plainText],
                confidence: 0.97,
                colorComponents: color
            )
        }

        // 3. Check Single URL (HTTP, HTTPS, Local dev URLs, git@, ssh://, custom deep links)
        if let urlInfo = parseURL(from: trimmed) {
            return ClassificationResult(
                primaryCategory: .url,
                secondaryCategories: [.plainText],
                confidence: 0.98,
                urlHostname: urlInfo.hostname,
                isSuspiciousDomain: urlInfo.isSuspicious
            )
        }

        // 4. Check Valid JSON (Object or Array)
        if let jsonValid = checkJSON(trimmed), jsonValid {
            return ClassificationResult(
                primaryCategory: .json,
                secondaryCategories: [.code],
                confidence: 0.99,
                jsonIsValid: true
            )
        }

        // 5. Check Terminal Commands (Shell, Git, Docker, K8s, Package managers, PowerShell)
        if let terminalMatch = detectTerminalCommand(in: trimmed) {
            var secondaries: [ClipCategory] = [.code]
            if trimmed.contains("http://") || trimmed.contains("https://") {
                secondaries.append(.url)
            }
            return ClassificationResult(
                primaryCategory: .terminalCommand,
                secondaryCategories: secondaries,
                detectedLanguage: terminalMatch.language,
                confidence: terminalMatch.confidence,
                terminalSafetyWarning: terminalMatch.safetyWarning
            )
        }

        // 6. Check Code vs Markdown
        let markdownScore = scoreMarkdown(trimmed)
        let codeMatch = detectCodeLanguage(in: trimmed)

        if let code = codeMatch, code.score >= 2.5 && code.score >= markdownScore {
            var secondaries: [ClipCategory] = []
            if markdownScore >= 2.5 {
                secondaries.append(.markdown)
            }
            return ClassificationResult(
                primaryCategory: .code,
                secondaryCategories: secondaries,
                detectedLanguage: code.language,
                confidence: min(0.98, 0.65 + (code.score * 0.06))
            )
        }

        if markdownScore >= 2.5 {
            var secondaries: [ClipCategory] = []
            if let code = codeMatch {
                secondaries.append(.code)
                return ClassificationResult(
                    primaryCategory: .markdown,
                    secondaryCategories: secondaries,
                    detectedLanguage: code.language,
                    confidence: min(0.96, 0.65 + (markdownScore * 0.06))
                )
            }
            return ClassificationResult(
                primaryCategory: .markdown,
                secondaryCategories: secondaries,
                confidence: min(0.96, 0.65 + (markdownScore * 0.06))
            )
        }

        if let code = codeMatch, code.score >= 1.8 {
            return ClassificationResult(
                primaryCategory: .code,
                secondaryCategories: [],
                detectedLanguage: code.language,
                confidence: 0.78
            )
        }

        // 7. Fallback to Plain Text
        return ClassificationResult(
            primaryCategory: .plainText,
            secondaryCategories: [],
            confidence: 1.0
        )
    }

    // MARK: - Color Parsing (Section 5.1.2)

    /// Recognizes:
    /// - `#FFF`
    /// - `#FFFFFF`
    /// - `#FF5733` / `#FF5733AA`
    /// - `0xFFFFFF`
    /// - `rgb(255, 87, 51)` / `rgba(255, 87, 51, 0.8)`
    /// - `hsl(14, 100%, 60%)` / `hsla(14, 100%, 60%, 0.8)`
    /// Does NOT classify bare 6-character hex strings without `#` or `0x` prefix as colors!
    public func parseColor(from text: String) -> ColorComponents? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return nil }

        // 1. Hex with # or 0x prefix
        if let match = firstRegexGroups(trimmed, pattern: #"^(?:#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})|0x([0-9a-fA-F]{6}|[0-9a-fA-F]{8}))$"#) {
            let hex = !match[1].isEmpty ? match[1] : match[2]
            if hex.count == 3 {
                let chars = Array(hex)
                let r = Int(String(repeating: chars[0], count: 2), radix: 16) ?? 0
                let g = Int(String(repeating: chars[1], count: 2), radix: 16) ?? 0
                let b = Int(String(repeating: chars[2], count: 2), radix: 16) ?? 0
                return ColorComponents(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
            } else if hex.count == 6 {
                let r = Int(hex.prefix(2), radix: 16) ?? 0
                let g = Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0
                let b = Int(hex.suffix(2), radix: 16) ?? 0
                return ColorComponents(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
            } else if hex.count == 8 {
                let r = Int(hex.prefix(2), radix: 16) ?? 0
                let g = Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0
                let b = Int(hex.dropFirst(4).prefix(2), radix: 16) ?? 0
                let a = Int(hex.suffix(2), radix: 16) ?? 255
                return ColorComponents(
                    red: Double(r) / 255.0,
                    green: Double(g) / 255.0,
                    blue: Double(b) / 255.0,
                    alpha: Double(a) / 255.0
                )
            }
        }

        // 2. rgb() / rgba()
        if let groups = firstRegexGroups(
            trimmed,
            pattern: #"^(?i)rgba?\(\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})\s*,\s*([0-9]{1,3})(?:\s*,\s*([0-9]*(?:\.[0-9]+)?))?\s*\)$"#
        ) {
            guard let r = Double(groups[1]), let g = Double(groups[2]), let b = Double(groups[3]),
                  r <= 255, g <= 255, b <= 255 else {
                return nil
            }
            let a = groups[4].isEmpty ? 1.0 : (Double(groups[4]) ?? 1.0)
            guard a >= 0.0 && a <= 1.0 else { return nil }
            return ColorComponents(red: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
        }

        // 3. hsl() / hsla()
        if let groups = firstRegexGroups(
            trimmed,
            pattern: #"^(?i)hsla?\(\s*([0-9]{1,3}(?:\.[0-9]+)?)\s*,\s*([0-9]{1,3}(?:\.[0-9]+)?)%\s*,\s*([0-9]{1,3}(?:\.[0-9]+)?)%(?:\s*,\s*([0-9]*(?:\.[0-9]+)?))?\s*\)$"#
        ) {
            guard let h = Double(groups[1]), let s = Double(groups[2]), let l = Double(groups[3]),
                  h <= 360, s <= 100, l <= 100 else {
                return nil
            }
            let a = groups[4].isEmpty ? 1.0 : (Double(groups[4]) ?? 1.0)
            guard a >= 0.0 && a <= 1.0 else { return nil }
            return hslToRGB(h: h, s: s / 100.0, l: l / 100.0, a: a)
        }

        return nil
    }

    private func hslToRGB(h: Double, s: Double, l: Double, a: Double) -> ColorComponents {
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let x = c * (1.0 - abs(((h / 60.0).truncatingRemainder(dividingBy: 2.0)) - 1.0))
        let m = l - c / 2.0
        var rPrime = 0.0
        var gPrime = 0.0
        var bPrime = 0.0

        switch h {
        case 0..<60:
            (rPrime, gPrime, bPrime) = (c, x, 0)
        case 60..<120:
            (rPrime, gPrime, bPrime) = (x, c, 0)
        case 120..<180:
            (rPrime, gPrime, bPrime) = (0, c, x)
        case 180..<240:
            (rPrime, gPrime, bPrime) = (0, x, c)
        case 240..<300:
            (rPrime, gPrime, bPrime) = (x, 0, c)
        default:
            (rPrime, gPrime, bPrime) = (c, 0, x)
        }

        return ColorComponents(red: rPrime + m, green: gPrime + m, blue: bPrime + m, alpha: a)
    }

    // MARK: - URL Parsing (Section 5.1.3)

    public struct URLParseInfo: Sendable {
        public let hostname: String
        public let isSuspicious: Bool
    }

    public func parseURL(from text: String) -> URLParseInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        // Check Git SSH URLs: git@github.com:org/repo.git
        if let gitGroups = firstRegexGroups(trimmed, pattern: #"^git@([a-zA-Z0-9.-]+):[a-zA-Z0-9._/-]+(?:\.git)?$"#) {
            let host = gitGroups[1].lowercased()
            return URLParseInfo(hostname: host, isSuspicious: isSuspiciousHost(host, fullURL: trimmed))
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        let allowedSchemes: Set<String> = [
            "http", "https", "ssh", "ftp", "ws", "wss",
            "vscode", "cursor", "raycast", "slack", "figma", "linear", "x-xcode"
        ]
        guard allowedSchemes.contains(scheme) else { return nil }

        let host = (components.host ?? scheme).lowercased()
        guard !host.isEmpty else { return nil }

        if (scheme == "http" || scheme == "https") && !host.contains(".") && host != "localhost" && !host.hasPrefix("127.") && !host.hasPrefix("0.0.0.0") {
            return nil
        }

        return URLParseInfo(
            hostname: host,
            isSuspicious: isSuspiciousHost(host, fullURL: trimmed)
        )
    }

    private func isSuspiciousHost(_ host: String, fullURL: String) -> Bool {
        // Check punycode / homograph IDN domains, raw IP with non-local address, or @ phishing trick in authority
        let lowerURL = fullURL.lowercased()
        if host.contains("xn--") || lowerURL.contains("xn--") || !host.allSatisfy({ $0.isASCII }) {
            return true
        }
        if fullURL.contains("@") && !fullURL.hasPrefix("git@") && !fullURL.hasPrefix("ssh://") {
            return true
        }
        let suspiciousTLDs = [".zip", ".mov", ".tk", ".top", ".gq", ".cf", ".ml"]
        for tld in suspiciousTLDs where host.hasSuffix(tld) {
            return true
        }
        return false
    }

    // MARK: - JSON Validation (Section 5.1.7)

    public func checkJSON(_ text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else { return false }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return (obj is [String: Any]) || (obj is [Any])
        } catch {
            return false
        }
    }

    // MARK: - Terminal Command Detection (Section 5.1.8)

    public struct TerminalMatch: Sendable {
        public let language: ProgrammingLanguage
        public let confidence: Double
        public let safetyWarning: String?
    }

    public func detectTerminalCommand(in text: String) -> TerminalMatch? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 25 else { return nil }

        // Check shebang
        if let first = lines.first {
            if first.hasPrefix("#!/bin/bash") || first.hasPrefix("#!/bin/zsh") || first.hasPrefix("#!/bin/sh") || first.hasPrefix("#!/usr/bin/env bash") || first.hasPrefix("#!/usr/bin/env zsh") {
                return TerminalMatch(language: .shell, confidence: 0.98, safetyWarning: evaluateTerminalSafety(text))
            }
            if first.lowercased().hasPrefix("#!/usr/bin/env pwsh") {
                return TerminalMatch(language: .powershell, confidence: 0.98, safetyWarning: evaluateTerminalSafety(text))
            }
        }

        // Check PowerShell cmdlets
        let psPattern = #"(?i)^(?:Get-|Set-|New-|Remove-|Invoke-|Start-|Stop-|Write-|Out-|Select-|Where-Object|ForEach-Object|\$[a-zA-Z_][a-zA-Z0-9_]*\s*=)"#
        let psHits = lines.filter { matchesRegex($0, pattern: psPattern) }.count
        if psHits > 0 && Double(psHits) / Double(lines.count) >= 0.5 {
            return TerminalMatch(language: .powershell, confidence: 0.92, safetyWarning: evaluateTerminalSafety(text))
        }

        // Check Shell / Git / Docker / K8s / Package managers
        let shellCommandPattern = #"^(?:\$\s+|#\s+)?(?:sudo\s+)?(?:git|docker|docker-compose|kubectl|helm|terraform|brew|npm|npx|pnpm|yarn|bun|pip|pip3|poetry|uv|cargo|go|swift|xcodebuild|xcrun|make|cmake|curl|wget|ssh|scp|rsync|tar|unzip|chmod|chown|ls|cd|mkdir|rm|cp|mv|cat|grep|rg|find|fd|sed|awk|jq|kill|killall|ps|top|lsof|export|source|echo|systemctl|journalctl|launchctl|aws|gcloud|az|gh)\b"#

        var matchingLines = 0
        for line in lines {
            if line.hasPrefix("#") && lines.count > 1 {
                matchingLines += 1
                continue
            }
            if matchesRegex(line, pattern: shellCommandPattern) ||
               line.hasSuffix(" \\") ||
               line.contains(" | ") ||
               line.contains(" && ") ||
               line.contains(" 2>&1") {
                matchingLines += 1
            }
        }

        if matchingLines > 0 && Double(matchingLines) / Double(lines.count) >= 0.6 {
            // Avoid misclassifying prose sentences starting with "go to..." or "make sure..."
            if lines.count == 1 {
                let first = lines[0]
                if matchesRegex(first, pattern: #"^(?:go|make|find|echo|cat|top|kill)\s+(?:to|sure|a|the|it|out|up|in|on|for|with)\b"#) &&
                   !first.contains("-") && !first.contains("/") && !first.contains("|") {
                    return nil
                }
            }
            return TerminalMatch(
                language: .shell,
                confidence: 0.92,
                safetyWarning: evaluateTerminalSafety(text)
            )
        }

        return nil
    }

    public func evaluateTerminalSafety(_ text: String) -> String? {
        if matchesRegex(text, pattern: #"(?:^|\s|sudo\s+)rm\s+-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*\s+(?:/|\*|~|\$HOME)"#) ||
           matchesRegex(text, pattern: #"(?:^|\s|sudo\s+)rm\s+-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*\s*"#) {
            return "Destructive file deletion command detected (rm -rf)"
        }
        if matchesRegex(text, pattern: #"(?i)\b(?:DROP\s+TABLE|DROP\s+DATABASE|TRUNCATE\s+TABLE)\b"#) {
            return "Destructive database operation detected (DROP / TRUNCATE)"
        }
        if matchesRegex(text, pattern: #"git\s+push\s+.*(?:-f|--force)\b"#) ||
           matchesRegex(text, pattern: #"git\s+reset\s+--hard\b"#) ||
           matchesRegex(text, pattern: #"git\s+clean\s+-[a-zA-Z]*f"#) {
            return "Potentially destructive Git history/working-tree command (--force / --hard / clean -f)"
        }
        if matchesRegex(text, pattern: #"(?:curl|wget)\s+[^\n|]+\|\s*(?:sudo\s+)?(?:bash|sh|zsh)\b"#) {
            return "Remote script piped directly to shell execution (curl/wget | sh)"
        }
        if matchesRegex(text, pattern: #"\b(?:mkfs|dd\s+if=|diskutil\s+eraseDisk)\b"#) {
            return "Low-level disk formatting or overwrite command detected"
        }
        if matchesRegex(text, pattern: #"chmod\s+(?:-R\s+)?777\b"#) {
            return "Insecure world-writable permissions command (chmod 777)"
        }
        if matchesRegex(text, pattern: #"kubectl\s+delete\s+"#) || matchesRegex(text, pattern: #"terraform\s+destroy"#) {
            return "Infrastructure deletion command detected (kubectl delete / terraform destroy)"
        }
        return nil
    }

    // MARK: - Markdown Scoring (Section 5.1.6)

    public func scoreMarkdown(_ text: String) -> Double {
        let lines = text.components(separatedBy: .newlines)
        var score = 0.0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Headings
            if matchesRegex(trimmed, pattern: #"^#{1,6}\s+\S+"#) { score += 2.0 }
            // Checkboxes
            if matchesRegex(trimmed, pattern: #"^[-*+]\s+\[[ xX]\]\s+\S+"#) { score += 2.5 }
            // Bullet lists
            else if matchesRegex(trimmed, pattern: #"^[-*+]\s+\S+"#) { score += 0.9 }
            // Numbered lists
            if matchesRegex(trimmed, pattern: #"^[0-9]+\.\s+\S+"#) { score += 0.8 }
            // Blockquotes
            if matchesRegex(trimmed, pattern: #"^>\s+\S+"#) { score += 1.2 }
            // Fenced code blocks
            if trimmed.hasPrefix("```") { score += 2.5 }
            // Markdown table row / separator
            if matchesRegex(trimmed, pattern: #"^\|.*\|$"#) { score += 1.5 }
            if matchesRegex(trimmed, pattern: #"^\|?[\s:-]+\|[\s|:-]+\|?$"#) { score += 2.5 }
        }

        // Inline links [text](url)
        if matchesRegex(text, pattern: #"\[[^\]]+\]\(https?://[^)]+\)"#) {
            score += 2.5
        }
        // Bold / emphasis pairs
        if matchesRegex(text, pattern: #"\*\*[^*\n]+\*\*"#) {
            score += 1.0
        }

        return score
    }

    // MARK: - Code Language Detection (Section 5.1.1)

    public struct CodeMatch: Sendable {
        public let language: ProgrammingLanguage
        public let score: Double
    }

    public func detectCodeLanguage(in text: String) -> CodeMatch? {
        var scores: [ProgrammingLanguage: Double] = [:]

        func add(_ lang: ProgrammingLanguage, _ points: Double) {
            scores[lang, default: 0] += points
        }

        // Swift
        if matchesRegex(text, pattern: #"\b(?:import\s+(?:Foundation|SwiftUI|AppKit|UIKit|Combine|CryptoKit)|struct\s+\w+\s*:\s*\w+|func\s+\w+\s*\(|guard\s+let\s+|if\s+let\s+)\b|@(?:State|Binding|Published|MainActor|Environment|ObservedObject)\b"#) {
            add(.swift, 4.5)
        }
        if matchesRegex(text, pattern: #"\b(?:let|var)\s+\w+\s*:\s*(?:some\s+)?[A-Z]\w+"#) { add(.swift, 2.5) }

        // TypeScript
        if matchesRegex(text, pattern: #"\b(?:interface\s+[A-Z]\w*|type\s+[A-Z]\w*\s*=|export\s+(?:interface|type)\s+|:\s*(?:string|number|boolean|any|unknown|Record<|Partial<|Readonly<))"#) {
            add(.typescript, 4.5)
        }
        if matchesRegex(text, pattern: #"\b(?:const|let|function)\s+\w+.*:\s*\w+"#) { add(.typescript, 2.5) }

        // JavaScript
        if matchesRegex(text, pattern: #"\b(?:const|let|var)\s+\w+\s*=\s*|console\.(?:log|error|warn)\(|document\.(?:getElementById|querySelector)|module\.exports\s*=|export\s+(?:default|const|function)\b|=>\s*\{"#) {
            add(.javascript, 3.2)
        }
        if matchesRegex(text, pattern: #"import\s+.*\s+from\s+['"][^'"]+['"]"#) {
            add(.javascript, 2.5)
            add(.typescript, 2.5)
        }

        // Python
        if matchesRegex(text, pattern: #"(?m)^(?:def\s+\w+\s*\(.*\)\s*(?:->\s*[^:]+)?\s*:|class\s+\w+(?:\([^)]*\))?\s*:|from\s+[\w.]+\s+import\s+|elif\s+.*:|if\s+__name__\s*==\s*['"]__main__['"]\s*:)"#) {
            add(.python, 4.5)
        }
        if matchesRegex(text, pattern: #"\b(?:self\.\w+|None|True|False|print\()"#) && text.contains(":") {
            add(.python, 2.0)
        }

        // Rust
        if matchesRegex(text, pattern: #"\b(?:fn\s+\w+\s*\(|pub\s+(?:fn|struct|enum|mod|use)\b|let\s+mut\s+\w+|impl(?:\s*<[^>]+>)?\s+\w+|println!\(|vec!\[|Option<|Result<|match\s+\w+\s*\{)"#) {
            add(.rust, 4.5)
        }

        // Go
        if matchesRegex(text, pattern: #"(?m)^(?:package\s+\w+|func\s+(?:\([^)]+\)\s*)?\w+\s*\(|type\s+\w+\s+struct\s*\{)|fmt\.(?:Println|Printf|Sprintf|Errorf)\(|:=\s*"#) {
            add(.go, 4.0)
        }

        // Java
        if matchesRegex(text, pattern: #"\b(?:public\s+(?:static\s+)?(?:final\s+)?(?:class|interface|void|int|String)\b|System\.out\.println\(|private\s+final\s+|@Override\b|package\s+[\w.]+;)"#) {
            add(.java, 4.0)
        }

        // Kotlin
        if matchesRegex(text, pattern: #"\b(?:fun\s+\w+\s*\(|val\s+\w+\s*[:=]|data\s+class\s+\w+|companion\s+object|suspend\s+fun\b)"#) {
            add(.kotlin, 4.2)
        }

        // C / C++
        if matchesRegex(text, pattern: #"(?m)^#include\s*[<"][^>"]+[>"]"#) {
            if matchesRegex(text, pattern: #"\b(?:std::|cout|cin|vector<|string|namespace\s+\w+|template\s*<|nullptr|class\s+\w+)"#) {
                add(.cpp, 5.0)
            } else {
                add(.c, 4.5)
            }
        }
        if matchesRegex(text, pattern: #"\b(?:std::\w+|cout\s*<<|cin\s*>>|template\s*<typename\s+)"#) {
            add(.cpp, 4.5)
        }
        if matchesRegex(text, pattern: #"\b(?:printf\s*\(|malloc\s*\(|sizeof\s*\(|int\s+main\s*\()"#) {
            add(.c, 3.5)
        }

        // Ruby
        if matchesRegex(text, pattern: #"(?m)^(?:def\s+\w+|module\s+[A-Z]\w*|require\s+['"][^'"]+['"]|attr_accessor\s+:|\bend\b)"#) {
            if matchesRegex(text, pattern: #"\b(?:puts\s+|do\s*\|[^|]+\||\.each\s+do\b|end\b)"#) {
                add(.ruby, 4.0)
            }
        }

        // PHP
        if matchesRegex(text, pattern: #"<\?php\b|\$[a-zA-Z_]\w*\s*=.*?;|function\s+\w+\s*\(\s*\$|->\w+\s*\("#) {
            add(.php, 4.5)
        }

        // SQL
        if matchesRegex(text, pattern: #"(?i)\b(?:SELECT\s+.+\s+FROM\s+\w+|INSERT\s+INTO\s+\w+|UPDATE\s+\w+\s+SET\s+|CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?\w+|ALTER\s+TABLE\s+\w+|INNER\s+JOIN\s+\w+|LEFT\s+JOIN\s+\w+|GROUP\s+BY\s+|ORDER\s+BY\s+)"#) {
            add(.sql, 4.5)
        }

        // HTML
        if matchesRegex(text, pattern: #"(?i)^\s*(?:<!DOCTYPE\s+html>|<html\b|<head\b|<body\b|<div\b|<section\b|<script\b|<style\b|<span\b|<form\b|<table\b|<svg\b)"#) &&
           matchesRegex(text, pattern: #"</[a-zA-Z0-9-]+>|/>"#) {
            add(.html, 4.5)
        }

        // CSS
        if matchesRegex(text, pattern: #"(?s)(?:^[.#]?[a-zA-Z0-9_-]+(?:\s*[>+~]\s*[.#]?[a-zA-Z0-9_-]+)*\s*\{\s*[a-z-]+\s*:\s*[^;]+;\s*\}|@(?:media|keyframes|import|supports)\b|\b(?:display|flex-direction|justify-content|align-items|background-color|border-radius|font-family|grid-template-columns)\s*:\s*[^;]+;)"#) {
            add(.css, 4.2)
        }

        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 1.8 else {
            return nil
        }
        return CodeMatch(language: best.key, score: best.value)
    }

    // MARK: - Regex Utilities

    private func matchesRegex(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func firstRegexGroups(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        var results: [String] = []
        for idx in 0..<match.numberOfRanges {
            let groupRange = match.range(at: idx)
            if groupRange.location != NSNotFound,
               let swiftRange = Range(groupRange, in: text) {
                results.append(String(text[swiftRange]))
            } else {
                results.append("")
            }
        }
        return results
    }
}
