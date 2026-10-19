#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "LightIsle builds only on Apple Silicon macOS (darwin/arm64)." >&2
  exit 1
fi

echo "[1/5] Build Vue 3 frontend"
swift scripts/generate-brand-assets.swift
npm ci --prefix apps/web
npm run build --prefix apps/web

echo "[2/5] Test and build Go Core"
go test ./...
APP="$ROOT/dist/LightIsle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/core" "$APP/Contents/Resources/web"
GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -trimpath -o "$APP/Contents/Resources/core/lightisled" ./core/cmd/lightisled

echo "[3/5] Build native SwiftUI app"
swift build -c release --product LightIsle
SWIFT_BIN="$(swift build -c release --show-bin-path)/LightIsle"
cp "$SWIFT_BIN" "$APP/Contents/MacOS/LightIsle"
cp apps/macos/Info.plist "$APP/Contents/Info.plist"
cp apps/macos/Resources/LightIsleLogo.png "$APP/Contents/Resources/LightIsleLogo.png"
iconutil -c icns -o "$APP/Contents/Resources/LightIsle.icns" "$ROOT/dist/LightIsle.iconset"
cp -R apps/web/dist/. "$APP/Contents/Resources/web/"

echo "[4/5] Local development code signing (ad hoc)"
# Production distribution requires an Apple Developer ID and notarization.
codesign --force --deep --sign - "$APP"

echo "[5/5] Check bundle metadata"
plutil -lint "$APP/Contents/Info.plist"
python3 tests/test_app_lifecycle.py
python3 tests/test_native_setup.py
python3 tests/test_cinema_bundle.py
python3 tests/test_native_backup.py
python3 tests/test_brand_assets.py
echo "Built: $APP"
echo "Launch with: open \"$APP\""
echo "Note: LAN HTTPS must be manually enabled in LightIsle.app Settings after local administrator setup."

