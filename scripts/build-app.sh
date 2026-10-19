#!/usr/bin/env bash
# Builds Arbor with SwiftPM and wraps the binary into build/Arbor.app.
# Usage: scripts/build-app.sh [debug|release] [--run]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Arbor.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Arbor"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Arbor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS keeps TCC (Documents/Desktop access) decisions stable between builds.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    pkill -x Arbor 2>/dev/null || true
    open "$APP"
fi
