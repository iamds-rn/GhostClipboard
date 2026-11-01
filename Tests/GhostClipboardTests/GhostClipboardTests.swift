import Foundation
import CryptoKit
import GhostClipboardCore

@main
struct GhostClipboardTestRunner {
    private static var passedCount = 0
    private static var failedCount = 0

    static func assertTrue(_ condition: @autoclosure () throws -> Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        do {
            if try condition() {
                passedCount += 1
            } else {
                failedCount += 1
                fputs("❌ Assertion failed at \(file):\(line) — \(message)\n", stderr)
            }
        } catch {
            failedCount += 1
            fputs("❌ Assertion threw error at \(file):\(line) — \(error). \(message)\n", stderr)
        }
    }

    static func assertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, _ message: String = "", file: String = #file, line: Int = #line) {
        do {
            let l = try lhs()
            let r = try rhs()
            if l == r {
                passedCount += 1
            } else {
                failedCount += 1
                fputs("❌ Assertion failed at \(file):\(line) — Expected \(r), got \(l). \(message)\n", stderr)
            }
        } catch {
            failedCount += 1
            fputs("❌ Assertion threw error at \(file):\(line) — \(error). \(message)\n", stderr)
        }
    }

    static func assertNotEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String = "", file: String = #file, line: Int = #line) {
        let l = lhs()
        let r = rhs()
        if l != r {
            passedCount += 1
        } else {
            failedCount += 1
            fputs("❌ Assertion failed at \(file):\(line) — Expected != \(r). \(message)\n", stderr)
        }
    }

    static func assertNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: String = #file, line: Int = #line) {
        if value() != nil {
            passedCount += 1
        } else {
            failedCount += 1
            fputs("❌ Assertion failed at \(file):\(line) — Expected non-nil. \(message)\n", stderr)
        }
    }

    static func assertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "", file: String = #file, line: Int = #line) {
        if value() == nil {
            passedCount += 1
        } else {
            failedCount += 1
            fputs("❌ Assertion failed at \(file):\(line) — Expected nil. \(message)\n", stderr)
        }
    }

    @MainActor
    static func main() {
        print("Running GhostClipboard Verification Suite...")

        let classifier = ContentClassificationEngine()
        let securityEngine = SensitiveContentEngine()
        let actionsEngine = DeveloperActionsEngine()

        // 1. Sensitive Content Engine Pre-Persistence Tests
        do {
            let meta = PasteboardMetadata(
                types: [PasteboardMetadata.concealedType],
                sourceBundleID: "com.apple.Safari",
                isConcealed: true
            )
            let eval = securityEngine.evaluate(content: "CorrectHorseBatteryStaple!", metadata: meta)
            assertEqual(eval.sensitivityLevel, .sensitive, "Concealed pasteboard type must be Level 2 sensitive")
            assertEqual(eval.disposition, .discardImmediately, "Concealed pasteboard type must be discarded immediately")
        }

        // 2. Excluded App (1Password, Bitwarden, Keychain)
        do {
            let meta = PasteboardMetadata(
                types: ["public.utf8-plain-text"],
                sourceBundleID: "com.1password.1password",
                sourceAppName: "1Password"
            )
            let eval = securityEngine.evaluate(content: "normal looking text", metadata: meta)
            assertEqual(eval.sensitivityLevel, .sensitive)
            assertEqual(eval.disposition, .discardImmediately)
            assertEqual(eval.detectedSecretType, "Excluded Application")
        }

        // 3. API Keys, PEM Private Keys, JWTs, Database URIs
        do {
            let secrets = [
                "sk-proj-9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b",
                "sk-ant-api03-abcdef0123456789abcdef0123456789",
                "AKIAIOSFODNN7EXAMPLE",
                "ghp_1234567890abcdefghijklmnopqrstuvwxyzABCD",
                "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----",
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
                "postgres://admin:SuperSecretPass123@db.internal.example.com:5432/production"
            ]

            for secret in secrets {
                let eval = securityEngine.evaluate(content: secret, metadata: PasteboardMetadata())
                assertEqual(eval.sensitivityLevel, .sensitive, "Expected sensitive level for \(secret)")
                assertEqual(eval.disposition, .discardImmediately, "Expected immediate discard for \(secret)")
            }
        }

        // 4. OTP Conservative Detection (Section 5.1.4: Never assume every 6-digit number is an OTP)
        do {
            let bareNumber = "482910"
            let normalMeta = PasteboardMetadata(sourceBundleID: "com.apple.dt.Xcode", sourceAppName: "Xcode")
            let otpMatch = securityEngine.detectOTP(in: bareNumber, metadata: normalMeta)
            assertNil(otpMatch, "Bare 6-digit number from Xcode without transient/OTP context must not be flagged as OTP")

            let eval = securityEngine.evaluate(content: bareNumber, metadata: normalMeta)
            assertEqual(eval.sensitivityLevel, .normal)

            let contextualOTP = "Your verification code is 482910. Do not share this code."
            let eval1 = securityEngine.evaluate(content: contextualOTP, metadata: PasteboardMetadata())
            assertEqual(eval1.sensitivityLevel, .sensitive)
            assertEqual(eval1.disposition, .discardImmediately)

            let smsMeta = PasteboardMetadata(sourceBundleID: "com.apple.MobileSMS", sourceAppName: "Messages")
            let eval2 = securityEngine.evaluate(content: "839201", metadata: smsMeta)
            assertEqual(eval2.sensitivityLevel, .sensitive)

            var prefs = GhostPreferences()
            prefs.neverSaveOTPs = false
            prefs.allowEphemeralOTP = true
            let eval3 = securityEngine.evaluate(content: contextualOTP, metadata: PasteboardMetadata(), preferences: prefs)
            assertEqual(eval3.sensitivityLevel, .ephemeralSecret)
            assertEqual(eval3.disposition, .memoryOnlyEphemeral)
            assertEqual(eval3.expirationSeconds, 120)
        }

        // 5. Color Classification & Non-Prefixed 6-char Hex Rejection (Section 5.1.2)
        do {
            let validColors = [
                "#FFF",
                "#A6B7FF",
                "#FF5733AA",
                "0xFF5733",
                "rgb(255, 87, 51)",
                "rgba(166, 183, 255, 0.75)",
                "hsl(14, 100%, 60%)",
                "hsla(225, 100%, 82%, 0.9)"
            ]

            for colorStr in validColors {
                let res = classifier.classify(content: colorStr)
                assertEqual(res.primaryCategory, .hexColor, "Failed to classify \(colorStr) as hexColor")
                assertNotNil(res.colorComponents)
            }

            let bareHex = "FF5733"
            let bareRes = classifier.classify(content: bareHex)
            assertNotEqual(bareRes.primaryCategory, .hexColor, "Bare 6-char hex without # or 0x must NOT be classified as color")
        }

        // 6. URL Classification & Suspicious Domain Detection
        do {
            let normalURL = "https://developer.apple.com/documentation/swift"
            let res1 = classifier.classify(content: normalURL)
            assertEqual(res1.primaryCategory, .url)
            assertEqual(res1.urlHostname, "developer.apple.com")
            assertEqual(res1.isSuspiciousDomain, false)

            let suspiciousURL = "https://xn--80ak6aa92e.com/login"
            let res2 = classifier.classify(content: suspiciousURL)
            assertEqual(res2.primaryCategory, .url)
            assertEqual(res2.isSuspiciousDomain, true)
        }

        // 7. JSON, Markdown, Terminal, and Code Language Detection
        do {
            let json = #"{"name":"GhostClipboard","localOnly":true,"categories":["code","json","url"]}"#
            let resJSON = classifier.classify(content: json)
            assertEqual(resJSON.primaryCategory, .json)
            assertEqual(resJSON.jsonIsValid, true)

            let md = "# Architecture Overview\n- [x] Pre-persistence security evaluation\n- [ ] CLI integration\nRead [Spec](https://example.com/spec)."
            let resMD = classifier.classify(content: md)
            assertEqual(resMD.primaryCategory, .markdown)

            let safeCmd = "docker compose up -d --build && kubectl get pods -n prod"
            let resCmd1 = classifier.classify(content: safeCmd)
            assertEqual(resCmd1.primaryCategory, .terminalCommand)
            assertNil(resCmd1.terminalSafetyWarning)

            let dangerousCmd = "sudo rm -rf /var/lib/docker/*"
            let resCmd2 = classifier.classify(content: dangerousCmd)
            assertEqual(resCmd2.primaryCategory, .terminalCommand)
            assertNotNil(resCmd2.terminalSafetyWarning)

            let swiftCode = "import SwiftUI\nstruct PaletteView: View {\n    @State private var query = \"\"\n    var body: some View { Text(query) }\n}"
            let swiftRes = classifier.classify(content: swiftCode)
            assertEqual(swiftRes.primaryCategory, .code)
            assertEqual(swiftRes.detectedLanguage, .swift)

            let pythonCode = "from typing import List\ndef compute_entropy(tokens: List[str]) -> float:\n    if not tokens:\n        return 0.0\n    return len(tokens) * 1.5"
            let pyRes = classifier.classify(content: pythonCode)
            assertEqual(pyRes.primaryCategory, .code)
            assertEqual(pyRes.detectedLanguage, .python)

            let rustCode = "pub fn verify_signature(payload: &[u8]) -> Result<bool, Error> {\n    let mut hasher = Sha256::new();\n    println!(\"Verifying payload\");\n    Ok(true)\n}"
            let rsRes = classifier.classify(content: rustCode)
            assertEqual(rsRes.primaryCategory, .code)
            assertEqual(rsRes.detectedLanguage, .rust)

            let sqlCode = "SELECT id, primary_category, created_at FROM clips WHERE is_pinned = 1 ORDER BY created_at DESC;"
            let sqlRes = classifier.classify(content: sqlCode)
            assertEqual(sqlRes.primaryCategory, .code)
            assertEqual(sqlRes.detectedLanguage, .sql)
        }

        // 8. Developer Actions Engine Verification
        do {
            let dirty = "https://github.com/org/repo?utm_source=twitter&utm_medium=social&tab=readme&fbclid=IwAR999"
            let clean = actionsEngine.removeTrackingParameters(from: dirty)
            assertEqual(clean, "https://github.com/org/repo?tab=readme")

            let raw = #"{"z":1,"a":{"nested":true},"m":[1,2,3]}"#
            let sorted = actionsEngine.prettyPrintJSON(raw, sortKeys: true)
            assertNotNil(sorted)
            assertTrue(sorted?.contains("\"a\" :") == true)

            let minified = actionsEngine.minifyJSON(sorted ?? "")
            assertEqual(minified, #"{"a":{"nested":true},"m":[1,2,3],"z":1}"#)

            let keys = actionsEngine.extractJSONKeys(raw)
            assertEqual(keys, ["a", "m", "z"])

            let numbered = "  1 | let a = 10\n  2 | let b = 20"
            let stripped = actionsEngine.stripLineNumbers(from: numbered)
            assertEqual(stripped, "let a = 10\nlet b = 20")
        }

        // 9. Encrypted SQLite Storage, FTS5 Search, and Coordinator Pre-Persistence Pipeline
        do {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ghost_test_\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let key = SymmetricKey(size: .bits256)
            let vault = CryptoVault(customKey: key)
            let db = try SQLiteStorageEngine(databaseURL: tempURL, vault: vault)

            let normalClip = ClipItem(
                content: "func calculateHash(input: String) -> String",
                contentHash: CryptoVault.sha256Hex("func calculateHash(input: String) -> String"),
                primaryCategory: .code,
                detectedLanguage: .swift,
                sourceApplication: "Xcode",
                sensitivityLevel: .normal
            )
            try db.saveClip(normalClip)

            let secretClip = ClipItem(
                content: "sk-proj-secret123456789012345678901234567890",
                contentHash: CryptoVault.sha256Hex("sk-proj-secret123456789012345678901234567890"),
                primaryCategory: .credential,
                sensitivityLevel: .sensitive
            )
            try db.saveClip(secretClip)

            let allClips = try db.fetchClips()
            assertEqual(allClips.count, 1)
            assertEqual(allClips.first?.content, normalClip.content)

            let searchHits = try db.fetchClips(query: "calculateHash")
            assertEqual(searchHits.count, 1)
            assertEqual(searchHits.first?.id, normalClip.id)

            let expiredClip = ClipItem(
                content: "Temporary URL https://localhost:3000",
                contentHash: CryptoVault.sha256Hex("Temporary URL https://localhost:3000"),
                primaryCategory: .url,
                sensitivityLevel: .normal,
                createdAt: Date().addingTimeInterval(-3600),
                expiresAt: Date().addingTimeInterval(-10)
            )
            try db.saveClip(expiredClip)
            let beforePurgeCount = try db.fetchClips().count
            assertEqual(beforePurgeCount, 2)

            let purged = try db.purgeExpiredClips(now: Date())
            assertEqual(purged, 1)
            let afterPurgeCount = try db.fetchClips().count
            assertEqual(afterPurgeCount, 1)

            // Coordinator test
            let coordURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ghost_coord_\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: coordURL) }
            let coordDB = try SQLiteStorageEngine(databaseURL: coordURL, vault: vault)
            let coordinator = ClipboardCoordinator(storage: coordDB)

            let disp1 = coordinator.ingestClipboardContent("sk-ant-api03-9999999999999999999999999999")
            assertEqual(disp1, .discardImmediately)
            assertEqual(coordinator.persistentClips.count, 0)
            assertEqual(coordinator.ephemeralClips.count, 0)
            assertEqual(coordinator.excludedEvents.count, 1)

            let transientMeta = PasteboardMetadata(types: [PasteboardMetadata.transientType], isTransient: true)
            let now = Date()
            let disp2 = coordinator.ingestClipboardContent("Temporary transient token", metadata: transientMeta, now: now)
            assertEqual(disp2, .memoryOnlyEphemeral)
            assertEqual(coordinator.ephemeralClips.count, 1)
            assertEqual(coordinator.persistentClips.count, 0)

            coordinator.runRetentionCycle(now: now.addingTimeInterval(125))
            assertEqual(coordinator.ephemeralClips.count, 0)

            // 10. Verify CLI opt-in security gate & subcommands against temporary encrypted DB
            coordinator.seedSampleDeveloperClipsIfEmpty()
            var cliPrefs = coordDB.loadPreferences()
            cliPrefs.enableCLIAccess = false
            try coordDB.savePreferences(cliPrefs)
            assertEqual(coordDB.loadPreferences().enableCLIAccess, false)

            cliPrefs.enableCLIAccess = true
            try coordDB.savePreferences(cliPrefs)
            assertEqual(coordDB.loadPreferences().enableCLIAccess, true)
            let seededClips = try coordDB.fetchClips()
            assertTrue(seededClips.count >= 6, "Expected 6 seeded developer clips")

            // 11. Regression Tests for Checkbox / Toggle Reactivity & Multi-Process Sync
            let regURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ghost_reg_\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: regURL) }
            let regDB = try SQLiteStorageEngine(databaseURL: regURL, vault: vault)
            let regCoord = ClipboardCoordinator(storage: regDB)

            // 11a. captureRichText checkbox controls Markdown capture
            regCoord.preferences.captureRichText = false
            assertEqual(regCoord.preferences.isCategoryCaptureEnabled(.markdown), false)
            let mdDisp1 = regCoord.ingestClipboardContent("### Release Notes\n- [x] Fixed checkbox bug")
            assertEqual(mdDisp1, .discardImmediately, "Markdown must be skipped when captureRichText is false")
            regCoord.preferences.captureRichText = true
            assertEqual(regCoord.preferences.isCategoryCaptureEnabled(.markdown), true)
            let mdDisp2 = regCoord.ingestClipboardContent("### Release Notes\n- [x] Fixed checkbox bug")
            assertEqual(mdDisp2, .persistStandard, "Markdown must be captured when captureRichText is true")

            // 11b. captureCode checkbox controls both .code and .terminalCommand
            regCoord.preferences.captureCode = false
            assertEqual(regCoord.preferences.isCategoryCaptureEnabled(.code), false)
            assertEqual(regCoord.preferences.isCategoryCaptureEnabled(.terminalCommand), false)
            assertEqual(regCoord.ingestClipboardContent("docker compose up -d"), .discardImmediately)
            regCoord.preferences.captureCode = true
            assertEqual(regCoord.ingestClipboardContent("docker compose up -d"), .persistStandard)

            // 11c. Categories tab per-category toggle (e.g., .hexColor and .json)
            regCoord.setCategoryCaptureEnabled(.hexColor, enabled: false)
            assertEqual(regCoord.preferences.isCategoryCaptureEnabled(.hexColor), false)
            assertEqual(regCoord.ingestClipboardContent("#FF5733"), .discardImmediately)
            regCoord.setCategoryCaptureEnabled(.hexColor, enabled: true)
            assertEqual(regCoord.ingestClipboardContent("#FF5733"), .persistStandard)

            // 11d. neverSaveAPIKeys vs neverSavePasswords independence + live ephemeral purge
            regCoord.preferences.neverSavePasswords = true
            regCoord.preferences.neverSaveAPIKeys = false
            let apiKeyDisp = regCoord.ingestClipboardContent("sk-proj-1234567890abcdefghijklmnopqrstuvwxyzABCD")
            assertEqual(apiKeyDisp, .memoryOnlyEphemeral, "Unchecking neverSaveAPIKeys while neverSavePasswords is true must retain API keys in ephemeral memory")
            assertEqual(regCoord.ephemeralClips.count, 1)
            let dbPassDisp = regCoord.ingestClipboardContent("postgres://user:superSecretPass@db.example.com:5432/prod")
            assertEqual(dbPassDisp, .discardImmediately, "DB password URI must still be discarded when neverSavePasswords is true")
            // Re-checking neverSaveAPIKeys must immediately purge ephemeral credential clips
            regCoord.preferences.neverSaveAPIKeys = true
            assertEqual(regCoord.ephemeralClips.count, 0, "Checking neverSaveAPIKeys must purge existing ephemeral credential clips")

            // 11e. OTP checkbox coupling (neverSaveOTPs <-> allowEphemeralOTP)
            regCoord.preferences.neverSaveOTPs = false
            assertEqual(regCoord.preferences.allowEphemeralOTP, true, "Unchecking neverSaveOTPs must automatically enable allowEphemeralOTP")
            let otpDisp = regCoord.ingestClipboardContent("Your verification code is 918273")
            assertEqual(otpDisp, .memoryOnlyEphemeral)
            assertEqual(regCoord.ephemeralClips.count, 1)
            regCoord.preferences.neverSaveOTPs = true
            assertEqual(regCoord.preferences.allowEphemeralOTP, false)
            assertEqual(regCoord.ephemeralClips.count, 0, "Checking neverSaveOTPs must immediately purge ephemeral OTPs")

            // 11f. Default application exclusion checkbox unchecking works (not overridden by defaultExcludedBundleIDs)
            if let onePassRule = regCoord.applicationExclusions.first(where: { $0.bundleIdentifier == "com.1password.1password" }) {
                regCoord.setApplicationExclusion(onePassRule, isEnabled: false)
                let onePassMeta = PasteboardMetadata(sourceBundleID: "com.1password.1password", sourceAppName: "1Password")
                let allowedDisp = regCoord.ingestClipboardContent("Normal note from 1Password", metadata: onePassMeta)
                assertEqual(allowedDisp, .persistStandard, "Disabling 1Password exclusion checkbox must allow normal clips from 1Password")
                regCoord.setApplicationExclusion(onePassRule, isEnabled: true)
                let blockedDisp = regCoord.ingestClipboardContent("Another note from 1Password", metadata: onePassMeta)
                assertEqual(blockedDisp, .discardImmediately, "Re-enabling 1Password exclusion checkbox must block clips from 1Password")
            } else {
                assertTrue(false, "Expected default 1Password exclusion rule")
            }

            // 11g. Changing standardRetentionDays updates existing unpinned clips' expiresAt
            regCoord.preferences.standardRetentionDays = 7
            if let clip = regCoord.persistentClips.first {
                let expectedRemaining = clip.remainingSeconds(at: Date()) ?? 0
                assertTrue(expectedRemaining > 6 * 86_400 && expectedRemaining <= 7 * 86_400 + 60, "Expected ~7 days remaining after changing standardRetentionDays to 7")
            }

            // 11h. External SQLite preferences update sync (simulating CLI enable-cli while app is running)
            var extPrefs = regDB.loadPreferences()
            extPrefs.enableCLIAccess = true
            Thread.sleep(forTimeInterval: 0.01)
            try regDB.savePreferences(extPrefs)
            regCoord.syncExternalPreferencesIfNeeded()
            assertEqual(regCoord.preferences.enableCLIAccess, true, "Coordinator must pick up external CLI preference changes")

            // 11i. Terminal safety warning icon name typo check
            let termActions = actionsEngine.terminalActions(for: "sudo rm -rf /tmp/*")
            assertEqual(termActions.first?.iconName, "exclamationmark.triangle.fill")

            // 11j. updateClipContent updates persisted clip content (used by interactive Markdown task list checkboxes)
            if let mdClip = regCoord.persistentClips.first(where: { $0.primaryCategory == .markdown }) {
                regCoord.updateClipContent(mdClip, newContent: "### Release Notes\n- [ ] Fixed checkbox bug")
                let updatedMD = regCoord.persistentClips.first(where: { $0.id == mdClip.id })
                assertEqual(updatedMD?.content, "### Release Notes\n- [ ] Fixed checkbox bug")
            }

            // 11k. Unified CLI / GUI Dispatch & Subcommand Verification
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/GhostClipboard"]), false)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/GhostClipboard", "-psn_0_12345"]), false)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/GhostClipboard", "-NSDocumentRevisionsDebugMode", "YES"]), false)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/GhostClipboard", "/Users/dev/custom_arg"]), false)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/GhostClipboard", "status"]), true)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/ghostclipboard"]), true)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/ghostclipboard", "--help"]), true)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/usr/local/bin/ghostclipboard-cli"]), true)

            assertEqual(GhostCLIRunner.run(arguments: ["disable-cli"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["recent"], storage: regDB), 2, "CLI recent must fail with exit code 2 when CLI gate is disabled")
            assertEqual(GhostCLIRunner.run(arguments: ["enable-cli"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["status"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["recent", "--limit", "3", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["search", "docker", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["search", "--limit", "1", "docker", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["search", "--limit", "1"], storage: regDB), 1, "search with only --limit 1 and no query must fail with exit code 1")
            assertEqual(GhostCLIRunner.run(arguments: ["list", "--category", "code", "--limit", "2", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["list", "--category", "invalid_cat"], storage: regDB), 1)
            assertEqual(GhostCLIRunner.run(arguments: ["unknown-cmd"], storage: regDB), 1)
            assertEqual(GhostCLIRunner.run(arguments: ["backup-key"], storage: regDB), 0)

            // 12. Zero-Plaintext On-Disk SQLite Search Index (HMAC-SHA256 Blind Indexing Verification)
            do {
                let blindURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ghost_blind_\(UUID().uuidString).sqlite3")
                defer {
                    try? FileManager.default.removeItem(at: blindURL)
                    try? FileManager.default.removeItem(atPath: blindURL.path + "-wal")
                    try? FileManager.default.removeItem(atPath: blindURL.path + "-shm")
                }

                let blindDB = try SQLiteStorageEngine(databaseURL: blindURL, vault: vault)

                let canaryCode = "func calculateQuantumSignature(payload: Data) -> String { return \"UniqueCanaryPlaintextToken98765\" }"
                let canaryURL = "https://internal-portal.corp.example.com/v2/dashboard?env=.env"
                let canaryColor = "#FF5733"
                let canaryOperator = "if (a === b && status !== 0) { console.log('strict equality'); }"

                try blindDB.saveClip(ClipItem(
                    content: canaryCode,
                    contentHash: CryptoVault.sha256Hex(canaryCode),
                    primaryCategory: .code,
                    detectedLanguage: .swift,
                    sourceApplication: "Xcode"
                ))
                try blindDB.saveClip(ClipItem(
                    content: canaryURL,
                    contentHash: CryptoVault.sha256Hex(canaryURL),
                    primaryCategory: .url,
                    urlHostname: "internal-portal.corp.example.com"
                ))
                try blindDB.saveClip(ClipItem(
                    content: canaryColor,
                    contentHash: CryptoVault.sha256Hex(canaryColor),
                    primaryCategory: .hexColor
                ))
                try blindDB.saveClip(ClipItem(
                    content: canaryOperator,
                    contentHash: CryptoVault.sha256Hex(canaryOperator),
                    primaryCategory: .code,
                    detectedLanguage: .javascript
                ))

                // Consolidate WAL into main SQLite file and inspect raw bytes on disk
                blindDB.checkpointDatabase()
                let rawSQLiteBytes = try Data(contentsOf: blindURL)
                let rawWALBytes = (try? Data(contentsOf: URL(fileURLWithPath: blindURL.path + "-wal"))) ?? Data()
                let combinedDiskBytes = rawSQLiteBytes + rawWALBytes

                let forbiddenPlaintexts = [
                    "calculateQuantumSignature",
                    "UniqueCanaryPlaintextToken98765",
                    "internal-portal.corp.example.com",
                    "strict equality",
                    "#FF5733"
                ]
                for forbidden in forbiddenPlaintexts {
                    let needle = Data(forbidden.utf8)
                    assertNil(
                        combinedDiskBytes.range(of: needle),
                        "Raw SQLite file on disk MUST NOT contain plaintext '\(forbidden)'"
                    )
                }

                // Verify blind index tokens start with "bi_" and contain zero plaintext
                let generatedTokens = vault.blindIndexTokens(for: canaryCode)
                assertTrue(generatedTokens.hasPrefix("bi_"), "Blind index tokens must start with bi_")
                assertTrue(!generatedTokens.contains("calculate"), "Blind index tokens must not contain plaintext words")

                // Verify exact word, camelCase subword, 3+ char prefix, mid-word substring, and symbol searches all succeed!
                assertEqual(try blindDB.searchClips("calculateQuantumSignature").count, 1)
                assertEqual(try blindDB.searchClips("UniqueCanaryPlaintextToken98765").count, 1)
                assertEqual(try blindDB.searchClips("quantum").count, 1, "CamelCase subword search must succeed via blind index")
                assertEqual(try blindDB.searchClips("calc").count, 1, "3+ char prefix search must succeed via blind index")
                assertEqual(try blindDB.searchClips("QuantumSig").count, 1, "Mid-word substring search must succeed via hybrid decrypted scan")
                assertEqual(try blindDB.searchClips("#FF5733").count, 1, "Hex color symbol search must succeed")
                assertEqual(try blindDB.searchClips("===").count, 1, "Operator symbol search must succeed")
                assertEqual(try blindDB.searchClips(".env").count, 1, "Dotfile symbol search must succeed")
                assertEqual(try blindDB.searchClips("internal-portal.corp.example.com").count, 1, "Encrypted hostname search must succeed")
                assertEqual(try blindDB.searchClips("nonexistent_token_xyz_999").count, 0)
            }

            // 13. Persistent SQLite Connection Concurrency & 100-Clip Benchmark
            do {
                let benchURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ghost_bench_\(UUID().uuidString).sqlite3")
                defer {
                    try? FileManager.default.removeItem(at: benchURL)
                    try? FileManager.default.removeItem(atPath: benchURL.path + "-wal")
                    try? FileManager.default.removeItem(atPath: benchURL.path + "-shm")
                }

                let benchDB = try SQLiteStorageEngine(databaseURL: benchURL, vault: vault)
                var batchClips: [ClipItem] = []
                for idx in 0..<100 {
                    let text = "func benchmarkFunction_\(idx)(arg: Int) -> Int { return arg * \(idx) }"
                    batchClips.append(ClipItem(
                        content: text,
                        contentHash: CryptoVault.sha256Hex(text),
                        primaryCategory: .code,
                        detectedLanguage: .swift
                    ))
                }

                let startTime = CFAbsoluteTimeGetCurrent()
                try benchDB.saveClipsBatch(batchClips)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                assertTrue(elapsed < 2.0, "100 clip encrypt+insert+blind-index batch took \(elapsed)s (expected < 2.0s)")
                assertEqual(benchDB.fetchStorageStats().totalClips, 100)
                assertEqual(try benchDB.searchClips("benchmarkFunction_77").count, 1)
            }

            // 14. Pre-Compiled RegexCache & BoundedContentCache Verification
            do {
                let beforeStats = RegexCache.shared.stats
                _ = RegexCache.shared.matches("sk-proj-1234567890abcdefghijklmnopqrstuvwxyzABCD", pattern: #"(?:^|[^A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{28,255}"#)
                _ = RegexCache.shared.matches("sk-proj-1234567890abcdefghijklmnopqrstuvwxyzABCD", pattern: #"(?:^|[^A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{28,255}"#)
                let afterStats = RegexCache.shared.stats
                assertTrue(afterStats.hits >= beforeStats.hits + 1, "Expected RegexCache hits to increment")
                assertTrue(afterStats.count > 0, "Expected non-zero compiled regex count")

                // Edge cases: empty string and invalid regex pattern
                assertEqual(RegexCache.shared.matches("", pattern: #"^[0-9]+$"#), false)
                assertNil(RegexCache.shared.regex(for: "[unclosed_group"))

                // BoundedContentCache hit verification
                let sampleSnippet = "SELECT id, email FROM users WHERE active = 1 ORDER BY id DESC;"
                _ = classifier.classify(content: sampleSnippet)
                let cHitsBefore = BoundedContentCache.shared.stats.hits
                let cachedRes = classifier.classify(content: sampleSnippet)
                let cHitsAfter = BoundedContentCache.shared.stats.hits
                assertEqual(cachedRes.primaryCategory, .code)
                assertEqual(cachedRes.detectedLanguage, .sql)
                assertEqual(cHitsAfter, cHitsBefore + 1, "Expected BoundedContentCache hit on repeated classification")
            }

            // 15. Zero-Idle-Wake Ephemeral Timer Lifecycle & Sleep/Wake Awareness
            do {
                let timerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ghost_timer_\(UUID().uuidString).sqlite3")
                defer { try? FileManager.default.removeItem(at: timerURL) }
                let timerDB = try SQLiteStorageEngine(databaseURL: timerURL, vault: vault)
                let timerCoord = ClipboardCoordinator(storage: timerDB)

                // Initially ephemeralClips is empty -> timer MUST be inactive (0 Hz)
                assertEqual(timerCoord.ephemeralClips.count, 0)
                assertEqual(timerCoord.isEphemeralTimerActive, false, "Ephemeral countdown timer must be nil/inactive when ephemeralClips is empty")
                assertEqual(timerCoord.runtimeEfficiencySnapshot().ephemeralTimerStateText, "Idle (0 Hz — Zero Wake)")

                // Enable ephemeral OTP capture and ingest an OTP -> timer MUST activate
                timerCoord.preferences.neverSaveOTPs = false
                timerCoord.preferences.allowEphemeralOTP = true
                let t0 = Date()
                let disp = timerCoord.ingestClipboardContent("Your verification code is 654321", now: t0)
                assertEqual(disp, .memoryOnlyEphemeral)
                assertEqual(timerCoord.ephemeralClips.count, 1)
                assertEqual(timerCoord.isEphemeralTimerActive, true, "Ephemeral timer must activate immediately when an ephemeral clip is captured")
                assertTrue(timerCoord.runtimeEfficiencySnapshot().ephemeralTimerStateText.contains("Counting down"))

                // Expire the OTP -> timer MUST automatically stop and return to 0 Hz idle
                timerCoord.runRetentionCycle(now: t0.addingTimeInterval(130))
                assertEqual(timerCoord.ephemeralClips.count, 0)
                assertEqual(timerCoord.isEphemeralTimerActive, false, "Ephemeral timer must automatically cancel once ephemeralClips becomes empty")

                // Sleep / Wake awareness
                timerCoord.startMonitoring()
                assertEqual(timerCoord.isSleepingOrScreenLocked, false)
                timerCoord.handleSystemWillSleep()
                assertEqual(timerCoord.isSleepingOrScreenLocked, true)
                assertEqual(timerCoord.runtimeEfficiencySnapshot().isPasteboardPollingPaused, true)
                timerCoord.handleSystemDidWake()
                assertEqual(timerCoord.isSleepingOrScreenLocked, false)
                assertEqual(timerCoord.runtimeEfficiencySnapshot().isPasteboardPollingPaused, false)
                timerCoord.stopMonitoring()

                // Resident memory telemetry sanity check
                let snap = timerCoord.runtimeEfficiencySnapshot()
                assertTrue(snap.residentMemoryBytes > 0, "Expected non-zero resident memory bytes from mach_task_basic_info")
                assertTrue(snap.residentMemoryMB > 0.5 && snap.residentMemoryMB < 2048.0, "Expected reasonable resident RAM in MB")
            }

            // 16. Custom Global Shortcut Preferences & Display Formatting + Direct Paste Preference
            do {
                assertEqual(ShortcutFormatter.displayString(keyCode: 49, carbonModifiers: ShortcutFormatter.carbonOptionKey), "⌥Space")
                assertEqual(ShortcutFormatter.displayString(keyCode: 9, carbonModifiers: ShortcutFormatter.carbonShiftKey | ShortcutFormatter.carbonCmdKey), "⇧⌘V")
                assertEqual(ShortcutFormatter.displayString(keyCode: 49, carbonModifiers: ShortcutFormatter.carbonControlKey | ShortcutFormatter.carbonOptionKey), "⌃⌥Space")
                assertEqual(ShortcutFormatter.displayString(keyCode: 9, carbonModifiers: ShortcutFormatter.carbonControlKey | ShortcutFormatter.carbonShiftKey), "⌃⇧V")

                var prefs = GhostPreferences()
                assertEqual(prefs.hotkeyKeyCode, 49)
                assertEqual(prefs.hotkeyModifiers, 2048)
                assertEqual(prefs.hotkeyDisplayString, "⌥Space")
                assertEqual(prefs.directPasteToActiveApp, false)

                // Updating hotkeyKeyCode / hotkeyModifiers automatically updates hotkeyDisplayString
                prefs.hotkeyKeyCode = 9
                prefs.hotkeyModifiers = ShortcutFormatter.carbonShiftKey | ShortcutFormatter.carbonCmdKey
                assertEqual(prefs.hotkeyDisplayString, "⇧⌘V")
                prefs.directPasteToActiveApp = true

                try regDB.savePreferences(prefs)
                let reloaded = regDB.loadPreferences()
                assertEqual(reloaded.hotkeyKeyCode, 9)
                assertEqual(reloaded.hotkeyModifiers, ShortcutFormatter.carbonShiftKey | ShortcutFormatter.carbonCmdKey)
                assertEqual(reloaded.hotkeyDisplayString, "⇧⌘V")
                assertEqual(reloaded.directPasteToActiveApp, true)
            }

            // 17. New Developer Actions: JWT Inspector, Base64 Encode/Decode, cURL -> JS fetch / Swift URLRequest, Timestamps, Markdown Fence, Paste Stack
            do {
                // 17a. JWT Inspector
                let sampleJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzQyIiwiaXNzIjoiZ2hvc3RjbGlwYm9hcmQiLCJleHAiOjE4OTM0NTYwMDAsImlhdCI6MTcwMDAwMDAwMH0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
                let decodedJWT = actionsEngine.decodeJWT("Bearer " + sampleJWT, now: Date(timeIntervalSince1970: 1_750_000_000))
                assertNotNil(decodedJWT, "Expected 3-part JWT with Bearer prefix to decode")
                assertEqual(decodedJWT?.algorithm, "HS256")
                assertEqual(decodedJWT?.subject, "user_42")
                assertEqual(decodedJWT?.issuer, "ghostclipboard")
                assertEqual(decodedJWT?.isExpired, false)
                assertTrue(decodedJWT?.claimsJSON.contains("user_42") == true)

                let jwtClip = ClipItem(
                    content: sampleJWT,
                    contentHash: CryptoVault.sha256Hex(sampleJWT),
                    primaryCategory: .credential,
                    sensitivityLevel: .ephemeralSecret,
                    isEphemeral: true
                )
                let jwtActions = actionsEngine.availableActions(for: jwtClip)
                assertTrue(jwtActions.contains(where: { $0.id == "jwt.decode" }), "Expected jwt.decode action for JWT clip")

                // 17b. Base64 Encode & Decode
                let originalText = "GhostClipboard-ZeroPlaintext-Index-2026"
                let b64 = actionsEngine.base64Encode(originalText)
                assertEqual(actionsEngine.base64Decode(b64), originalText)
                assertNil(actionsEngine.base64Decode("hello"), "Short plain English word without padding must not be treated as Base64")

                // 17c. cURL -> JS fetch() & Swift URLRequest
                let curlCmd = """
                curl -X POST https://api.example.com/v1/embeddings \\
                  -H "Authorization: Bearer tok_123" \\
                  -H "Content-Type: application/json" \\
                  -d '{"input":"clipboard text","model":"embed-small"}'
                """
                let jsFetch = actionsEngine.convertCurlToJSFetch(curlCmd)
                assertNotNil(jsFetch)
                assertTrue(jsFetch?.contains("fetch(\"https://api.example.com/v1/embeddings\"") == true)
                assertTrue(jsFetch?.contains("method: \"POST\"") == true)
                assertTrue(jsFetch?.contains("\"Authorization\": \"Bearer tok_123\"") == true)

                let swiftReq = actionsEngine.convertCurlToSwiftURLRequest(curlCmd)
                assertNotNil(swiftReq)
                assertTrue(swiftReq?.contains("URLRequest(url: url)") == true)
                assertTrue(swiftReq?.contains("request.httpMethod = \"POST\"") == true)
                assertTrue(swiftReq?.contains("forHTTPHeaderField: \"Authorization\"") == true)

                let curlActions = actionsEngine.terminalActions(for: curlCmd)
                assertTrue(curlActions.contains(where: { $0.id == "curl.to_fetch" }))
                assertTrue(curlActions.contains(where: { $0.id == "curl.to_swift" }))

                // 17d. Unix Epoch & ISO-8601 Timestamp Converter
                let tsSec = actionsEngine.parseTimestamp("1700000000")
                assertNotNil(tsSec)
                assertEqual(tsSec?.epochSeconds, 1_700_000_000)
                assertEqual(tsSec?.epochMilliseconds, 1_700_000_000_000)
                assertEqual(tsSec?.iso8601UTC, "2023-11-14T22:13:20Z")

                let tsMs = actionsEngine.parseTimestamp("1700000000000")
                assertEqual(tsMs?.iso8601UTC, "2023-11-14T22:13:20Z")

                let tsISO = actionsEngine.parseTimestamp("2023-11-14T22:13:20Z")
                assertEqual(tsISO?.epochSeconds, 1_700_000_000)

                assertNil(actionsEngine.parseTimestamp("42"), "Small integer must not be parsed as Unix timestamp")

                // 17e. Markdown Code Fence & Paste Stack / UUID Generator
                let fencedSwift = actionsEngine.formatAsMarkdownCodeFence("let x = 1", language: .swift, category: .code)
                assertEqual(fencedSwift, "```swift\nlet x = 1\n```")

                let genUUID = regCoord.generateAndCopyUUID()
                assertEqual(genUUID.count, 36)
                assertNotNil(UUID(uuidString: genUUID))

                let mergedRecent = regCoord.copyMergedClips(pinnedOnly: false, limit: 2, separator: "\n---\n")
                assertTrue(!mergedRecent.isEmpty && mergedRecent.contains("\n---\n"))

                // 18. Deep Edge-Case Regression Suite (Long Clip Blind Index, 17..23-char Prefixes, Punctuation/Emoji Search, Override Category Sync, Function/Arrow Hotkeys, Paused Timer, cURL/JWT/Timestamp Edge Cases)
                let edgeURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("ghost_edge_\(UUID().uuidString).sqlite3")
                defer {
                    try? FileManager.default.removeItem(at: edgeURL)
                    try? FileManager.default.removeItem(atPath: edgeURL.path + "-wal")
                    try? FileManager.default.removeItem(atPath: edgeURL.path + "-shm")
                }
                let edgeDB = try SQLiteStorageEngine(databaseURL: edgeURL, vault: vault)

                // 18a. Long clip (>55 words) + 17..23 char prefix + camelCase tail blind indexing
                let fillerWords = (1...55).map { "fillerIdentifierWord\($0)" }.joined(separator: " ")
                let longClipText = "\(fillerWords) authenticationProviderConfiguration TailCanaryToken55"
                let longClip = ClipItem(
                    content: longClipText,
                    contentHash: CryptoVault.sha256Hex(longClipText),
                    primaryCategory: .code,
                    detectedLanguage: .swift,
                    sourceApplication: "Xcode"
                )
                try edgeDB.saveClip(longClip)

                // Verify the 56th+ words are present in the blind index tokens directly (not starved by prefixes of words 1..30)
                let longBlindTokens = vault.blindIndexTokens(for: longClipText)
                let tailTokenHash = vault.blindIndexToken(for: "tailcanarytoken55")
                let longPrefix18Hash = vault.blindIndexToken(for: "authenticationprov") // 18-char prefix (>16)
                assertTrue(longBlindTokens.contains(tailTokenHash), "56th word in clip must not be dropped from blind index")
                assertTrue(longBlindTokens.contains(longPrefix18Hash), "18-char prefix must be present in blind index")
                assertEqual(try edgeDB.searchClips("authenticationProv").count, 1, "18-char prefix search must match")
                assertEqual(try edgeDB.searchClips("TailCanaryToken55").count, 1, "Word after 50+ earlier words must match")

                // 18b. Emoji + Punctuation multi-word queries
                let emojiClipText = "🚀 Deploy production release v2.4.0 to cluster"
                try edgeDB.saveClip(ClipItem(
                    content: emojiClipText,
                    contentHash: CryptoVault.sha256Hex(emojiClipText),
                    primaryCategory: .plainText,
                    sourceApplication: "Terminal"
                ))
                assertEqual(try edgeDB.searchClips("🚀 deploy").count, 1, "Emoji + word query must match")
                assertEqual(try edgeDB.searchClips("deploy, release").count, 1, "Comma-punctuated multi-word query must match")
                assertEqual(try edgeDB.searchClips("Xcode: TailCanaryToken55").count, 1, "Colon-punctuated app + token query must match")

                // 18c. overrideCategory updates clip_category_assignments and clips_fts
                try edgeDB.overrideCategory(clipID: longClip.id, newCategory: .json)
                assertEqual(try edgeDB.fetchClips(category: .code).count, 0, "Old category assignment must be replaced on overrideCategory")
                assertEqual(try edgeDB.fetchClips(category: .json).count, 1, "New category assignment must be active after overrideCategory")

                // 18d. Function keys (F1-F12), Arrow keys, and Modifier-only keyCode guard in ShortcutFormatter
                assertEqual(ShortcutFormatter.displayString(keyCode: 122, carbonModifiers: ShortcutFormatter.carbonCmdKey), "⌘F1")
                assertEqual(ShortcutFormatter.displayString(keyCode: 111, carbonModifiers: ShortcutFormatter.carbonOptionKey | ShortcutFormatter.carbonShiftKey), "⌥⇧F12")
                assertEqual(ShortcutFormatter.displayString(keyCode: 123, carbonModifiers: ShortcutFormatter.carbonControlKey | ShortcutFormatter.carbonOptionKey), "⌃⌥←")
                assertEqual(ShortcutFormatter.displayString(keyCode: 126, carbonModifiers: ShortcutFormatter.carbonCmdKey), "⌘↑")
                assertEqual(ShortcutFormatter.isModifierOnlyKeyCode(55), true, "kVK_Command must be recognized as modifier-only")
                assertEqual(ShortcutFormatter.isModifierOnlyKeyCode(56), true, "kVK_Shift must be recognized as modifier-only")
                assertEqual(ShortcutFormatter.isModifierOnlyKeyCode(49), false, "kVK_Space must not be modifier-only")

                // 18e. Paused monitoring actually cancels pasteboardTimer
                let edgeCoord = ClipboardCoordinator(storage: edgeDB)
                edgeCoord.startMonitoring()
                assertEqual(edgeCoord.runtimeEfficiencySnapshot().isPasteboardPollingPaused, false)
                edgeCoord.preferences.monitoringPaused = true
                assertEqual(edgeCoord.runtimeEfficiencySnapshot().isPasteboardPollingPaused, true)
                edgeCoord.preferences.monitoringPaused = false
                assertEqual(edgeCoord.runtimeEfficiencySnapshot().isPasteboardPollingPaused, false)
                edgeCoord.stopMonitoring()

                // 18f. Quoted JWT, cURL with -XPOST / -o / localhost / multiple -d, and SQL space-separated timestamps
                let quotedJWT = "\"\(sampleJWT)\""
                assertNotNil(actionsEngine.decodeJWT(quotedJWT), "Quoted JWT string literal must decode cleanly")

                let trickyCurl = "curl -XPOST -o output.json -A 'Mozilla/5.0' -d 'a=1' -d 'b=2' localhost:8080/graphql"
                let trickyFetch = actionsEngine.convertCurlToJSFetch(trickyCurl)
                assertNotNil(trickyFetch)
                assertTrue(trickyFetch?.contains("fetch(\"http://localhost:8080/graphql\"") == true, "Must not confuse output.json or Mozilla/5.0 with target URL")
                assertTrue(trickyFetch?.contains("method: \"POST\"") == true, "Attached -XPOST flag must be parsed")
                assertTrue(trickyFetch?.contains("a=1&b=2") == true, "Multiple -d flags must be combined with &")

                let sqlTimestamp = actionsEngine.parseTimestamp("2023-11-14 22:13:20")
                assertNotNil(sqlTimestamp, "Space-separated SQL timestamp must parse")
                assertEqual(sqlTimestamp?.epochSeconds, 1_700_000_000)

                assertTrue(vault.keyStorageSummary().contains("HKDF Blind-Index Subkey"))
            }
        } catch {
            failedCount += 1
            fputs("❌ Unexpected error during storage/coordinator tests: \(error)\n", stderr)
        }

        print("✅ Assertions Passed: \(passedCount) | ❌ Failed: \(failedCount)")
        fflush(stdout)
        Foundation.exit(failedCount > 0 ? 1 : 0)
    }
}
