# Contributing to GhostClipboard

Thank you for your interest in contributing to **GhostClipboard**! Every improvement to secret detection, developer actions, performance, and macOS UX helps keep developers' clipboards fast and private.

---

## Project Architecture

GhostClipboard is structured as a modular Swift 5.9 package (`Package.swift`) with zero external third-party dependencies—relying exclusively on native Apple frameworks (`AppKit`, `SwiftUI`, `CryptoKit`, `Security`, `LocalAuthentication`, `Carbon`) and system `libsqlite3`.

```text
GhostClipboard/
├── Sources/
│   ├── GhostClipboardCore/              # Core library (UI-independent, fully testable)
│   │   ├── Actions/
│   │   │   └── DeveloperActionsEngine.swift      # JSON, JWT, cURL, Timestamp, Color, Markdown, Case & Encoding transforms
│   │   ├── CLI/
│   │   │   └── GhostCLIRunner.swift              # Subcommand parser & execution for `ghostclipboard`
│   │   ├── Clipboard/
│   │   │   ├── AccessibilityPasteHelper.swift    # Direct Paste (⌘V synthesis via CGEvent)
│   │   │   ├── ClipboardCoordinator.swift        # Pasteboard monitor, ephemeral/quarantine queues, NSCache
│   │   │   └── RuntimeTelemetry.swift            # Mach task_vm_info RSS memory & latency telemetry
│   │   ├── Intelligence/
│   │   │   ├── ContentClassificationEngine.swift # 9 categories & 17-language code classifier
│   │   │   └── RegexCache.swift                  # Thread-safe pre-compiled NSRegularExpression cache
│   │   ├── Models/
│   │   │   └── CoreModels.swift                  # SensitivityLevel, ClipCategory, ClipRecord, GhostPreferences
│   │   ├── Security/
│   │   │   ├── CryptoVault.swift                 # AES-256-GCM encryption + HKDF/HMAC-SHA256 blind indexing
│   │   │   └── SensitiveContentEngine.swift      # Pre-persistence secret, PEM, token, entropy & OTP detector
│   │   └── Storage/
│   │       └── SQLiteStorageEngine.swift         # Encrypted SQLite WAL engine + zero-plaintext FTS5 table
│   │
│   ├── GhostClipboardApp/               # Native macOS AppKit + SwiftUI executable target
│   │   ├── GhostClipboardApp.swift               # Menu bar extra, global Carbon hotkey, NSPanel controller
│   │   ├── Theme/
│   │   │   └── DesignSystem.swift                # Dark-glass color tokens, badges, typography
│   │   └── Views/
│   │       ├── FloatingPaletteView.swift         # ⌥Space quick palette UI
│   │       ├── ClipDetailPreviewView.swift       # Rich preview & Developer Actions bar
│   │       ├── FullHistoryWindowView.swift       # 3-pane workspace + Live Detector Sandbox
│   │       └── SettingsAndOnboardingView.swift   # Security, shortcut recorder, retention & exclusions
│   │
│   └── GhostClipboardCLI/               # Standalone CLI executable target (`ghostclipboard-cli`)
│       └── GhostClipboardCLI.swift
│
├── Tests/
│   └── GhostClipboardTests/             # Self-contained verification runner (247 assertions)
│       └── GhostClipboardTests.swift
│
├── Resources/
│   ├── AppIcon.icns                     # Native macOS icon bundle
│   └── GhostClipboard.entitlements      # Hardened runtime entitlements
└── scripts/
    ├── bundle_app.sh                    # Builds & signs dist/GhostClipboard.app
    ├── build_app_bundle.sh
    └── generate_app_icon.swift
```

---

## Development Workflow

### 1. Clone & Build
```bash
git clone https://github.com/iamds-rn/GhostClipboard.git
cd GhostClipboard
swift build
```

### 2. Run the Automated Verification Suite
Before submitting any pull request, run the full test suite and ensure all assertions pass with zero warnings:
```bash
swift run GhostClipboardTests
```

### 3. Build & Verify the Signed `.app` Bundle
If your change touches `Sources/GhostClipboardApp`, `Resources/`, or `scripts/`, verify that the release bundle packages and passes `codesign --verify`:
```bash
./scripts/bundle_app.sh
```

---

## Coding & Security Standards

1. **Zero Plaintext Leakage**: Never store unencrypted clip content, previews, or raw search words in SQLite tables (`clips` or `clips_fts`), logs, or `UserDefaults`. All FTS indexing must go through `CryptoVault.blindIndexTokens(for:)`.
2. **Pre-Compilation for Hot Paths**: Any regular expression used in `SensitiveContentEngine` or `ContentClassificationEngine` must be retrieved through `RegexCache.shared` rather than compiled per clipboard event.
3. **Idle Resource Discipline**: Background timers must not spin when idle. The ephemeral countdown timer in `ClipboardCoordinator` must remain cancelled (`0 Hz`) whenever `ephemeralItems` and `quarantinedItems` are empty or monitoring is paused.
4. **Add Regression Assertions**: Every new secret signature, developer action, or bug fix must include corresponding assertions in `Tests/GhostClipboardTests/GhostClipboardTests.swift`.

---

## Submitting Pull Requests

1. Fork the repository and create a feature or fix branch (`git checkout -b feat/your-feature`).
2. Add tests in `Tests/GhostClipboardTests/GhostClipboardTests.swift`.
3. Verify `swift build -c release` and `swift run GhostClipboardTests` succeed.
4. Open a Pull Request with a clear summary of the motivation, design, and test coverage.
