#!/usr/bin/env bash
# Build TokenPulse (Electron) and install it to ~/Applications/TokenPulse.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v npm >/dev/null; then
  echo "npm is required" >&2
  exit 1
fi

npm install
npm run pack:mac

APP_SRC="$(find "$ROOT/release/mac"* -maxdepth 2 -name 'TokenPulse.app' -type d 2>/dev/null | head -1 || true)"
if [[ -z "${APP_SRC}" ]]; then
  APP_SRC="$(find "$ROOT/release" -maxdepth 3 -name 'TokenPulse.app' -type d | head -1 || true)"
fi
if [[ -z "${APP_SRC}" ]]; then
  echo "TokenPulse.app not found under release/" >&2
  exit 1
fi

DEST="$HOME/Applications/TokenPulse.app"

# Quit the running copy (Swift or Electron) so the bundle can be replaced.
pkill -f "TokenPulse.app/Contents/MacOS/TokenPulse" 2>/dev/null || true
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep --sign - --identifier com.kris.tokenpulse "$DEST" >/dev/null 2>&1 || true

mkdir -p "$HOME/bin"
chmod +x "$ROOT/bin/tokenpulse"
ln -sfn "$ROOT/bin/tokenpulse" "$HOME/bin/tokenpulse"

open -a "$DEST"
echo "Installed ${DEST}"
echo "CLI: tokenpulse status|start|stop|enable|disable (ensure ~/bin is on PATH)"
