#!/bin/sh
# Offline-first checks. Build only the requested declared project platforms.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$ROOT/scripts/sync-flutter-tokens.py" --check
cd "$ROOT/apps/flutter"
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub
for platform in "$@"; do
  case "$platform" in
    android) flutter build apk --debug --no-pub ;;
    macos) flutter build macos --debug --no-pub ;;
    ios) flutter build ios --simulator --debug --no-codesign --no-pub ;;
    *) echo "Supported build arguments: android macos ios" >&2; exit 2 ;;
  esac
done
