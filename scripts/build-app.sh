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
# Icon: with Xcode, compile the Icon Composer document into Assets.car, which macOS 26+ shows as Liquid
# Glass (with the dark, clear and tinted looks). Earlier systems use AppIcon.icns from scripts/make-icon.swift
# (actool writes one too, but only up to 256 px).
if xcrun --find actool >/dev/null 2>&1; then
    PARTIAL="$(mktemp -d)"
    xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist "$PARTIAL/icon.plist" --errors >/dev/null
    rm -rf "$PARTIAL"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Text is written in Chinese in the source; en.lproj holds the English (see Sources/Arbor/App/Localization.swift).
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"

# Ad-hoc sign with an explicit designated requirement. An ad-hoc signature's default requirement is the
# build's own hash, so macOS privacy permissions (Desktop, Documents, Full Disk Access…) were tied to one
# build and asked for again after every update. Requiring only the bundle identifier keeps them.
codesign --force --sign - --identifier app.arbor.Arbor \
    -r='designated => identifier "app.arbor.Arbor"' "$APP"

echo "Built $APP"

if [[ "${2:-}" == "--run" ]]; then
    pkill -x Arbor 2>/dev/null || true
    open "$APP"
fi
