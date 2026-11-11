#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT/Sources/TokenUsage.swift" "$ROOT/Sources/BurnModel.swift" "$ROOT/Sources/BonfireRenderer.swift" \
  "$ROOT/Tests/main.swift" -o "$ROOT/.build/tests"
"$ROOT/.build/tests" "${1:-$ROOT/Resources}"
