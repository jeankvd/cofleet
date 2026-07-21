#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

strict_runtime=false
if [[ "${1:-}" == "--strict-runtime" ]]; then
    strict_runtime=true
elif [[ $# -gt 0 ]]; then
    cofleet_die "usage: Scripts/doctor.sh [--strict-runtime]"
fi

failures=0
for command_name in xcodebuild xcrun swift python3 xcodegen; do
    if command -v "$command_name" >/dev/null 2>&1; then
        cofleet_log "$command_name: available"
    else
        cofleet_warn "$command_name: missing"
        failures=$((failures + 1))
    fi
done

if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
        cofleet_log "Python: $(python3 --version 2>&1)"
    else
        cofleet_warn "Python 3.9 or newer is required"
        failures=$((failures + 1))
    fi
fi

if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version | sed 's/^/[cofleet] /'
fi

if command -v codex >/dev/null 2>&1; then
    cofleet_log "Codex runtime: available"
else
    cofleet_warn "Codex runtime is not installed; builds still work, live host use will not"
    [[ "$strict_runtime" == false ]] || failures=$((failures + 1))
fi

if command -v tailscale >/dev/null 2>&1; then
    cofleet_log "Tailscale runtime: available"
else
    cofleet_warn "Tailscale is not installed; local-only use still works"
    [[ "$strict_runtime" == false ]] || failures=$((failures + 1))
fi

if [[ ! -f "$COFLEET_ROOT/Config/Local.xcconfig" ]]; then
    cofleet_warn "Config/Local.xcconfig is absent; unsigned builds use sanitized defaults"
elif rg -q 'ABCDE12345|com\.example\.cofleet' "$COFLEET_ROOT/Config/Local.xcconfig"; then
    cofleet_warn "Config/Local.xcconfig still contains example signing identifiers"
else
    cofleet_log "local signing configuration: present"
fi

if [[ -f "$COFLEET_ROOT/CoFleet.xcodeproj/project.pbxproj" ]]; then
    cofleet_log "generated Xcode project: present"
else
    cofleet_warn "generated Xcode project is missing; run Scripts/generate-project.sh"
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    cofleet_die "$failures required doctor check(s) failed"
fi

cofleet_log "doctor checks passed"
