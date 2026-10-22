#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) release of Arcky and packages it for sharing:
#   dist/Arcky.app, dist/Arcky-<version>.dmg (drag to Applications) and dist/Arcky-<version>.zip
# Usage: scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DIST="dist"
APP="$DIST/Arcky.app"

echo "Building Arcky $VERSION (universal release)…"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -vE "x86_64 architecture is deprecated" || true
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Arcky" "$APP/Contents/MacOS/Arcky"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Arcky.sdef Support/AppIcon.icns "$APP/Contents/Resources/"

# No Developer ID certificate is available, so the app is signed ad hoc. macOS asks the
# person opening it to approve it once (see "Read Me First").
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --strict "$APP"

# Zip, for GitHub releases.
ditto -c -k --keepParent "$APP" "$DIST/Arcky-$VERSION.zip"

# DMG with the app, an Applications shortcut and install notes.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<EOF
Arcky $VERSION (test build)

1. Drag Arcky into the Applications folder.
2. Open Arcky. macOS will say it can't verify the app. That's expected for test
   builds that aren't distributed through Apple. Click Done (not Move to Trash).
3. Open System Settings > Privacy & Security, scroll down, and click "Open Anyway"
   next to the message about Arcky. Confirm with your password or Touch ID.
4. Arcky opens with a short welcome guide. You only need to do this once.

Needs macOS 15 (Sequoia) or later, on an Apple Silicon or Intel Mac.
EOF
hdiutil create -volname "Arcky $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Arcky-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
# A fixed name too, so "latest release" links always find it.
cp "$DIST/Arcky-$VERSION.dmg" "$DIST/Arcky.dmg"

echo "Done:"
ls -lh "$DIST" | tail -n +2
