#!/usr/bin/env bash
# Builds a release Arbor.app and zips it as dist/Arbor-<tag>.zip for a GitHub release.
# The tag comes from ArborReleaseTag in Resources/Info.plist (e.g. v0.1.0-dev.1).
# Usage: scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TAG="$(/usr/libexec/PlistBuddy -c 'Print :ArborReleaseTag' Resources/Info.plist)"

scripts/build-app.sh release
mkdir -p dist
ZIP="dist/Arbor-$TAG.zip"
rm -f "$ZIP"
# ditto keeps the bundle's code signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent build/Arbor.app "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1)), sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
