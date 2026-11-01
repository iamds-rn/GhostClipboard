import Foundation
import CryptoKit
import GhostClipboardCore

@main
struct GhostClipboardTestRunner {
    private static var passedCount = 0
    private static var failedCount = 0

    static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        if condition() {
            passedCount += 1
        } else {
            failedCount += 1
            fputs("❌ Assertion failed at \(file):\(line) — \(message)\n", stderr)
        }
    }

    static func assertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String = "", file: String = #file, line: Int = #line) {
        let l = lhs()
        let r = rhs()
        if l == r {
            passedCount += 1
        } else {
            failedCount += 1
            fputs("❌ Assertion failed at \(file):\(line) — Expected \(r), got \(l). \(message)\n", stderr)
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
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/GhostClipboard", "status"]), true)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/Applications/GhostClipboard.app/Contents/MacOS/ghostclipboard", "--help"]), true)
            assertEqual(GhostCLIRunner.shouldDispatchCLI(from: ["/usr/local/bin/ghostclipboard-cli"]), true)

            assertEqual(GhostCLIRunner.run(arguments: ["disable-cli"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["recent"], storage: regDB), 2, "CLI recent must fail with exit code 2 when CLI gate is disabled")
            assertEqual(GhostCLIRunner.run(arguments: ["enable-cli"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["status"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["recent", "--limit", "3", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["search", "docker", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["list", "--category", "code", "--json"], storage: regDB), 0)
            assertEqual(GhostCLIRunner.run(arguments: ["list", "--category", "invalid_cat"], storage: regDB), 1)
            assertEqual(GhostCLIRunner.run(arguments: ["unknown-cmd"], storage: regDB), 1)
        } catch {
            failedCount += 1
            fputs("❌ Unexpected error during storage/coordinator tests: \(error)\n", stderr)
        }

        print("✅ Assertions Passed: \(passedCount) | ❌ Failed: \(failedCount)")
        fflush(stdout)
        Foundation.exit(failedCount > 0 ? 1 : 0)
    }
}
