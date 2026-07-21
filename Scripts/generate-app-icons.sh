#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="${COFLEET_SWIFT_MODULE_CACHE:-${TMPDIR:-/tmp}/cofleet-swift-module-cache}"
mkdir -p "$MODULE_CACHE"
exec xcrun swift -module-cache-path "$MODULE_CACHE" "$ROOT/Scripts/generate-app-icons.swift"
