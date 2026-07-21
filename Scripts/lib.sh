#!/usr/bin/env bash

set -euo pipefail

COFLEET_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

cofleet_log() {
    printf '[cofleet] %s\n' "$*"
}

cofleet_warn() {
    printf '[cofleet] warning: %s\n' "$*" >&2
}

cofleet_die() {
    printf '[cofleet] error: %s\n' "$*" >&2
    exit 1
}

cofleet_require_command() {
    command -v "$1" >/dev/null 2>&1 || cofleet_die "required command not found: $1"
}

cofleet_is_own_git_repository() {
    local git_root
    git_root="$(git -C "$COFLEET_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ -n "$git_root" ]] || return 1
    git_root="$(cd -P "$git_root" 2>/dev/null && pwd -P)" || return 1
    [[ "$git_root" == "$COFLEET_ROOT" ]]
}

cofleet_revision() {
    if cofleet_is_own_git_repository; then
        git -C "$COFLEET_ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf 'development\n'
    else
        printf 'development\n'
    fi
}
