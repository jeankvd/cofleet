#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cofleet_require_command git
cofleet_is_own_git_repository || cofleet_die "initialize CoFleet as its own Git repository first"

if ! git -C "$COFLEET_ROOT" diff --quiet; then
    cofleet_die "unstaged tracked changes exist; stage the exact publication snapshot first"
fi
if [[ -n "$(git -C "$COFLEET_ROOT" ls-files --others --exclude-standard)" ]]; then
    cofleet_die "untracked publication files exist; stage them before verification"
fi

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/cofleet-publication.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT
snapshot="$temp_root/snapshot"
origin="$temp_root/origin.git"
clone="$temp_root/clone"
mkdir -p "$snapshot"

if ! git -C "$COFLEET_ROOT" diff --cached --quiet; then
    cofleet_log "creating a temporary commit from the staged publication index"
    git -C "$COFLEET_ROOT" checkout-index --all --force --prefix="$snapshot/"
else
    git -C "$COFLEET_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || \
        cofleet_die "nothing is staged and the repository has no commit to verify"
    cofleet_log "creating a temporary publication snapshot from HEAD"
    git -C "$COFLEET_ROOT" archive HEAD | tar -x -C "$snapshot"
fi

git -C "$snapshot" init -b main
git -C "$snapshot" add --all
git -C "$snapshot" \
    -c user.name='Jean Diaz' \
    -c user.email='jeankvd@users.noreply.github.com' \
    commit -m 'feat: initialize CoFleet for Codex' >/dev/null

git clone --bare "$snapshot" "$origin" >/dev/null
git clone "$origin" "$clone" >/dev/null

cofleet_log "bootstrapping fresh clone"
(
    cd "$clone"
    Scripts/bootstrap.sh
)
git -C "$clone" diff --exit-code

# UI smoke needs simulator/window-server state and is enforced once by
# publication-gate.sh plus the dedicated UI workflow. Keep this isolated clone
# proof deterministic and headless rather than running the same UI matrix twice.
cofleet_log "running headless tests from fresh clone"
(
    cd "$clone"
    Scripts/test.sh
)

cofleet_log "running all unsigned Release builds from fresh clone"
(
    cd "$clone"
    COFLEET_SIGNING=0 CONFIGURATION=Release Scripts/build.sh all
)

git -C "$clone" fsck --full --strict
cofleet_log "fresh-clone publication proof passed"
