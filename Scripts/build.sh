#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<'EOF'
Usage: Scripts/build.sh <macos|ios-simulator|ios-device|watch|ios-widgets|watch-widgets|all>

Builds only. It never installs or launches an application.
Set COFLEET_SIGNING=1 to allow configured signing; builds are unsigned by default.
Set COFLEET_ALLOW_PROVISIONING_UPDATES=1 with signing to let Xcode create or
refresh development profiles and register the selected device.
EOF
}

build_kind="${1:-}"
if [[ -z "$build_kind" || "$build_kind" == "-h" || "$build_kind" == "--help" ]]; then
    usage
    [[ -n "$build_kind" ]] && exit 0 || exit 2
fi

cofleet_require_command xcodebuild
[[ -d "$COFLEET_ROOT/CoFleet.xcodeproj" ]] || "$SCRIPT_DIR/generate-project.sh"

configuration="${CONFIGURATION:-Release}"
derived_data="${COFLEET_DERIVED_DATA:-$COFLEET_ROOT/.build/DerivedData}"
revision="$(cofleet_revision)"

common=(
    -project "$COFLEET_ROOT/CoFleet.xcodeproj"
    -configuration "$configuration"
    -derivedDataPath "$derived_data"
    "COFLEET_SOURCE_REVISION=$revision"
)

if [[ "${COFLEET_SIGNING:-0}" != "1" ]]; then
    common+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
elif [[ "${COFLEET_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
    common+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
fi

run_build() {
    local scheme="$1"
    local destination="$2"
    cofleet_log "building $scheme for $destination ($configuration)"
    xcodebuild "${common[@]}" -scheme "$scheme" -destination "$destination" build
}

case "$build_kind" in
    macos)
        run_build CoFleetMac 'generic/platform=macOS'
        ;;
    ios-simulator)
        run_build CoFleetIOS 'generic/platform=iOS Simulator'
        ;;
    ios-device)
        run_build CoFleetIOS 'generic/platform=iOS'
        ;;
    watch)
        run_build CoFleetWatch 'generic/platform=watchOS'
        ;;
    ios-widgets)
        run_build CoFleetWidgets 'generic/platform=iOS Simulator'
        ;;
    watch-widgets)
        run_build CoFleetWatchWidgets 'generic/platform=watchOS'
        ;;
    all)
        run_build CoFleetMac 'generic/platform=macOS'
        run_build CoFleetIOS 'generic/platform=iOS Simulator'
        run_build CoFleetIOS 'generic/platform=iOS'
        run_build CoFleetWatch 'generic/platform=watchOS'
        run_build CoFleetWidgets 'generic/platform=iOS Simulator'
        run_build CoFleetWatchWidgets 'generic/platform=watchOS'
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

cofleet_log "build completed; nothing was installed or launched"
