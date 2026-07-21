#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

build_first=false
launch_after=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) build_first=true ;;
        --launch) launch_after=true ;;
        -h|--help)
            printf 'Usage: Scripts/install-macos.sh [--build] [--launch]\n'
            exit 0
            ;;
        *) cofleet_die "unknown option: $1" ;;
    esac
    shift
done

if [[ "$build_first" == true ]]; then
    COFLEET_SIGNING=1 "$SCRIPT_DIR/build.sh" macos
fi

configuration="${CONFIGURATION:-Release}"
derived_data="${COFLEET_DERIVED_DATA:-$COFLEET_ROOT/.build/DerivedData}"
source_app="$derived_data/Build/Products/$configuration/CoFleet.app"
destination_dir="${COFLEET_MAC_INSTALL_DIR:-$HOME/Applications}"
destination_app="$destination_dir/CoFleet.app"

[[ -d "$source_app" ]] || cofleet_die "signed app not found at $source_app; run this script with --build"
codesign --verify --strict "$source_app" >/dev/null 2>&1 || \
    cofleet_die "the build is unsigned or invalid; configure signing and use --build"

mkdir -p "$destination_dir"
staging_dir="$(mktemp -d "$destination_dir/.cofleet-install.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$source_app" "$staging_dir/CoFleet.app"

backup_app="$staging_dir/Previous.app"
if [[ -e "$destination_app" ]]; then
    [[ -d "$destination_app" ]] || cofleet_die "refusing to replace non-directory path: $destination_app"
    mv "$destination_app" "$backup_app"
fi

if ! mv "$staging_dir/CoFleet.app" "$destination_app"; then
    [[ ! -d "$backup_app" ]] || mv "$backup_app" "$destination_app"
    cofleet_die "installation failed"
fi

cofleet_log "installed $destination_app"
if [[ "$launch_after" == true ]]; then
    open "$destination_app"
    cofleet_log "launched CoFleet"
fi
