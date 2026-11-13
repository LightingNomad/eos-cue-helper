#!/bin/bash
# Builds "EOS Cue Helper.app".
#   ./build.sh            build into ./build
#   ./build.sh install    build and copy to /Applications (quits the running copy first)
#   ./build.sh zip        build and zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="EOS Cue Helper"
EXEC="EOSCueHelper"
BUNDLE_ID="com.lightingnomad.eoscuehelper"
REPO="${GITHUB_REPO:-LightingNomad/eos-cue-helper}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▸ Compiling ${APP_NAME} ${VERSION}…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXEC"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>EOS Cue Helper turns pages in the Cuelist tab in Google Chrome.</string>
  <key>NSLocalNetworkUsageDescription</key><string>EOS Cue Helper talks to your EOS console over OSC.</string>
  <key>GitHubRepo</key><string>$REPO</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (required on Apple Silicon; no developer account needed).
codesign --force --deep --sign - "$APP"
echo "✓ Built $APP"

case "${1:-}" in
  install)
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    echo "✓ Installed to /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    ;;
  zip)
    ZIP="build/EOS-Cue-Helper-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "✓ $ZIP"
    ;;
esac
