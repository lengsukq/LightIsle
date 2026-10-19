#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Go unit/integration:"
go test ./...
go vet ./...

echo "Swift compile:"
swift build -c debug

echo "Vue TypeScript + build:"
npm run build --prefix apps/web
echo "Basic M1 checks passed."

