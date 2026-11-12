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

mkdir -p "$ROOT/.build"

run_swift_check() {
  local out_name="$1"
  shift
  local bin="$ROOT/.build/$out_name"
  swiftc "$@" -o "$bin"
  "$bin"
}

echo "Documentation integrity:"
python3 -B scripts/check-docs.py

echo "Go unit/integration:"
if [[ "${LIGHTISLE_RACE:-0}" == "1" ]]; then
  go test -race ./...
else
  go test ./...
fi
go vet ./...

echo "Swift compile:"
swift build -c debug
run_swift_check lightisle-core-framer-check \
  apps/macos/Sources/LightIsle/CoreLineFramer.swift tests/CoreLineFramerCheck.swift
run_swift_check lightisle-core-ipc-domain-check \
  apps/macos/Sources/LightIsle/CoreIPCDomainEvent.swift tests/CoreIPCDomainEventCheck.swift
run_swift_check lightisle-space-input-validation-check -parse-as-library \
  apps/macos/Sources/LightIsle/SpaceInputValidation.swift tests/SpaceInputValidationCheck.swift
run_swift_check lightisle-media-scope-check \
  apps/macos/Sources/LightIsle/MediaScanScope.swift tests/MediaScanScopeCheck.swift
run_swift_check lightisle-storage-volume-check \
  apps/macos/Sources/LightIsle/StorageVolumeSelection.swift tests/StorageVolumeSelectionCheck.swift
run_swift_check lightisle-upgrade-check -lsqlite3 \
  apps/macos/Sources/LightIsle/NativeUpgradePreflight.swift tests/NativeUpgradePreflightCheck.swift
run_swift_check lightisle-service-presence-check \
  apps/macos/Sources/LightIsle/BonjourPublisher.swift \
  apps/macos/Sources/LightIsle/NativeServicePresenceCoordinator.swift \
  tests/NativeServicePresenceCheck.swift
run_swift_check lightisle-lightweight-policy-check \
  apps/macos/Sources/LightIsle/LightweightModePolicy.swift tests/LightweightModePolicyCheck.swift
run_swift_check lightisle-lan-policy-check \
  apps/macos/Sources/LightIsle/LANAccessPolicy.swift tests/LANAccessPolicyCheck.swift
run_swift_check lightisle-service-persistence-check \
  apps/macos/Sources/LightIsle/ServicePersistencePolicy.swift tests/ServicePersistencePolicyCheck.swift
run_swift_check lightisle-frp-config-check \
  apps/macos/Sources/LightIsle/FRPConfigDocument.swift tests/FRPConfigDocumentCheck.swift
run_swift_check lightisle-smb-elevation-check -parse-as-library \
  apps/macos/Sources/LightIsle/Base64URLCodec.swift \
  apps/macos/Sources/LightIsle/SmbElevation.swift \
  tests/SmbElevationCheck.swift
run_swift_check lightisle-window-visibility-check -swift-version 5 -parse-as-library \
  apps/macos/Sources/LightIsle/ManagementWindowVisibility.swift tests/ManagementWindowVisibilityCheck.swift
python3 -B scripts/sync-fluid-tokens.py --check
run_swift_check lightisle-presentation-check -swift-version 5 -parse-as-library \
  apps/macos/Sources/LightIsle/ManagementNavigation.swift \
  apps/macos/Sources/LightIsle/SidebarPage.swift \
  apps/macos/Sources/LightIsle/IsleFluidPalette.swift \
  apps/macos/Sources/LightIsle/LiquidComponents.swift \
  apps/macos/Sources/LightIsle/ManagementShell.swift \
  apps/macos/Sources/LightIsle/DetailPreview.swift \
  tests/NativePresentationCheck.swift
run_swift_check lightisle-tunnel-wire-check \
  apps/macos/Sources/LightIsle/Base64URLCodec.swift \
  apps/macos/Sources/LightIsle/TunnelWireCodec.swift \
  tests/TunnelWireCodecCheck.swift
run_swift_check lightisle-tunnel-credentials-check \
  apps/macos/Sources/LightIsle/TunnelCredentialCoordinator.swift tests/TunnelCredentialCoordinatorCheck.swift
run_swift_check lightisle-tunnel-payload-check \
  apps/macos/Sources/LightIsle/TunnelSupport.swift \
  apps/macos/Sources/LightIsle/TunnelPayloadParser.swift \
  tests/TunnelPayloadParserCheck.swift

python3 -B tests/test_offline_recovery_runner.py
python3 -B tests/test_media_worker.py "$(swift build -c debug --show-bin-path)/lightisle-media-worker"
go build -o "$ROOT/.build/lightisled-ipc-check" ./core/cmd/lightisled
python3 -B tests/test_native_metrics_ipc.py "$ROOT/.build/lightisled-ipc-check"
python3 -B tests/test_core_failure_isolation.py "$ROOT/.build/lightisled-ipc-check"
swiftc -parse-as-library apps/macos/Sources/LightIsle/{CoreSupervisorPolicy,CoreCommandWriter,CoreHealthProbe,CoreLifecycleSignal,CoreProcessBootstrap,CorePortListener}.swift tests/CoreSupervisorCheck.swift -o "$ROOT/.build/lightisle-core-supervisor-check"
"$ROOT/.build/lightisle-core-supervisor-check" "$ROOT/.build/lightisled-ipc-check"

echo "Vue TypeScript + build:"
npm ci --prefix apps/web
(cd apps/web && node --test)
npm run build --prefix apps/web

echo "Release QA validator tests:"
python3 -B -m unittest discover -s tests -p 'test_release_qa.py' -v
python3 -B tests/test_release_packaging.py
python3 -B tests/test_dmg_packaging.py
python3 -B tests/test_beta_upgrade_preflight.py

echo "Go tests/vet, Swift debug build, Web regressions/build, and release checks passed. Packaged smoke tests were not run."
