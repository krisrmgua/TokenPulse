#!/bin/bash
# Assembles TokenPulse.app from the SwiftPM release build.
# A real bundle (with a bundle identifier + LSUIElement) is required for
# UserNotifications to work and is the artifact Jamf ships.
set -euo pipefail
cd "$(dirname "$0")"

# Side-by-side with Electron: APP_NAME=TokenPulse-Swift BUNDLE_ID=com.kris.tokenpulse.swift ./make-app.sh
APP_NAME="${APP_NAME:-TokenPulse}"
BUNDLE_ID="${BUNDLE_ID:-com.kris.tokenpulse}"
APP="${APP_NAME}.app"
DISPLAY_NAME="${DISPLAY_NAME:-$APP_NAME}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TokenPulse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenPulse"
cp Artwork/TokenPulse.icns "$APP/Contents/Resources/TokenPulse.icns"
cp Artwork/TokenPulseMark.png "$APP/Contents/Resources/TokenPulseMark.png"
# Ship pricing.json inside the bundle so cost works without a repo checkout.
cp ../pricing.json "$APP/Contents/Resources/pricing.json" 2>/dev/null || true

# Provider marks ship in the repo, so a Mac without ChatGPT or Grok Bot
# still gets the real logos instead of an SF Symbol.
cp Artwork/icon-chatgpt.png "$APP/Contents/Resources/icon-chatgpt.png"
cp Artwork/icon-grokbot.png "$APP/Contents/Resources/icon-grokbot.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>TokenPulse</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>TokenPulse.icns</string>
  <key>CFBundleIconName</key><string>TokenPulse</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Kristopher Simmons</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so notifications + launch work locally (Jamf re-signs for prod).
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $PWD/$APP"
