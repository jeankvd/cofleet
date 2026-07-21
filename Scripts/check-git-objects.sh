#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if ! cofleet_is_own_git_repository; then
    cofleet_warn "Git object check skipped until CoFleet is initialized as its own repository"
    exit 0
fi

git -C "$COFLEET_ROOT" fsck --full --strict
unreachable="$(git -C "$COFLEET_ROOT" fsck --unreachable --no-reflogs 2>&1 | rg '^unreachable ' || true)"
if [[ -n "$unreachable" ]]; then
    printf '%s\n' "$unreachable" >&2
    cofleet_die "unreachable Git objects found; recreate the clean repository instead of importing history"
fi

cofleet_log "Git object graph is strict and contains no unreachable imported objects"
