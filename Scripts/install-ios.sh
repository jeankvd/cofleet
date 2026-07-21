#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

device=""
build_first=false
launch_after=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            shift
            [[ $# -gt 0 ]] || cofleet_die "--device requires a device identifier"
            device="$1"
            ;;
        --build) build_first=true ;;
        --launch) launch_after=true ;;
        -h|--help)
            printf 'Usage: Scripts/install-ios.sh --device <identifier> [--build] [--launch]\n'
            exit 0
            ;;
        *) cofleet_die "unknown option: $1" ;;
    esac
    shift
done

[[ -n "$device" ]] || cofleet_die "--device is required"
cofleet_require_command xcrun

if [[ "$build_first" == true ]]; then
    COFLEET_SIGNING=1 "$SCRIPT_DIR/build.sh" ios-device
fi

configuration="${CONFIGURATION:-Release}"
derived_data="${COFLEET_DERIVED_DATA:-$COFLEET_ROOT/.build/DerivedData}"
source_app="$derived_data/Build/Products/${configuration}-iphoneos/CoFleet.app"
[[ -d "$source_app" ]] || cofleet_die "signed device app not found at $source_app; run this script with --build"

xcrun devicectl device install app --device "$device" "$source_app"
cofleet_log "installed CoFleet and its embedded Watch app on device $device"

if [[ "$launch_after" == true ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Info.plist")"
    xcrun devicectl device process launch --device "$device" "$bundle_id"
    cofleet_log "launched $bundle_id"
fi
