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
swiftc apps/macos/Sources/LightIsle/CoreLineFramer.swift tests/CoreLineFramerCheck.swift -o "$ROOT/.build/lightisle-core-framer-check"
"$ROOT/.build/lightisle-core-framer-check"
swiftc apps/macos/Sources/LightIsle/MediaScanScope.swift tests/MediaScanScopeCheck.swift -o "$ROOT/.build/lightisle-media-scope-check"
"$ROOT/.build/lightisle-media-scope-check"
swiftc apps/macos/Sources/LightIsle/StorageVolumeSelection.swift tests/StorageVolumeSelectionCheck.swift -o "$ROOT/.build/lightisle-storage-volume-check"
"$ROOT/.build/lightisle-storage-volume-check"
swiftc apps/macos/Sources/LightIsle/NativeUpgradePreflight.swift tests/NativeUpgradePreflightCheck.swift -lsqlite3 -o "$ROOT/.build/lightisle-upgrade-check"
"$ROOT/.build/lightisle-upgrade-check"
swiftc apps/macos/Sources/LightIsle/BonjourPublisher.swift apps/macos/Sources/LightIsle/NativeServicePresenceCoordinator.swift tests/NativeServicePresenceCheck.swift -o "$ROOT/.build/lightisle-service-presence-check"
"$ROOT/.build/lightisle-service-presence-check"
swiftc apps/macos/Sources/LightIsle/LightweightModePolicy.swift tests/LightweightModePolicyCheck.swift -o "$ROOT/.build/lightisle-lightweight-policy-check"
"$ROOT/.build/lightisle-lightweight-policy-check"
swiftc apps/macos/Sources/LightIsle/TunnelWireCodec.swift tests/TunnelWireCodecCheck.swift -o "$ROOT/.build/lightisle-tunnel-wire-check"
"$ROOT/.build/lightisle-tunnel-wire-check"
swiftc apps/macos/Sources/LightIsle/TunnelCredentialCoordinator.swift tests/TunnelCredentialCoordinatorCheck.swift -o "$ROOT/.build/lightisle-tunnel-credentials-check"
"$ROOT/.build/lightisle-tunnel-credentials-check"
swiftc apps/macos/Sources/LightIsle/TunnelSupport.swift apps/macos/Sources/LightIsle/TunnelPayloadParser.swift tests/TunnelPayloadParserCheck.swift -o "$ROOT/.build/lightisle-tunnel-payload-check"
"$ROOT/.build/lightisle-tunnel-payload-check"
python3 -B tests/test_offline_recovery_runner.py
python3 -B tests/test_media_worker.py "$(swift build -c debug --show-bin-path)/lightisle-media-worker"

echo "Vue TypeScript + build:"
npm ci --prefix apps/web
node --test apps/web/tests/*.test.mjs
npm run build --prefix apps/web

echo "Release QA validator tests:"
python3 -B -m unittest discover -s tests -p 'test_release_qa.py' -v
python3 -B tests/test_release_packaging.py
python3 -B tests/test_dmg_packaging.py
python3 -B tests/test_beta_upgrade_preflight.py

echo "Go tests/vet, Swift debug build, Web regressions/build, and release checks passed. Packaged smoke tests were not run."
