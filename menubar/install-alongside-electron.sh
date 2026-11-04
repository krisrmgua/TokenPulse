#!/bin/bash
# Build the Swift menu-bar app and install it NEXT TO Electron for visual compare.
# Does not touch ~/Applications/TokenPulse.app or the Electron LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TokenPulse-Swift"
BUNDLE_ID="com.kris.tokenpulse.swift"
DISPLAY_NAME="TokenPulse Swift"
export APP_NAME BUNDLE_ID DISPLAY_NAME

./make-app.sh

DEST="$HOME/Applications/${APP_NAME}.app"
mkdir -p "$HOME/Applications"
# Quit only the Swift compare build if it is already running.
pkill -f "${APP_NAME}.app/Contents/MacOS/TokenPulse" 2>/dev/null || true
rm -rf "$DEST"
ditto "${APP_NAME}.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$DEST" >/dev/null 2>&1 || true

# Register so Spotlight/open -a find it; do not install a LaunchAgent.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

open "$DEST"
echo "Installed $DEST (bundle $BUNDLE_ID)"
echo "Electron stays at ~/Applications/TokenPulse.app — both can run at once."
echo "Quit Swift when done: pkill -f '${APP_NAME}.app/Contents/MacOS/TokenPulse'"
