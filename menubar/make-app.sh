#!/bin/bash
# Assembles TokenPulse.app from the SwiftPM release build.
# A real bundle (with a bundle identifier + LSUIElement) is required for
# UserNotifications to work and is the artifact Jamf ships.
set -euo pipefail
cd "$(dirname "$0")"

APP="TokenPulse.app"
BUNDLE_ID="com.kris.tokenpulse"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TokenPulse"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenPulse"
cp Artwork/TokenPulse.icns "$APP/Contents/Resources/TokenPulse.icns"
cp Artwork/TokenPulseMark.png "$APP/Contents/Resources/TokenPulseMark.png"
# Ship pricing.json inside the bundle so cost works without a repo checkout.
cp ../pricing.json "$APP/Contents/Resources/pricing.json" 2>/dev/null || true

# Reuse the locally installed official ChatGPT icon for the personal weekly
# allowance block. The app has an SF Symbol fallback when ChatGPT Desktop is
# absent and only the standalone Codex CLI is installed.
for CHATGPT_ICON in \
  "/Applications/AI:Coding/ChatGPT.app/Contents/Resources/icon-chatgpt.png" \
  "/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png" \
  "$HOME/Applications/ChatGPT.app/Contents/Resources/icon-chatgpt.png"; do
  if [ -f "$CHATGPT_ICON" ]; then
    cp "$CHATGPT_ICON" "$APP/Contents/Resources/icon-chatgpt.png"
    break
  fi
done

# Grok Bot ships an .icns; retain enough resolution for themed Retina artwork.
# Runtime still falls back to the live app icon when this copy is missing.
for GROK_ICNS in \
  "/Applications/Grok Bot.app/Contents/Resources/icon.icns" \
  "$HOME/Applications/Grok Bot.app/Contents/Resources/icon.icns"; do
  if [ -f "$GROK_ICNS" ]; then
    sips -s format png -z 128 128 "$GROK_ICNS" \
      --out "$APP/Contents/Resources/icon-grokbot.png" >/dev/null 2>&1 || true
    break
  fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TokenPulse</string>
  <key>CFBundleDisplayName</key><string>TokenPulse</string>
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
