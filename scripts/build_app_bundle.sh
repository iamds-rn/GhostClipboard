#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building GhostClipboard release binaries..."
swift build -c release

APP_NAME="GhostClipboard.app"
BUILD_DIR=".build/release"
BUNDLE_DIR="dist/${APP_NAME}"

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BUILD_DIR}/GhostClipboard" "${BUNDLE_DIR}/Contents/MacOS/GhostClipboard"
cp "${BUILD_DIR}/ghostclipboard-cli" "${BUNDLE_DIR}/Contents/MacOS/ghostclipboard-cli"
cp "${BUILD_DIR}/ghostclipboard-cli" "${BUNDLE_DIR}/Contents/Resources/ghostclipboard"
cp "${BUILD_DIR}/ghostclipboard-cli" "dist/ghostclipboard"

cat > "${BUNDLE_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>GhostClipboard</string>
    <key>CFBundleIdentifier</key>
    <string>com.ghostclipboard.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GhostClipboard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Packaged macOS app bundle at: $(pwd)/${BUNDLE_DIR}"
