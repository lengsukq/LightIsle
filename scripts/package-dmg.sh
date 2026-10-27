#!/usr/bin/env bash
# Package an already-built macOS app into a drag-to-Applications disk image.
# This does NOT sign or notarize the app or the image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/LightIsle.app}"
OUTPUT="${2:-$ROOT/dist/LightIsle-dev.dmg}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "A macOS host is required to create a DMG." >&2
  exit 2
fi
if [[ ! -d "$APP/Contents" || ! -f "$APP/Contents/Info.plist" || ! -f "$APP/Contents/MacOS/LightIsle" ]]; then
  echo "LightIsle.app is missing or incomplete: $APP" >&2
  echo "Build it first: bash scripts/build-macos.sh" >&2
  exit 2
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "Missing macOS hdiutil; cannot create a disk image." >&2
  exit 2
fi

OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"
WORKDIR="$(mktemp -d "$OUTPUT_DIR/.lightisle-dmg.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
STAGING="$WORKDIR/contents"
TEMP_IMAGE="$WORKDIR/LightIsle.dmg"
mkdir -p "$STAGING"

# Use an actual copy: a symlink to the build's .app would break when mounted.
ditto "$APP" "$STAGING/LightIsle.app"
ln -s /Applications "$STAGING/Applications"

echo "Creating LightIsle disk image with an Applications shortcut..."
hdiutil create -ov -srcfolder "$STAGING" -volname LightIsle -fs HFS+ -format UDZO "$TEMP_IMAGE"
hdiutil verify "$TEMP_IMAGE"

# Remove any previous output only after the new image has passed verification.
mv -f "$TEMP_IMAGE" "$OUTPUT"
echo "Built disk image: $OUTPUT"
