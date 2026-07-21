#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cofleet_require_command xcodegen
cd "$COFLEET_ROOT"
xcodegen generate --spec project.yml
cofleet_log "generated CoFleet.xcodeproj from project.yml"
