#!/usr/bin/env bash
# Production distribution gate. Never accept a development/ad-hoc signed
# package. No certificates, notarization credentials or QA evidence are
# committed to the repository.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "A native Apple Silicon Mac is required." >&2; exit 2
fi
if [[ -z "${LIGHTISLE_DEVELOPER_ID:-}" || -z "${LIGHTISLE_NOTARY_PROFILE:-}" ]]; then
  echo "Missing LIGHTISLE_DEVELOPER_ID / LIGHTISLE_NOTARY_PROFILE. An ad-hoc app must never be labeled production." >&2
  exit 2
fi
if [[ ! -f "${LIGHTISLE_QA_REPORT:-}" ]]; then
  echo "Missing independent hardware acceptance evidence: LIGHTISLE_QA_REPORT (JSON)." >&2
  exit 2
fi
python3 scripts/verify-release-qa.py "$LIGHTISLE_QA_REPORT"

DIST="$ROOT/dist"
SUBMISSION_ZIP="$DIST/LightIsle-notary-submit.zip"
FINAL_ZIP="$DIST/LightIsle.zip"
FINAL_DMG="$DIST/LightIsle.dmg"
VERIFY_DIR=""
cleanup_release_temporary_files() {
  local release_exit_code=$?
  rm -f "$SUBMISSION_ZIP"
  if [[ -n "$VERIFY_DIR" ]]; then
    rm -rf "$VERIFY_DIR"
  fi
  if [[ "$release_exit_code" != "0" ]]; then
    rm -f "$FINAL_ZIP" "$FINAL_DMG"
  fi
}
trap cleanup_release_temporary_files EXIT
rm -f "$FINAL_ZIP" "$FINAL_DMG" "$SUBMISSION_ZIP"

echo "Running full automated checks and creating a development-signed bundle..."
go vet ./...
go test -race ./...
bash scripts/build-macos.sh

APP="$ROOT/dist/LightIsle.app"
CORE="$APP/Contents/Resources/core/lightisled"
RECOVERY="$APP/Contents/Resources/core/lightisle-recovery"
MEDIA_WORKER="$APP/Contents/Resources/core/lightisle-media-worker"
APP_EXECUTABLE="$APP/Contents/MacOS/LightIsle"

assert_arm64_only() {
  local binary="$1"
  local architectures
  architectures="$(lipo -archs "$binary")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Expected a macOS arm64-only executable: $binary (found: $architectures)" >&2
    exit 3
  fi
}

echo "Checking packaged executable architectures..."
assert_arm64_only "$APP_EXECUTABLE"
assert_arm64_only "$CORE"
assert_arm64_only "$RECOVERY"
assert_arm64_only "$MEDIA_WORKER"

echo "Replacing ad-hoc signature with hardened-runtime Developer ID signing..."
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$CORE"
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$RECOVERY"
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$MEDIA_WORKER"
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$MEDIA_WORKER"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
  echo "Developer ID signature check failed. Refusing to publish." >&2;exit 3;
}

ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"
xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$LIGHTISLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "Creating and verifying the final stapled distribution archive..."
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lightisle-release-verify.XXXXXX")"
ditto -x -k "$FINAL_ZIP" "$VERIFY_DIR"
VERIFIED_APP="$VERIFY_DIR/LightIsle.app"
VERIFIED_CORE="$VERIFIED_APP/Contents/Resources/core/lightisled"
VERIFIED_RECOVERY="$VERIFIED_APP/Contents/Resources/core/lightisle-recovery"
VERIFIED_MEDIA_WORKER="$VERIFIED_APP/Contents/Resources/core/lightisle-media-worker"
assert_arm64_only "$VERIFIED_APP/Contents/MacOS/LightIsle"
assert_arm64_only "$VERIFIED_CORE"
assert_arm64_only "$VERIFIED_RECOVERY"
assert_arm64_only "$VERIFIED_MEDIA_WORKER"
codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"
codesign --verify --strict --verbose=2 "$VERIFIED_CORE"
codesign --verify --strict --verbose=2 "$VERIFIED_RECOVERY"
codesign --verify --strict --verbose=2 "$VERIFIED_MEDIA_WORKER"
codesign -dv --verbose=4 "$VERIFIED_APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
  echo "Final archive does not contain the expected Developer ID signature." >&2; exit 3;
}
xcrun stapler validate "$VERIFIED_APP"
spctl --assess --type execute --verbose=2 "$VERIFIED_APP"

echo "Creating distribution DMG from the signed, stapled app..."
bash scripts/package-dmg.sh "$APP" "$FINAL_DMG"
echo "Notarizing and stapling the final distribution DMG..."
xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$LIGHTISLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$FINAL_DMG"

echo "Release signed, notarized and locally assessed: $APP"
echo "Final distribution archive: $FINAL_ZIP"
echo "Final notarized disk image: $FINAL_DMG"
echo "Do not publish until the supplied hardware QA evidence has been independently reviewed."
