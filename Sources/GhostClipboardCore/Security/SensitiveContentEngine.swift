import Foundation

public final class SensitiveContentEngine: Sendable {

    public init() {}

    // MARK: - Main Pre-Persistence Security Evaluation

    /// Evaluates clipboard content and metadata BEFORE any persistence occurs.
    public func evaluate(
        content: String,
        metadata: PasteboardMetadata,
        preferences: GhostPreferences = GhostPreferences(),
        excludedBundleIDs: Set<String> = PasteboardMetadata.defaultExcludedBundleIDs
    ) -> SecurityEvaluation {
        var reasons: [String] = []
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Check Excluded Source Application
        if let bundleID = metadata.sourceBundleID?.lowercased() {
            let normalizedExclusions = Set(excludedBundleIDs.map { $0.lowercased() })
            if normalizedExclusions.contains(bundleID) {
                reasons.append("Excluded source application (\(metadata.sourceAppName ?? bundleID))")
                return SecurityEvaluation(
                    sensitivityLevel: .sensitive,
                    disposition: .discardImmediately,
                    detectionReasons: reasons,
                    detectedSecretType: "Excluded Application"
                )
            }
        }

        // 2. Check Pasteboard Concealed / Password-Manager Markers
        if metadata.isConcealed || metadata.hasPasswordManagerMarker {
            reasons.append("Concealed or password-manager pasteboard marker present")
            if preferences.neverSavePasswords {
                return SecurityEvaluation(
                    sensitivityLevel: .sensitive,
                    disposition: .discardImmediately,
                    detectionReasons: reasons,
                    detectedSecretType: "Password Manager Secret"
                )
            } else {
                return SecurityEvaluation(
                    sensitivityLevel: .ephemeralSecret,
                    disposition: .memoryOnlyEphemeral,
                    detectionReasons: reasons,
                    detectedSecretType: "Password Manager Secret",
                    expirationSeconds: preferences.secretExpirationDurationSeconds
                )
            }
        }

        let typesSet = Set(metadata.types)
        if typesSet.contains(PasteboardMetadata.concealedType) ||
           !typesSet.isDisjoint(with: PasteboardMetadata.knownPasswordManagerTypes) {
            reasons.append("NSPasteboard concealed type or password manager type detected")
            return SecurityEvaluation(
                sensitivityLevel: .sensitive,
                disposition: preferences.neverSavePasswords ? .discardImmediately : .memoryOnlyEphemeral,
                detectionReasons: reasons,
                detectedSecretType: "Concealed Credential",
                expirationSeconds: preferences.neverSavePasswords ? nil : preferences.secretExpirationDurationSeconds
            )
        }

        // 3. Check Explicit Cryptographic Private Keys & Known API Keys / Credentials
        if let secretMatch = detectKnownCredentialOrKey(in: trimmed) {
            reasons.append(secretMatch.reason)
            let shouldDiscard = secretMatch.isPasswordCredential ? preferences.neverSavePasswords : preferences.neverSaveAPIKeys
            if shouldDiscard {
                return SecurityEvaluation(
                    sensitivityLevel: .sensitive,
                    disposition: .discardImmediately,
                    detectionReasons: reasons,
                    detectedSecretType: secretMatch.secretType
                )
            } else {
                return SecurityEvaluation(
                    sensitivityLevel: .ephemeralSecret,
                    disposition: .memoryOnlyEphemeral,
                    detectionReasons: reasons,
                    detectedSecretType: secretMatch.secretType,
                    expirationSeconds: preferences.secretExpirationDurationSeconds
                )
            }
        }

        // 4. Check OTP Codes (Conservative Detection + Transient / Contextual Signals)
        if let otpMatch = detectOTP(in: trimmed, metadata: metadata) {
            reasons.append(otpMatch)
            if preferences.allowEphemeralOTP || !preferences.neverSaveOTPs {
                return SecurityEvaluation(
                    sensitivityLevel: .ephemeralSecret,
                    disposition: .memoryOnlyEphemeral,
                    detectionReasons: reasons,
                    detectedSecretType: "One-Time Verification Code (OTP)",
                    expirationSeconds: preferences.secretExpirationDurationSeconds
                )
            } else {
                return SecurityEvaluation(
                    sensitivityLevel: .sensitive,
                    disposition: .discardImmediately,
                    detectionReasons: reasons,
                    detectedSecretType: "One-Time Verification Code (OTP)"
                )
            }
        }

        // 5. Check Transient Pasteboard Marker (e.g., TextExpander, system transient copies, or potential secrets)
        if metadata.isTransient || typesSet.contains(PasteboardMetadata.transientType) {
            reasons.append("Transient pasteboard marker (org.nspasteboard.TransientType)")
            return SecurityEvaluation(
                sensitivityLevel: .ephemeralSecret,
                disposition: .memoryOnlyEphemeral,
                detectionReasons: reasons,
                detectedSecretType: "Transient Clipboard Item",
                expirationSeconds: preferences.secretExpirationDurationSeconds
            )
        }

        // 6. Check Level 1 — Potentially Sensitive Content (High-entropy standalone tokens, connection strings, recovery codes)
        if let potentialMatch = detectPotentiallySensitive(in: trimmed) {
            reasons.append(potentialMatch.reason)
            if preferences.quarantinePotentiallySensitive {
                return SecurityEvaluation(
                    sensitivityLevel: .potentiallySensitive,
                    disposition: .memoryOnlyEphemeral,
                    detectionReasons: reasons,
                    detectedSecretType: potentialMatch.secretType,
                    expirationSeconds: preferences.secretExpirationDurationSeconds
                )
            }
        }

        // 7. Level 0 — Normal Content
        return SecurityEvaluation(
            sensitivityLevel: .normal,
            disposition: .persistStandard,
            detectionReasons: [],
            detectedSecretType: nil,
            expirationSeconds: TimeInterval(preferences.standardRetentionDays * 86_400)
        )
    }

