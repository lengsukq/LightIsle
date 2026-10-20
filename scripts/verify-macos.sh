#!/usr/bin/env bash
# Local/CI validation entry point. The product targets Apple Silicon macOS
# only; refuse to run the target checks under Rosetta, Intel or another OS so a
# passing run always refers to the real deployment architecture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "verify-macos.sh requires native Apple Silicon macOS (got $(uname -s)/$(uname -m))." >&2
  exit 2
fi
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" != "1" ]]; then
  echo "This macOS host is not Apple Silicon (hw.optional.arm64 != 1)." >&2
  exit 2
fi
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == "1" ]]; then
  echo "This shell runs under Rosetta; use a native arm64 terminal." >&2
  exit 2
fi

echo "Go unit/integration:"
if [[ "${LIGHTISLE_RACE:-0}" == "1" ]]; then
  go test -race ./...
else
  go test ./...
fi
go vet ./...

echo "Swift compile:"
swift build -c debug

echo "Vue TypeScript + build:"
npm ci --prefix apps/web
npm run build --prefix apps/web

echo "Release QA validator tests:"
python3 -B -m unittest discover -s tests -p 'test_release_qa.py' -v

echo "Go tests/vet, Swift debug build, Web build, and release-QA validator tests passed. Packaged smoke tests were not run."
