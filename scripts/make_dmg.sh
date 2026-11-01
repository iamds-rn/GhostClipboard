#!/usr/bin/env zsh
# Builds a drag-to-install disk image: dist/GhostClipboard-<version>.dmg
# Usage: ./scripts/make_dmg.sh            (uses existing dist/GhostClipboard.app)
#        ./scripts/make_dmg.sh --rebuild  (rebuilds the app bundle first)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="GhostClipboard"
APP_PATH="dist/${APP_NAME}.app"

if [[ "${1:-}" == "--rebuild" || ! -d "${APP_PATH}" ]]; then
    ./scripts/bundle_app.sh
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
VOL_NAME="${APP_NAME} ${VERSION}"
DMG_FINAL="dist/${APP_NAME}-${VERSION}.dmg"
DMG_TEMP="dist/.${APP_NAME}-temp.dmg"
STAGING="dist/.dmg-staging"

echo "Packaging ${VOL_NAME}..."

# Detach any stale mount of the same volume name
if [[ -d "/Volumes/${VOL_NAME}" ]]; then
    hdiutil detach "/Volumes/${VOL_NAME}" -force -quiet || true
fi

rm -rf "${STAGING}" "${DMG_TEMP}" "${DMG_FINAL}"
mkdir -p "${STAGING}"

ditto "${APP_PATH}" "${STAGING}/${APP_NAME}.app"
ln -s /Applications "${STAGING}/Applications"

cat > "${STAGING}/If macOS blocks the app.txt" <<'EOF'
GhostClipboard is free, open-source, and not yet notarized by Apple,
so macOS may show "Apple could not verify GhostClipboard..." the first time.

To open it:
  1. Drag GhostClipboard into the Applications folder.
  2. Open it once (macOS will block it - click Done).
  3. Open System Settings > Privacy & Security.
  4. Scroll down and click "Open Anyway" next to GhostClipboard.
  5. Confirm with your password or Touch ID.

You only need to do this once.

Alternative (Terminal):
  xattr -dr com.apple.quarantine /Applications/GhostClipboard.app

Source code: https://github.com/iamds-rn/GhostClipboard
EOF

# Read-write image so we can lay out the Finder window
hdiutil create -srcfolder "${STAGING}" -volname "${VOL_NAME}" -fs HFS+ \
    -format UDRW -ov "${DMG_TEMP}" -quiet

MOUNT_DIR="/Volumes/${VOL_NAME}"
hdiutil attach "${DMG_TEMP}" -readwrite -noverify -noautoopen -quiet

# Best-effort window layout (skipped silently in headless CI)
osascript <<EOF || echo "   (Finder layout skipped)"
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 760, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        set position of item "${APP_NAME}.app" of container window to {140, 150}
        set position of item "Applications" of container window to {420, 150}
        set position of item "If macOS blocks the app.txt" of container window to {280, 310}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

sync
hdiutil detach "${MOUNT_DIR}" -quiet || hdiutil detach "${MOUNT_DIR}" -force -quiet

hdiutil convert "${DMG_TEMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_FINAL}" -quiet
rm -rf "${STAGING}" "${DMG_TEMP}"

# Sign the disk image itself (ad-hoc unless a Developer ID is installed)
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"Developer ID Application:' | head -n 1 | awk -F'"' '{print $2}' || true)
codesign --force --sign "${SIGN_IDENTITY:--}" "${DMG_FINAL}"

hdiutil verify "${DMG_FINAL}" -quiet
shasum -a 256 "${DMG_FINAL}" | tee "${DMG_FINAL}.sha256"
echo "✅ Built ${DMG_FINAL} ($(du -h "${DMG_FINAL}" | cut -f1))"
