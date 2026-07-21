#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

cofleet_require_command python3
cofleet_require_command rg
cofleet_require_command ruby

cofleet_log "checking shell syntax"
while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find "$COFLEET_ROOT/Scripts" -type f -name '*.sh' -print0)

if command -v shellcheck >/dev/null 2>&1; then
    shell_scripts=()
    while IFS= read -r -d '' script; do
        shell_scripts+=("$script")
    done < <(find "$COFLEET_ROOT/Scripts" -type f -name '*.sh' -print0)
    shellcheck --exclude=SC1091 "${shell_scripts[@]}"
elif [[ "${CI:-}" == "true" || "${COFLEET_REQUIRE_SHELLCHECK:-0}" == "1" ]]; then
    cofleet_die "ShellCheck is required in this environment"
else
    cofleet_warn "ShellCheck is unavailable; syntax checks still ran"
fi

cofleet_log "checking JSON"
while IFS= read -r -d '' json_file; do
    python3 -m json.tool "$json_file" >/dev/null
done < <(find "$COFLEET_ROOT" \
    -path "$COFLEET_ROOT/.git" -prune -o \
    -path "$COFLEET_ROOT/.build" -prune -o \
    -type f -name '*.json' -print0)

cofleet_log "parsing and validating OpenAPI structure"
ruby "$SCRIPT_DIR/check-openapi.rb" "$COFLEET_ROOT/Docs/openapi.yaml"

if command -v plutil >/dev/null 2>&1; then
    cofleet_log "checking plist, entitlement, and privacy manifests"
    while IFS= read -r -d '' plist_file; do
        plutil -lint "$plist_file" >/dev/null
    done < <(find "$COFLEET_ROOT/Config" -type f \( -name '*.plist' -o -name '*.entitlements' -o -name '*.xcprivacy' \) -print0)
fi

if cofleet_is_own_git_repository; then
    "$SCRIPT_DIR/check-private-content.sh" --history
else
    "$SCRIPT_DIR/check-private-content.sh"
fi
python3 "$SCRIPT_DIR/check-binary-assets.py"
"$SCRIPT_DIR/check-git-objects.sh"

if cofleet_is_own_git_repository; then
    ignored_tracked="$(git -C "$COFLEET_ROOT" ls-files -ci --exclude-standard)"
    if [[ -n "$ignored_tracked" ]]; then
        printf '%s\n' "$ignored_tracked" >&2
        cofleet_die "ignored files are tracked"
    fi

    tracked_symlinks="$(git -C "$COFLEET_ROOT" ls-files -s | awk '$1 == "120000" { print $4 }')"
    if [[ -n "$tracked_symlinks" ]]; then
        printf '%s\n' "$tracked_symlinks" >&2
        cofleet_die "tracked symlinks are not permitted in the publication source tree"
    fi
fi

if [[ "${COFLEET_GITLEAKS_EXTERNAL:-0}" == "1" ]]; then
    cofleet_log "Gitleaks is delegated to the pinned CI action"
elif command -v gitleaks >/dev/null 2>&1; then
    cofleet_log "scanning the working tree for secrets"
    if gitleaks dir --help >/dev/null 2>&1; then
        gitleaks dir "$COFLEET_ROOT" --no-banner --redact --config "$COFLEET_ROOT/.gitleaks.toml"
        if cofleet_is_own_git_repository && git -C "$COFLEET_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
            gitleaks git "$COFLEET_ROOT" --no-banner --redact --config "$COFLEET_ROOT/.gitleaks.toml"
        fi
    else
        gitleaks detect --source "$COFLEET_ROOT" --no-git --no-banner --redact --config "$COFLEET_ROOT/.gitleaks.toml"
        if cofleet_is_own_git_repository && git -C "$COFLEET_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
            gitleaks detect --source "$COFLEET_ROOT" --no-banner --redact --config "$COFLEET_ROOT/.gitleaks.toml"
        fi
    fi
elif [[ "${CI:-}" == "true" || "${COFLEET_REQUIRE_GITLEAKS:-0}" == "1" ]]; then
    cofleet_die "Gitleaks is required in this environment"
else
    cofleet_warn "Gitleaks is unavailable; private-content checks still ran"
fi

cofleet_log "repository hygiene checks passed"
