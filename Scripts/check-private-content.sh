#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

scan_history=false
if [[ "${1:-}" == "--history" ]]; then
    scan_history=true
elif [[ $# -gt 0 ]]; then
    cofleet_die "usage: Scripts/check-private-content.sh [--history]"
fi

cofleet_require_command rg
terms_file="$COFLEET_ROOT/Config/private-terms.txt"
[[ -f "$terms_file" ]] || cofleet_die "missing private-term denylist"
term_files=("$terms_file")
local_terms_file="$COFLEET_ROOT/Config/private-terms.local.txt"
if [[ -f "$local_terms_file" ]]; then
    term_files+=("$local_terms_file")
fi

# Ripgrep's exclusion globs below are repository-relative. Search from the
# publication root so they remain effective regardless of the caller's cwd.
cd "$COFLEET_ROOT"

failures=0
common_globs=(
    --hidden
    --glob '!.git/**'
    --glob '!.build/**'
    --glob '!DerivedData/**'
    --glob '!Config/Local.xcconfig'
    --glob '!Config/private-terms.txt'
    --glob '!Config/private-terms.local.txt'
)

for active_terms_file in "${term_files[@]}"; do
    while IFS= read -r term; do
        [[ -n "$term" && "${term:0:1}" != "#" ]] || continue
        matches="$(rg -n -i -F "${common_globs[@]}" -- "$term" . || true)"
        if [[ -n "$matches" ]]; then
            cofleet_warn "forbidden legacy/private term found: $term"
            printf '%s\n' "$matches" >&2
            failures=$((failures + 1))
        fi
    done < "$active_terms_file"
done

declare -a sensitive_patterns=(
    '/Users/[[:alnum:]_.-]+/'
    '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'
    '(^|[^0-9])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    '(^|[^0-9])192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
    '(^|[^0-9])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
    'file:///Users/'
    '[~]/[.]ssh/'
)

for pattern in "${sensitive_patterns[@]}"; do
    matches="$(rg -n -e "$pattern" "${common_globs[@]}" --glob '!Scripts/check-private-content.sh' . || true)"
    if [[ "$pattern" == '/Users/[[:alnum:]_.-]+/' && -n "$matches" ]]; then
        matches="$(printf '%s\n' "$matches" | rg -v '/Users/(example|sample|test)/' || true)"
    fi
    if [[ -n "$matches" ]]; then
        cofleet_warn "private path or address pattern found: $pattern"
        printf '%s\n' "$matches" >&2
        failures=$((failures + 1))
    fi
done

if [[ "$scan_history" == true ]] && cofleet_is_own_git_repository; then
    while IFS= read -r commit; do
        [[ -n "$commit" ]] || continue
        for active_terms_file in "${term_files[@]}"; do
            while IFS= read -r term; do
                [[ -n "$term" && "${term:0:1}" != "#" ]] || continue
                matches="$(git -C "$COFLEET_ROOT" grep -n -i -F "$term" "$commit" -- . \
                    ':(exclude)Config/private-terms.txt' \
                    ':(exclude)Config/private-terms.local.txt' 2>/dev/null || true)"
                if [[ -n "$matches" ]]; then
                    cofleet_warn "forbidden term exists in Git history at $commit: $term"
                    printf '%s\n' "$matches" >&2
                    failures=$((failures + 1))
                fi
            done < "$active_terms_file"
        done

        for pattern in "${sensitive_patterns[@]}"; do
            matches="$(git -C "$COFLEET_ROOT" grep -n -i -E "$pattern" "$commit" -- . \
                ':(exclude)Config/Local.xcconfig' \
                ':(exclude)Config/private-terms.txt' \
                ':(exclude)Config/private-terms.local.txt' \
                ':(exclude)Scripts/check-private-content.sh' 2>/dev/null || true)"
            if [[ "$pattern" == '/Users/[[:alnum:]_.-]+/' && -n "$matches" ]]; then
                matches="$(printf '%s\n' "$matches" | rg -v '/Users/(example|sample|test)/' || true)"
            fi
            if [[ -n "$matches" ]]; then
                cofleet_warn "private path or address pattern exists in Git history at $commit: $pattern"
                printf '%s\n' "$matches" >&2
                failures=$((failures + 1))
            fi
        done
    done < <(git -C "$COFLEET_ROOT" rev-list --all 2>/dev/null || true)
fi

if (( failures > 0 )); then
    cofleet_die "$failures private-content check(s) failed"
fi

cofleet_log "private-content denylist passed"
