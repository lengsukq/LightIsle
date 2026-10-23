#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="${LIGHTISLE_MEDIA_WORKER_BIN:-$repo_root/.build/out/Products/Release/lightisle-media-worker}"
if [[ "$worker" != /* ]]; then
	worker="$repo_root/$worker"
fi
if [[ ! -x "$worker" ]]; then
	echo "Native worker not found or not executable: $worker" >&2
	echo "Build the project's lightisle-media-worker target locally, or set LIGHTISLE_MEDIA_WORKER_BIN to an existing binary." >&2
	exit 2
fi
if [[ ! -x /usr/bin/sips ]]; then
	echo "This integration requires macOS /usr/bin/sips for the HEIC thumbnail endpoint." >&2
	exit 2
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/lightisle-media-integration.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# The fixture generator uses only Apple's SDK frameworks and the source tree.
# It creates deterministic local HEIC/MP4 fixtures and does not fetch assets.
swiftc -suppress-warnings -parse-as-library "$repo_root/tests/MediaWorkerFixtureMaker.swift" -o "$scratch/media-fixture-maker"
"$scratch/media-fixture-maker" heic "$scratch/synthetic.heic"
"$scratch/media-fixture-maker" mp4 "$scratch/synthetic.mp4"

cd "$repo_root"
LIGHTISLE_TEST_MEDIA_WORKER="$worker" \
LIGHTISLE_TEST_HEIC="$scratch/synthetic.heic" \
LIGHTISLE_TEST_MP4="$scratch/synthetic.mp4" \
	go test ./core/internal/server -run '^TestMediaWorkerHTTPIntegration$' -count=1 -v
