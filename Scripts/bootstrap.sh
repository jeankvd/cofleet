#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

install_tools=false
if [[ "${1:-}" == "--install-tools" ]]; then
    install_tools=true
elif [[ $# -gt 0 ]]; then
    cofleet_die "usage: Scripts/bootstrap.sh [--install-tools]"
fi

if [[ "$install_tools" == true ]]; then
    cofleet_require_command brew
    cofleet_log "installing declared Homebrew tools"
    brew bundle --file "$COFLEET_ROOT/Brewfile"
fi

cofleet_require_command xcodegen
cofleet_require_command xcrun
cofleet_require_command swift
cofleet_require_command python3

if [[ ! -f "$COFLEET_ROOT/Config/Local.xcconfig" ]]; then
    cp "$COFLEET_ROOT/Config/Local.xcconfig.example" "$COFLEET_ROOT/Config/Local.xcconfig"
    cofleet_log "created ignored Config/Local.xcconfig from the public example"
fi

"$SCRIPT_DIR/generate-app-icons.sh"
"$SCRIPT_DIR/generate-project.sh"

cofleet_log "resolving local Swift package graph"
swift_package_args=(package --package-path "$COFLEET_ROOT/Packages/CoFleetKit")
if [[ "${COFLEET_SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    swift_package_args+=(--disable-sandbox)
fi
swift "${swift_package_args[@]}" resolve

cofleet_log "checking Python host package imports"
PYTHONPATH="$COFLEET_ROOT/Services/CoFleetHost" \
    python3 -m compileall -q "$COFLEET_ROOT/Services/CoFleetHost/cofleet_host"

cofleet_log "bootstrap complete; build and install remain separate commands"
