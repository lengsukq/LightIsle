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

echo "Running full automated checks and creating a development-signed bundle..."
go vet ./...
go test -race ./...
bash scripts/build-macos.sh

APP="$ROOT/dist/LightIsle.app"
CORE="$APP/Contents/Resources/core/lightisled"
RECOVERY="$APP/Contents/Resources/core/lightisle-recovery"
echo "Replacing ad-hoc signature with hardened-runtime Developer ID signing..."
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$CORE"
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$RECOVERY"
codesign --force --options runtime --timestamp --sign "$LIGHTISLE_DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
  echo "Developer ID signature check failed. Refusing to publish." >&2;exit 3;
}

ZIP="$ROOT/dist/LightIsle-notary.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$LIGHTISLE_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "Release signed, notarized and locally assessed: $APP"
echo "Do not publish until the supplied hardware QA evidence has been independently reviewed."
