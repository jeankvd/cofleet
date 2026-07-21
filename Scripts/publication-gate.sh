#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cofleet_is_own_git_repository || cofleet_die "initialize a fresh CoFleet Git repository before publication gating"

COFLEET_REQUIRE_GITLEAKS=1 COFLEET_REQUIRE_SHELLCHECK=1 "$SCRIPT_DIR/check-repository.sh"
"$SCRIPT_DIR/check-project-drift.sh"
"$SCRIPT_DIR/test.sh" --ui
COFLEET_SIGNING=0 CONFIGURATION=Release "$SCRIPT_DIR/build.sh" all
COFLEET_SIGNING=0 CONFIGURATION=Release "$SCRIPT_DIR/verify-clean-clone.sh"

cofleet_log "publication gate passed; creating a public remote is still a separate explicit action"
