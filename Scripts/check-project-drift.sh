#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cofleet_require_command xcodegen

if [[ ! -d "$COFLEET_ROOT/CoFleet.xcodeproj" ]]; then
    cofleet_die "CoFleet.xcodeproj is missing; generate and commit it first"
fi

if ! cofleet_is_own_git_repository; then
    cofleet_warn "not running at the root of CoFleet's own Git repository; validating generation only"
    "$SCRIPT_DIR/generate-project.sh"
    exit 0
fi

"$SCRIPT_DIR/generate-project.sh"
if ! git -C "$COFLEET_ROOT" diff --exit-code -- CoFleet.xcodeproj; then
    cofleet_die "CoFleet.xcodeproj differs from project.yml; regenerate and commit it"
fi

cofleet_log "generated Xcode project matches project.yml"
