#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

platform="${COFLEET_UI_PLATFORM:-all}"
if [[ "${1:-}" == "--platform" ]]; then
    shift
    [[ $# -gt 0 ]] || cofleet_die "--platform requires ios, macos, or all"
    platform="$1"
    shift
fi
[[ $# -eq 0 ]] || cofleet_die "usage: Scripts/run-ui-tests.sh [--platform ios|macos|all]"
[[ "$platform" == "ios" || "$platform" == "macos" || "$platform" == "all" ]] || \
    cofleet_die "unsupported UI test platform: $platform"

cofleet_require_command xcodebuild
cofleet_require_command xcrun
[[ -d "$COFLEET_ROOT/CoFleet.xcodeproj" ]] || "$SCRIPT_DIR/generate-project.sh"

results_root="$COFLEET_ROOT/.artifacts/UI-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$results_root"

if [[ "$platform" == "ios" || "$platform" == "all" ]]; then
    simulator_id="${COFLEET_IOS_SIMULATOR_ID:-}"
    if [[ -z "$simulator_id" ]]; then
        simulator_id="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }')"
    fi
    [[ -n "$simulator_id" ]] || cofleet_die "no available iPhone simulator was found"
    cofleet_log "running iOS UI smoke on simulator $simulator_id"
    xcodebuild \
        -project "$COFLEET_ROOT/CoFleet.xcodeproj" \
        -scheme CoFleetIOS \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        -derivedDataPath "$COFLEET_ROOT/.build/UITestDerivedData" \
        -resultBundlePath "$results_root/CoFleetIOS.xcresult" \
        -parallel-testing-enabled NO \
        test
fi

if [[ "$platform" == "macos" || "$platform" == "all" ]]; then
    cofleet_log "running macOS UI smoke"
    # The production app-group entitlement requires an Apple Development
    # profile. Omit only that entitlement file for the ad-hoc UI smoke;
    # Xcode still injects its sandbox and XCTest automation entitlements.
    xcodebuild \
        -project "$COFLEET_ROOT/CoFleet.xcodeproj" \
        -scheme CoFleetMac \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$COFLEET_ROOT/.build/MacUITestDerivedData" \
        -resultBundlePath "$results_root/CoFleetMac.xcresult" \
        -parallel-testing-enabled NO \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_ENTITLEMENTS= \
        test
fi

cofleet_log "UI smoke tests passed; results are in $results_root"
