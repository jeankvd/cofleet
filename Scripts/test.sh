#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

run_ui=false
if [[ "${1:-}" == "--ui" ]]; then
    run_ui=true
elif [[ $# -gt 0 ]]; then
    cofleet_die "usage: Scripts/test.sh [--ui]"
fi

"$SCRIPT_DIR/check-repository.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/cofleet-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/home" "$test_root/tmp"

cofleet_log "running isolated Swift package tests"
swift_test_args=(test --package-path "$COFLEET_ROOT/Packages/CoFleetKit")
if [[ "${COFLEET_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    swift_test_args+=(--disable-sandbox)
fi
env \
    CFFIXED_USER_HOME="$test_root/home" \
    TMPDIR="$test_root/tmp" \
    COFLEET_TEST_ROOT="$test_root/swift" \
    swift "${swift_test_args[@]}"

cofleet_log "running Python host/API tests"
env \
    PYTHONPATH="$COFLEET_ROOT/Services/CoFleetHost" \
    COFLEET_TEST_ROOT="$test_root/python" \
    python3 -m unittest discover -s "$COFLEET_ROOT/Tests/HostTests" -v

if [[ "$run_ui" == true ]]; then
    "$SCRIPT_DIR/run-ui-tests.sh"
fi

cofleet_log "test suite passed"
