#!/bin/bash
set -e

# LocalWhisper Release Script
# Creates a distributable .app bundle and DMG

VERSION="${1:-1.0.0}"
APP_NAME="LocalWhisper"
BUNDLE_ID="com.localwhisper.app"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "🚀 Building LocalWhisper v$VERSION"
echo "================================"

# Clean previous builds
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build release version
echo "📦 Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

# Derive the canonical repo URL from the git remote so the About screen link
# always matches wherever the repo lives — no manual updates needed.
REPO_URL=$(git remote get-url origin \
    | sed 's|git@github.com:|https://github.com/|' \
    | sed 's|\.git$||')

# Create app bundle structure
echo "📁 Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/LocalWhisper" "$APP_BUNDLE/Contents/MacOS/"

# Copy icon
if [ -f "$PROJECT_DIR/LocalWhisper/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/LocalWhisper/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
elif [ -f "$PROJECT_DIR/LocalWhisper.app/Contents/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/LocalWhisper.app/Contents/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>LocalWhisper needs microphone access to record audio for voice-to-text transcription.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Startr LLC. Licensed under AGPL-3.0. Based on LocalWhisper (MIT, 2024).</string>
    <key>RepoURL</key>
    <string>$REPO_URL</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Sign the app with a persistent identity so macOS TCC entries
# (Accessibility, Microphone, etc.) survive rebuilds. The "LocalWhisper Dev"
# identity is created once per machine by `make setup` — without it,
# codesign falls back to ad-hoc signing and every rebuild orphans the
# user's permissions. Fail loudly with a fix hint if it's missing.
SIGN_IDENTITY="LocalWhisper Dev"
# NOT using `-v` — that flag filters to chain-trusted identities and excludes
# our self-signed dev cert. codesign accepts untrusted identities as long as
# the private key is present and the cert has the code-signing EKU.
if ! security find-identity -p codesigning login.keychain 2>/dev/null \
    | grep -q "\"$SIGN_IDENTITY\""; then
    echo "❌ Code-signing identity '$SIGN_IDENTITY' not found in login keychain."
    echo "   Run: make setup"
    echo "   (creates a persistent self-signed identity so TCC permissions"
    echo "    survive rebuilds — otherwise hotkeys/auto-paste break after"
    echo "    every \`make app\`.)"
    exit 1
fi
echo "🔐 Signing app with '$SIGN_IDENTITY'..."
# NOT using --options runtime here. Hardened runtime requires specific
# entitlements (com.apple.security.device.audio-input for the mic,
# com.apple.security.cs.disable-library-validation for SPM, etc.) that
# this app doesn't yet ship — without them, AVCaptureDevice.requestAccess
# silently fails in the kernel and macOS never surfaces a permission
# prompt. Hardened runtime becomes mandatory only at notarization time;
# until then, leave it off so dev builds Just Work.
codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --identifier com.localwhisper.app \
    "$APP_BUNDLE"

# Verify the app
echo "✅ Verifying app bundle..."
codesign --verify --verbose "$APP_BUNDLE"

# Get app size
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo "📊 App size: $APP_SIZE"

# Create DMG via create-dmg (Homebrew-installable; mirrors Startr canonical pattern).
echo "💿 Creating DMG..."
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
BACKGROUND="$PROJECT_DIR/assets/dmg_background.png"
VOLICON="$PROJECT_DIR/LocalWhisper/Resources/AppIcon.icns"

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "❌ create-dmg not found. Install with: brew install create-dmg"
    echo "   (Or run 'make setup' from the project root.)"
    exit 1
fi
if [ ! -f "$BACKGROUND" ]; then
    echo "❌ DMG background missing: $BACKGROUND"
    echo "   Run 'make setup' or 'swift scripts/make-dmg-background.swift $BACKGROUND'"
    exit 1
fi

# Remove any stale DMG at the destination (create-dmg refuses to overwrite).
rm -f "$DMG_PATH"

# create-dmg handles the layout-aware DMG end-to-end:
#   - styled Finder window (toolbar/sidebar hidden, icon view, sized)
#   - LocalWhisper.app + Applications symlink at named coordinates
#   - background picture
#   - volume icon (matches the app icon so the mounted disk reads as LocalWhisper)
create-dmg \
    --volname "$APP_NAME" \
    --volicon "$VOLICON" \
    --background "$BACKGROUND" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 140 190 \
    --app-drop-link 400 190 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_BUNDLE"

# Also create a ZIP for GitHub releases
echo "📦 Creating ZIP..."
ZIP_NAME="$APP_NAME-$VERSION.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
cd "$DIST_DIR"
zip -r "$ZIP_NAME" "$APP_NAME.app"

# Get final sizes
DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)

echo ""
echo "================================"
echo "✅ Release build complete!"
echo "================================"
echo ""
echo "📁 Output directory: $DIST_DIR"
echo ""
echo "Files created:"
echo "  • $APP_NAME.app ($APP_SIZE)"
echo "  • $DMG_NAME ($DMG_SIZE)"
echo "  • $ZIP_NAME ($ZIP_SIZE)"
echo ""
echo "To install:"
echo "  1. Open $DMG_NAME"
echo "  2. Drag LocalWhisper to Applications"
echo "  3. Open LocalWhisper from Applications"
echo "  4. Grant Microphone and Accessibility permissions when prompted"
echo ""
echo "For GitHub release, upload: $ZIP_PATH"
