#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "1. Generating native macOS AppIcon.icns..."
if [[ ! -f "Resources/AppIcon.icns" ]]; then
    swift scripts/generate_app_icon.swift
fi

echo "2. Building GhostClipboard release binaries..."
swift build -c release

APP_NAME="GhostClipboard.app"
BUILD_DIR=".build/release"
BUNDLE_DIR="dist/${APP_NAME}"
ENTITLEMENTS="Resources/GhostClipboard.entitlements"

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BUILD_DIR}/GhostClipboard" "${BUNDLE_DIR}/Contents/MacOS/GhostClipboard"
cp "${BUILD_DIR}/ghostclipboard-cli" "${BUNDLE_DIR}/Contents/MacOS/ghostclipboard-cli"
cp "${BUILD_DIR}/ghostclipboard-cli" "${BUNDLE_DIR}/Contents/Resources/ghostclipboard"
cp "${BUILD_DIR}/ghostclipboard-cli" "dist/ghostclipboard"
cp "Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

cat > "${BUNDLE_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>GhostClipboard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.ghostclipboard.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GhostClipboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>GhostClipboard uses Apple Events and Accessibility only when Direct Paste (⌘V synthesis) is explicitly enabled by the user.</string>
</dict>
</plist>
EOF

echo "3. Signing app bundle and CLI binaries with Hardened Runtime Entitlements..."
SIGN_IDENTITY="${GHOST_SIGN_IDENTITY:-}"
if [[ -z "${SIGN_IDENTITY}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development):' | head -n 1 | awk -F'"' '{print $2}' || true)
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "   Found Apple signing certificate: ${SIGN_IDENTITY}"
    codesign --force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}/Contents/MacOS/ghostclipboard-cli"
    codesign --force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}/Contents/Resources/ghostclipboard"
    codesign --force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}" "dist/ghostclipboard"
    codesign --force --deep --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}" "${BUNDLE_DIR}"

    if [[ -n "${GHOST_NOTARIZE_PROFILE:-}" ]]; then
        echo "4. Submitting to Apple Notary Service (profile: ${GHOST_NOTARIZE_PROFILE})..."
        ZIP_PATH="dist/GhostClipboard-notarize.zip"
        ditto -c -k --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"
        xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${GHOST_NOTARIZE_PROFILE}" --wait
        xcrun stapler staple "${BUNDLE_DIR}"
        rm -f "${ZIP_PATH}"
    fi
else
    echo "   No Developer ID certificate found in Keychain; applying ad-hoc signature with entitlements..."
    codesign --force --entitlements "${ENTITLEMENTS}" --sign - "${BUNDLE_DIR}/Contents/MacOS/ghostclipboard-cli"
    codesign --force --entitlements "${ENTITLEMENTS}" --sign - "${BUNDLE_DIR}/Contents/Resources/ghostclipboard"
    codesign --force --entitlements "${ENTITLEMENTS}" --sign - "dist/ghostclipboard"
    codesign --force --deep --entitlements "${ENTITLEMENTS}" --sign - "${BUNDLE_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}" 2>&1 || true
echo "✅ Packaged & signed macOS app bundle at: $(pwd)/${BUNDLE_DIR}"