    // MARK: - Known Credential & API Key Detection

    public struct SecretMatch: Sendable {
        public let secretType: String
        public let reason: String
        public let isPasswordCredential: Bool

        public init(secretType: String, reason: String, isPasswordCredential: Bool = false) {
            self.secretType = secretType
            self.reason = reason
            self.isPasswordCredential = isPasswordCredential
        }
    }

    public func detectKnownCredentialOrKey(in text: String) -> SecretMatch? {
        // 1. PEM Private Key Headers
        let privateKeyPatterns = [
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN DSA PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----"
        ]
        for header in privateKeyPatterns {
            if text.contains(header) {
                return SecretMatch(secretType: "Private Cryptographic Key", reason: "Contains PEM private key header (\(header))")
            }
        }

        // 2. AWS Access Key ID & Secret
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9])(AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}(?:[^A-Za-z0-9]|$)"#) {
            return SecretMatch(secretType: "AWS Access Key", reason: "Matches AWS Access Key ID pattern")
        }

        // 3. GitHub Personal Access Tokens / Fine-Grained Tokens
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9_])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,255}(?:[^A-Za-z0-9_]|$)"#) ||
           matchesRegex(text, pattern: #"github_pat_[A-Za-z0-9_]{40,255}"#) {
            return SecretMatch(secretType: "GitHub Token", reason: "Matches GitHub authentication token prefix")
        }

        // 4. OpenAI / Anthropic / AI Provider Keys
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,255}"#) {
            return SecretMatch(secretType: "Anthropic API Key", reason: "Matches Anthropic API key prefix (sk-ant-)")
        }
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{28,255}"#) {
            return SecretMatch(secretType: "OpenAI API Key", reason: "Matches OpenAI secret key prefix (sk-)")
        }

        // 5. Stripe Live/Test Secret & Restricted Keys
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9_])(sk|rk)_(live|test)_[0-9a-zA-Z]{20,99}"#) {
            return SecretMatch(secretType: "Stripe Secret Key", reason: "Matches Stripe secret/restricted API key")
        }

        // 6. Slack Tokens & Webhooks
        if matchesRegex(text, pattern: #"xox[baprs]-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*"#) {
            return SecretMatch(secretType: "Slack Token", reason: "Matches Slack API token prefix (xox*)")
        }
        if text.contains("https://hooks.slack.com/services/T") {
            return SecretMatch(secretType: "Slack Webhook URL", reason: "Contains Slack incoming webhook secret URL")
        }

        // 7. Google API Keys & OAuth
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?:[^A-Za-z0-9_-]|$)"#) {
            return SecretMatch(secretType: "Google Cloud API Key", reason: "Matches Google API key prefix (AIza)")
        }

        // 8. GitLab / npm / PyPI / HuggingFace / SendGrid / Twilio tokens
        if matchesRegex(text, pattern: #"(?:^|[^A-Za-z0-9_-])(glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36}|pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{30,}|hf_[A-Za-z0-9]{30,}|SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})(?:[^A-Za-z0-9_-]|$)"#) {
            return SecretMatch(secretType: "Service API Token", reason: "Matches known developer platform token (GitLab/npm/PyPI/HF/SendGrid)")
        }

        // 9. Bearer Token or Authorization Header
        if matchesRegex(text, pattern: #"(?i)^(?:authorization:\s*)?bearer\s+[A-Za-z0-9\-._~+/]+=*$"#) && text.count >= 24 {
            return SecretMatch(secretType: "Bearer Token", reason: "Matches Authorization Bearer token")
        }

        // 10. JSON Web Token (JWT)
        if matchesRegex(text, pattern: #"^eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}$"#) {
            return SecretMatch(secretType: "JSON Web Token (JWT)", reason: "Matches 3-part base64url JWT structure")
        }

        // 11. Database Connection Strings with Embedded Password
        if matchesRegex(text, pattern: #"(?i)^(postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|rediss|amqp)://[^:\s/]+:[^@\s/]{4,}@[^\s/]+"#) {
            return SecretMatch(secretType: "Database Connection Secret", reason: "URI contains embedded user:password credentials", isPasswordCredential: true)
        }

        // 12. Environment Variable Secret Assignment (single or few lines)
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count <= 8 {
            for line in lines {
                if matchesRegex(line, pattern: #"(?i)^\s*(?:export\s+)?[A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|PRIVATE_KEY|API_KEY|ACCESS_TOKEN|AUTH_TOKEN)[A-Z0-9_]*\s*=\s*['"]?[A-Za-z0-9_\-./+=!@#$%^&*]{12,}['"]?\s*$"#) {
                    // Exclude obvious placeholders like YOUR_API_KEY or xxx
                    let lower = line.lowercased()
                    if !lower.contains("your_") && !lower.contains("example") && !lower.contains("placeholder") && !lower.contains("changeme") && !lower.contains("xxxx") {
                        let isPass = lower.contains("password") || lower.contains("passwd")
                        return SecretMatch(secretType: "Credential Assignment", reason: "Contains secret environment variable assignment", isPasswordCredential: isPass)
                    }
                }
            }
        }

        return nil
    }

    // MARK: - OTP Detection (Section 5.1.4)

    /// Never assume every 6-digit number is an OTP.
    /// Recognizes OTPs via:
    /// 1. Explicit OTP context words ("verification code: 482910", "Your OTP is 839-201")
    /// 2. AutoGenerated / Transient / Mail / Messages source context with 6-8 digit code
    public func detectOTP(in text: String, metadata: PasteboardMetadata) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case A: Contextual message containing an OTP phrase and a 4-8 digit code
        let contextualPattern = #"(?i)\b(?:otp|verification\s+code|security\s+code|2fa\s+code|authentication\s+code|passcode|one-time\s+(?:password|code)|login\s+code)\b[^\n]{0,40}?\b([0-9]{4,8}|[0-9]{3}-[0-9]{3})\b"#
        let reverseContextualPattern = #"(?i)\b([0-9]{4,8}|[0-9]{3}-[0-9]{3})\b[^\n]{0,30}?\bis\s+your\s+(?:otp|verification|security|authentication|login|one-time)\s*(?:code|password|passcode)?"#
        if matchesRegex(trimmed, pattern: contextualPattern) || matchesRegex(trimmed, pattern: reverseContextualPattern) {
            return "Contextual OTP verification code message detected"
        }

        // Case B: Standalone 6-digit or 3-3 hyphenated code when accompanied by transient/autogenerated marker or known 2FA/Messaging apps
        let isStandaloneCode = matchesRegex(trimmed, pattern: #"^(?:[0-9]{6}|[0-9]{8}|[0-9]{3}-[0-9]{3})$"#)
        if isStandaloneCode {
            if metadata.isTransient || metadata.isAutoGenerated ||
               metadata.types.contains(PasteboardMetadata.transientType) ||
               metadata.types.contains(PasteboardMetadata.autoGeneratedType) {
                return "Standalone numeric code with transient/auto-generated pasteboard marker"
            }

            if let bundle = metadata.sourceBundleID?.lowercased() {
                let otpSourceBundles: Set<String> = [
                    "com.apple.mobileSMS",
                    "com.apple.iChat",
                    "com.apple.mail",
                    "com.authy.authy-mac",
                    "com.google.Step2",
                    "com.yubico.ykman",
                    "com.2stable.authenticator"
                ].map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }

                if otpSourceBundles.contains(bundle) {
                    return "Standalone numeric code copied from authentication/messaging app (\(metadata.sourceAppName ?? bundle))"
                }
            }
        }

        return nil
    }

    // MARK: - Potentially Sensitive Detection (Level 1)

    public func detectPotentiallySensitive(in text: String) -> SecretMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Single-line high-entropy password/token-like string (16..96 chars, no spaces, mixed char classes, not a URL or file path)
        if !trimmed.contains(where: { $0.isWhitespace }) &&
           trimmed.count >= 16 && trimmed.count <= 96 &&
           !trimmed.lowercased().hasPrefix("http://") &&
           !trimmed.lowercased().hasPrefix("https://") &&
           !trimmed.hasPrefix("/") &&
           !trimmed.hasPrefix("~/") &&
           !trimmed.hasPrefix("#") {

            let hasUpper = trimmed.contains(where: { $0.isUppercase })
            let hasLower = trimmed.contains(where: { $0.isLowercase })
            let hasDigit = trimmed.contains(where: { $0.isNumber })
            let specialChars = Set("!@#$%^&*()-_=+[]{}|;:,.<>?~")
            let hasSpecial = trimmed.contains(where: { specialChars.contains($0) })

            let classCount = [hasUpper, hasLower, hasDigit, hasSpecial].filter { $0 }.count
            let entropy = shannonEntropy(of: trimmed)

            // Exclude common camelCase/snake_case identifiers or UUIDs
            let isUUID = matchesRegex(trimmed, pattern: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)
            let isHexHash = matchesRegex(trimmed, pattern: #"^[0-9a-fA-F]{32,64}$"#)

            if !isUUID && !isHexHash {
                if classCount == 4 && entropy >= 3.7 {
                    return SecretMatch(
                        secretType: "High-Entropy Password / Secret Candidate",
                        reason: String(format: "Standalone string with 4 character classes and high Shannon entropy (%.2f bits/char)", entropy)
                    )
                }
                if classCount >= 3 && trimmed.count >= 28 && entropy >= 4.25 {
                    return SecretMatch(
                        secretType: "High-Entropy Token Candidate",
                        reason: String(format: "Standalone token with high Shannon entropy (%.2f bits/char)", entropy)
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Helpers

    public func shannonEntropy(of string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        var frequencies: [Character: Int] = [:]
        for ch in string {
            frequencies[ch, default: 0] += 1
        }
        let length = Double(string.count)
        var entropy = 0.0
        for (_, count) in frequencies {
            let p = Double(count) / length
            entropy -= p * log2(p)
        }
        return entropy
    }

    private func matchesRegex(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
