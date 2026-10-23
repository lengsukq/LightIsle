#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
swiftc "$ROOT/apps/macos/Sources/LightIsle/DockerSupport.swift" \
    "$ROOT/apps/macos/Sources/LightIsle/DockerOperations.swift" \
    "$ROOT/tests/DockerSupportRegression.swift" \
    -o "$TMPDIR_TEST/docker-support-regression"
"$TMPDIR_TEST/docker-support-regression"
