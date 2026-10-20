#!/bin/bash

# Offsider Test Runner Script
# Automates building Offsider executable, playground app, and running tests

set -e  # Exit on any error

# A git-ignored .env beside this script names the local simulators, AVDs and signing team (see .env.example).
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/.env"
    set +a
fi

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/scripts/e2e-environment.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/ui.sh"

# Any adb server the suites start sends no mDNS multicast on the LAN.
export ADB_MDNS=0
# An accidental overlap with another runner on the same device waits rather than failing with exit 8.
export OFFSIDER_WAIT_LOCK="${OFFSIDER_WAIT_LOCK:-30}"
# Suites name their devices; a shell's default device must not pick one.
unset OFFSIDER_DEVICE
# Captures from the suites never land in a developer's evidence run; suites that test runs set their own folder.
export OFFSIDER_RUN=off

# Configuration
SIMULATOR_UDID="${SIMULATOR_UDID:-}"
PLAYGROUND_PROJECT="OffsiderPlaygroundApp/OffsiderPlayground.xcodeproj"
PLAYGROUND_SCHEME="OffsiderPlayground"
BUNDLE_ID="com.mpalmes.offsider.playground"
ANDROID_PLAYGROUND_PACKAGE="com.mpalmes.offsider.playground.rn"

# Only a person may allow a device: an agent hands the command to the user, a person runs it.
if [[ "$UI_AGENT" == 1 ]]; then
    RUN_YOURSELF="Ask the user to run this in their own terminal"
    RENEW_YOURSELF="Ask the user to renew it in their own terminal"
else
    RUN_YOURSELF="Run this yourself"
    RENEW_YOURSELF="Renew it yourself"
fi

# The suites this run means to run and how each one ended, for the results at the end.
SUITES_PLANNED=" "
SUITE_WIDTH=0
RESULT_NAMES=()
RESULT_STATES=()
RESULT_TIMES=()
# A rerun command a failed suite's name completes, set while the React Native suites run.
RERUN=""
# The log of the quiet step running now, removed if the run is stopped part way.
STEP_LOG=""

plan_suites() {
    local suite
    for suite in "$@"; do
        [[ "$SUITES_PLANNED" == *" $suite "* ]] && continue
        SUITES_PLANNED="${SUITES_PLANNED}${suite} "
        if (( ${#suite} > SUITE_WIDTH )); then SUITE_WIDTH=${#suite}; fi
    done
    return 0
}

record_suite() {
    RESULT_NAMES+=("$1")
    RESULT_STATES+=("$2")
    RESULT_TIMES+=("$3")
    UI_ROW_LABEL_WIDTH="$SUITE_WIDTH" ui_row "$2" "$1" "$3"
}

# The counts so far and a row per suite that ran, when more than one did.
show_results() {
    local k=0 passed=0 failed=0 empty=0 planned summary
    (( ${#RESULT_NAMES[@]} > 1 )) || return 0
    while (( k < ${#RESULT_NAMES[@]} )); do
        case "${RESULT_STATES[k]}" in
            ok) passed=$(( passed + 1 )) ;;
            fail) failed=$(( failed + 1 )) ;;
            *) empty=$(( empty + 1 )) ;;
        esac
        k=$(( k + 1 ))
    done
    planned=$(( $(wc -w <<<"$SUITES_PLANNED") ))
    summary="$passed passed"
    if (( failed > 0 )); then summary="$summary $UI_DOT $failed failed"; fi
    if (( empty > 0 )); then summary="$summary $UI_DOT $empty with no tests"; fi
    if (( planned > ${#RESULT_NAMES[@]} )); then summary="$summary $UI_DOT $(( planned - ${#RESULT_NAMES[@]} )) not run"; fi
    ui_header "🧪" "Results" "$summary"
    k=0
    while (( k < ${#RESULT_NAMES[@]} )); do
        UI_ROW_LABEL_WIDTH="$SUITE_WIDTH" ui_row "${RESULT_STATES[k]}" "${RESULT_NAMES[k]}" "${RESULT_TIMES[k]}"
        k=$(( k + 1 ))
    done
    return 0
}

# Runs swift test with its output shown, then a status row with the time it took; returns swift test's status.
# A capture file also gets the output, for the caller to read.
run_swift_suite() {
    local name="$1" capture="$2" started status=0 took
    shift 2
    local args=(--skip-build --no-parallel "$@")
    [[ "$VERBOSE" == true ]] && args+=(--verbose)
    plan_suites "$name"
    ui_heading "" "$name"
    ui_kv "Run" "swift test ${args[*]}"
    started=$SECONDS
    if [[ -n "$capture" ]]; then
        set +e
        run_selected_swift test "${args[@]}" 2>&1 | tee "$capture"
        status=${PIPESTATUS[0]}
        set -e
    else
        run_selected_swift test "${args[@]}" || status=$?
    fi
    took="$(ui_elapsed $(( SECONDS - started )))"
    if [[ "$status" -ne 0 ]]; then
        record_suite "$name" fail "$took"
    elif [[ -n "$capture" ]] && grep -q "No matching test cases were run" "$capture" && ! grep -q "Test run with [1-9]" "$capture"; then
        record_suite "$name" skip "matched no tests"
    else
        record_suite "$name" ok "$took"
    fi
    return "$status"
}

# A quiet step behind a spinner, its output kept in a log that a failure shows; --verbose streams it instead.
run_step() {
    local label="$1" status=0
    shift
    if [[ "$VERBOSE" == true ]]; then
        ui_heading "" "$label"
        "$@" || status=$?
        if [[ "$status" -eq 0 ]]; then ui_row ok "$label"; else ui_row fail "$label" >&2; fi
        return "$status"
    fi
    STEP_LOG="$(mktemp "${TMPDIR:-/tmp}/offsider-e2e-step.XXXXXX")"
    if UI_TAIL_LINES=80 ui_run_logged "$label" "$STEP_LOG" "$@"; then
        rm -f "$STEP_LOG"
        STEP_LOG=""
        return 0
    fi
    # The log stays for the person to read; its path is on the screen.
    STEP_LOG=""
    return 1
}

# Short help: the modes. --help-env has the settings and suite names.
show_usage() {
    cat <<EOF
Usage: $0 [mode] [options] [SuiteName]

Modes (run $0 on a terminal with none to pick one):
  -u, --unit-tests     Unit tests, no device
      --simulator      Simulator suites on an iPhone simulator (the default)
  -a, --android        Android emulator suites on Offsider_E2E, booted if it is not running
      --rn-ios         React Native suites on an iPhone simulator (needs pnpm)
      --foldable       Foldable suite on the Offsider Duo simulator
      --android-fold   Foldable suite on the Offsider_E2E_Fold AVD, booted if it is not running
      --android-phone  Phone suites on a USB phone you allowed (.build/debug/offsider device-access allow)
      --ios-device     Device suites on an iPhone or iPad you allowed
Options: -t tests only, -b build only, -c clean build, -v verbose, --rn-debug (with --rn-ios or --android)

Missing a simulator or AVD? scripts/e2e-devices.sh creates them.
Settings, suite names and examples: $0 --help-env
EOF
}

show_env_help() {
    cat <<EOF
Settings for $0 (a git-ignored .env in the repository root is loaded first; see .env.example)

All modes:
  DEVELOPER_DIR             Xcode used to build and run tests (Xcode 27 uses Device Hub)
  OFFSIDER_BIN_PATH         Prebuilt Offsider executable to test with --tests-only
  OFFSIDER_REUSE_IDB=1      Reuse a build_products that matches the idb pin and this Xcode, here or in
                            another checkout of this repository, instead of rebuilding idb
  -s, --sequential          Run suites one by one (always on)

Simulator (--simulator, --rn-ios):
  OFFSIDER_SIMULATOR_NAME   Exact name of the simulator to test on (default: a stock iPhone on the Xcode's iOS major, booted first)
  SIMULATOR_UDID            UDID of the simulator to test on (overrides OFFSIDER_SIMULATOR_NAME)
  OFFSIDER_LANDSCAPE_E2E=1  Run gated landscape orientation precision tests when Simulator menu automation is available

Android (--android):
  OFFSIDER_ANDROID_DEVICE   The E2E emulator's serial or AVD name (default: OFFSIDER_ANDROID_E2E_AVD, booted if needed)
  OFFSIDER_ANDROID_APK      The React Native playground's release APK (default: OffsiderPlaygroundRN/build/android/OffsiderPlaygroundRN-release.apk)
  OFFSIDER_ANDROID_E2E_AVD  The only AVD the suites may drive: Offsider_E2E (default), Offsider_E2E_Fold or Offsider_E2E_API28 (Android 9)
  OFFSIDER_ANDROID_LANDSCAPE_E2E=1  Also run the landscape suite on Settings
  OFFSIDER_ANDROID_BOOT_E2E=1       Also stop and cold-boot the E2E AVD
  OFFSIDER_ANDROID_DEBUG_APK        The Debug APK for --rn-debug (default: built by scripts/rn-playground.sh build-android --debug)

Foldables (--foldable, --android-fold):
  OFFSIDER_FOLDABLE_SIMULATOR_NAME  The iPhone Duo simulator for --foldable (default: Offsider Duo); SIMULATOR_UDID overrides it
  OFFSIDER_ANDROID_FOLD_AVD The fold AVD for --android-fold (default: Offsider_E2E_Fold); OFFSIDER_ANDROID_DEVICE overrides it

Android phone (--android-phone):
  OFFSIDER_ANDROID_PHONE    The phone's exact USB serial from adb devices -l; no other device is touched
                            Unset: the one active Android phone on the allow-list, only when its allowance pins
                            com.mpalmes.offsider.playground.rn (several, none or another app is an error)
                            The user must first allow it: .build/debug/offsider device-access allow, then choose the phone
                            and pin com.mpalmes.offsider.playground.rn
  OFFSIDER_ANDROID_APK      The React Native playground's release APK, installed once and left in place

iPhone or iPad (--ios-device, needs XcodeGen):
  OFFSIDER_IOS_DEVICE       The device's exact UDID from devicectl list devices; no other device is touched
                            Unset: the one active iPhone or iPad on the allow-list, only when its allowance pins
                            com.mpalmes.offsider.playground (several, none or another app is an error)
                            The user must first allow it: .build/debug/offsider device-access allow, then choose the device
                            and pin com.mpalmes.offsider.playground
  OFFSIDER_IOS_TEAM_ID      The team that signs the runner and the playground, installed once and left in place
                            Unset: the team the device's allowance records

React Native on iOS (--rn-ios, needs pnpm):
  OFFSIDER_RN_IOS_APP       The Release simulator app (default: built by scripts/rn-playground.sh build-ios --if-changed)
  OFFSIDER_RN_IOS_DEBUG_APP The Debug simulator app for --rn-debug (default: built by build-ios --debug --if-changed)

Suite names (run just one):
  Simulator: BatchTests ButtonTests CommandNamingTests DescribeUITests DeviceControlTests DoctorTests DragTests
             GestureTests InitTests KeyComboTests KeySequenceTests KeyTests ListDevicesTests LogsTests
             ParkedSheetTests PresentationFixtureTests PresentedSheetTests RecordVideoTests SliderTests
             StreamVideoDebugTests StreamVideoTests SwipeTests TapTests TouchTests TypeTests VerifyTests
  React Native (with --rn-ios or --android): ReactNative*Tests, for example ReactNativeFixtureSmokeTests

Examples:
  $0 --simulator SwipeTests   # Build everything and run only the swipe tests
  $0 -t SwipeTests            # Skip building, run only the swipe tests
  $0 --android                # Boot Offsider_E2E if needed and run the Android suites
  $0 --rn-ios --rn-debug      # Debug build with Metro on 8742, run ReactNativeDebugSmokeTests
  $0 --android ReactNativeRowsTests   # One React Native suite on the Android emulator
  OFFSIDER_IOS_DEVICE=<udid> OFFSIDER_IOS_TEAM_ID=<team> $0 --ios-device   # Name the device and the team
EOF
}

# The mode picker for a bare run on a terminal; sets the same flags the options do.
pick_mode() {
    if ! UI_RECOMMENDED_INDEX=1 select_menu "What should run?" \
        "🧪|Unit tests|no device" \
        "📱|Simulator|an iPhone simulator and XcodeGen" \
        "🤖|Android emulator|the Offsider_E2E AVD, booted for you" \
        "⚛️|React Native iOS|an iPhone simulator and pnpm" \
        "📖|Foldable|the Offsider Duo simulator" \
        "📖|Android foldable|the Offsider_E2E_Fold AVD, booted for you" \
        "🔌|Android phone|needs a device you allowed" \
        "🔌|iPhone or iPad|needs a device you allowed" \
        "❌|Cancel|"; then
        log "Nothing run."
        exit 0
    fi
    case "$SELECTED_INDEX" in
        0) UNIT_TESTS=true ;;
        1) ;;
        2) ANDROID=true ;;
        3) RN_IOS=true ;;
        4) FOLDABLE=true ;;
        5) ANDROID_FOLD=true ;;
        6) ANDROID_PHONE=true ;;
        7) IOS_DEVICE=true ;;
        *) log "Nothing run."; exit 0 ;;
    esac
}

# Parse command line arguments
BUILD_ONLY=false
TESTS_ONLY=false
UNIT_TESTS=false
ANDROID=false
RN_IOS=false
RN_DEBUG=false
RN_METRO_STARTED=false
FOLDABLE=false
ANDROID_FOLD=false
ANDROID_PHONE=false
IOS_DEVICE=false
FOLDABLE_SIMULATOR_NAME="${OFFSIDER_FOLDABLE_SIMULATOR_NAME:-Offsider Duo}"
ANDROID_FOLD_AVD="${OFFSIDER_ANDROID_FOLD_AVD:-Offsider_E2E_Fold}"
ANDROID_E2E_AVD="${OFFSIDER_ANDROID_E2E_AVD:-Offsider_E2E}"
CLEAN_BUILD=false
SEQUENTIAL=true
VERBOSE=false
TEST_FILTER=""

# React Native suites run by --rn-ios and after the Android suites; a suite not added yet matches nothing and passes.
RN_SUITES=(
    "ReactNativeFixtureSmokeTests"
    "ReactNativeOffscreenTests"
    "ReactNativeOverlayTests"
    "ReactNativeRowsTests"
    "ReactNativeEnvironmentTests"
    "ReactNativeChoiceTests"
    "ReactNativeGestureTests"
    "ReactNativeEvidenceTests"
    "ReactNativeLiveTests"
    "ReactNativeStackCoverTests"
    "ReactNativeStickyFooterTests"
    "ReactNativeLoginTests"
    "ReactNativeSystemPromptTests"
)
RN_DEBUG_SUITES=(
    "ReactNativeDebugSmokeTests"
)

cleanup_test_runner() {
    ui_cleanup
    if [[ -n "$STEP_LOG" && -f "$STEP_LOG" ]]; then
        rm "$STEP_LOG"
    fi
    if [[ "$RN_METRO_STARTED" == true ]]; then
        scripts/rn-playground.sh metro stop || true
    fi
}

trap cleanup_test_runner EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# An agent never gets the picker: a bare run is the simulator suites, as it is off a terminal.
if [[ $# -eq 0 && -t 0 && -t 1 && "$UI_AGENT" != 1 ]]; then
    pick_mode
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --help-env)
            show_env_help
            exit 0
            ;;
        --simulator)
            shift
            ;;
        -b|--build-only)
            BUILD_ONLY=true
            shift
            ;;
        -t|--tests-only)
            TESTS_ONLY=true
            shift
            ;;
        -u|--unit-tests)
            UNIT_TESTS=true
            shift
            ;;
        -a|--android)
            ANDROID=true
            shift
            ;;
        --rn-ios)
            RN_IOS=true
            shift
            ;;
        --rn-debug)
            RN_DEBUG=true
            shift
            ;;
        --foldable)
            FOLDABLE=true
            shift
            ;;
        --android-fold)
            ANDROID_FOLD=true
            shift
            ;;
        --android-phone)
            ANDROID_PHONE=true
            shift
            ;;
        --ios-device)
            IOS_DEVICE=true
            shift
            ;;
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -s|--sequential)
            SEQUENTIAL=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        BatchTests|ButtonTests|CommandNamingTests|DescribeUITests|DeviceControlTests|DoctorTests|GestureTests|InitTests|KeyComboTests|KeySequenceTests|KeyTests|ListDevicesTests|LogsTests|ParkedSheetTests|PresentationFixtureTests|PresentedSheetTests|RecordVideoTests|StreamVideoDebugTests|StreamVideoTests|SwipeTests|DragTests|SliderTests|TapTests|TouchTests|TypeTests|VerifyTests)
            TEST_FILTER="$1"
            shift
            ;;
        ReactNative*Tests)
            TEST_FILTER="$1"
            shift
            ;;
        *)
            die "Unknown option: $1" "$0 --help"
            ;;
    esac
done

if [[ "$UNIT_TESTS" == true ]] &&
   [[ "$BUILD_ONLY" == true || "$TESTS_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
    die "--unit-tests cannot be combined with build, E2E test, clean, or test-filter options."
fi

if [[ "$FOLDABLE" == true || "$ANDROID_FOLD" == true ]]; then
    if [[ "$FOLDABLE" == true && "$ANDROID_FOLD" == true ]]; then
        die "--foldable and --android-fold cannot be combined; run them one at a time."
    fi
    if [[ "$ANDROID" == true || "$RN_IOS" == true || "$RN_DEBUG" == true || "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
        die "--foldable and --android-fold can only be combined with --tests-only and --verbose."
    fi
fi

if [[ "$ANDROID_PHONE" == true ]]; then
    if [[ "$FOLDABLE" == true || "$ANDROID_FOLD" == true || "$ANDROID" == true || "$RN_IOS" == true || "$RN_DEBUG" == true || "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
        die "--android-phone can only be combined with --tests-only and --verbose."
    fi
fi

if [[ "$IOS_DEVICE" == true ]]; then
    if [[ "$ANDROID_PHONE" == true || "$FOLDABLE" == true || "$ANDROID_FOLD" == true || "$ANDROID" == true || "$RN_IOS" == true || "$RN_DEBUG" == true || "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
        die "--ios-device can only be combined with --tests-only and --verbose."
    fi
fi

RN_FILTER=false
[[ "$TEST_FILTER" == ReactNative*Tests ]] && RN_FILTER=true

if [[ "$ANDROID" == true && "$RN_IOS" == true ]]; then
    die "--android and --rn-ios cannot be combined; run them one at a time."
fi

if [[ "$ANDROID" == true || "$RN_IOS" == true ]] &&
   [[ "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true ]]; then
    die "--android and --rn-ios can only be combined with --rn-debug, --tests-only, --verbose and a ReactNative*Tests filter."
fi

if [[ "$RN_FILTER" == true && "$ANDROID" != true && "$RN_IOS" != true ]]; then
    die "$TEST_FILTER needs --rn-ios or --android."
fi

if [[ -n "$TEST_FILTER" && "$RN_FILTER" != true ]] && [[ "$ANDROID" == true || "$RN_IOS" == true ]]; then
    die "$TEST_FILTER is a native iOS suite; --android and --rn-ios only take a ReactNative*Tests filter."
fi

if [[ "$RN_DEBUG" == true ]]; then
    if [[ "$ANDROID" != true && "$RN_IOS" != true ]]; then
        die "--rn-debug needs --rn-ios or --android."
    fi
    if [[ -n "$TEST_FILTER" ]]; then
        die "--rn-debug runs only ReactNativeDebugSmokeTests and takes no test filter."
    fi
fi

# Function to check prerequisites
check_prerequisites() {
    # Check if we're in the right directory
    if [[ ! -f "Package.swift" ]]; then
        die "Run this from the Offsider checkout." "cd \"$(dirname "$0")\" && ./test-runner.sh"
    fi

    # Check if Xcode is available
    if ! command -v xcodebuild &> /dev/null; then
        die "xcodebuild not found." "./scripts/build.sh dev"
    fi

    # Check if Swift is available
    if ! command -v swift &> /dev/null; then
        die "swift not found." "./scripts/build.sh dev"
    fi

    if [[ "$UNIT_TESTS" != true && "$ANDROID" != true && "$ANDROID_FOLD" != true && "$ANDROID_PHONE" != true && "$IOS_DEVICE" != true ]] && ! command -v jq &> /dev/null; then
        die "jq not found (it picks the simulator runtime)." "brew install jq"
    fi

    if [[ "$RN_IOS" == true || "$RN_DEBUG" == true ]] && ! command -v pnpm &> /dev/null; then
        die "pnpm not found (it builds the React Native playground)." "brew install pnpm"
    fi

    if [[ "$UNIT_TESTS" != true && "$ANDROID" != true && "$ANDROID_FOLD" != true && "$ANDROID_PHONE" != true && "$RN_IOS" != true ]] && ! command -v xcodegen &> /dev/null; then
        die "xcodegen not found (it generates the playground project)." "brew install xcodegen"
    fi

    if ! configure_e2e_environment; then
        die "Xcode 26 or later is required to build and test Offsider." "DEVELOPER_DIR=<Xcode 27.app>/Contents/Developer $0"
    fi

    ui_row ok "Tools ready" "Xcode $SELECTED_XCODE_VERSION ($(e2e_xcode_build "$SELECTED_DEVELOPER_DIR"))"
}

# Refuses a simulator in a crash loop, the same rule as doctor's simulator.crash-loop; a direct scan because Offsider is not built yet.
check_simulator_crash_loop() {
    local udid="$1"
    local reports="$HOME/Library/Logs/DiagnosticReports"
    [[ -d "$reports" ]] || return 0
    local looping
    # Only each report's first 16 KB, as doctor reads.
    looping=$(find "$reports" -maxdepth 1 -type f -name '*.ips' -mmin -10 -print0 2>/dev/null \
        | while IFS= read -r -d '' report; do
            prefix=$(head -c 16384 "$report")
            [[ "$prefix" == *"com.apple.CoreSimulator.SimDevice.$udid\""* ]] || continue
            printf '%s\n' "$prefix" | grep -o -m 1 '"procName" : "[^"]*"' | sed 's/.*: "\(.*\)"/\1/'
        done | sort | uniq -c | awk '{ n = $1; sub(/^ *[0-9]+ /, ""); if (n >= 5) printf "%s crashed %d times in the last 10 minutes\n", $0, n }') || true
    if [[ -n "$looping" ]]; then
        print_error "Simulator $udid is in a crash loop. Erase it (this removes its apps and settings), then run again."
        while IFS= read -r line; do log "    $line"; done <<<"$looping"
        ui_try "xcrun simctl shutdown $udid && xcrun simctl erase $udid"
        exit 1
    fi
}

# Function to boot simulator
boot_simulator() {
    if ! select_e2e_simulator; then
        die "Could not select an iOS simulator for E2E tests." "SIMULATOR_UDID=<udid from xcrun simctl list devices> $0"
    fi

    SIMULATOR_STATUS=$(xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -o "Booted\|Shutdown" || echo "NotFound")

    if [[ -z "$SIMULATOR_UDID" || "$SIMULATOR_STATUS" == "NotFound" ]]; then
        print_error "Simulator ${SIMULATOR_UDID:-with no UDID} was not found. These iPhones are:"
        xcrun simctl list devices | grep "iPhone" >&2 || true
        ui_try "SIMULATOR_UDID=<udid> $0"
        exit 1
    fi

    check_simulator_crash_loop "$SIMULATOR_UDID"

    if [[ "$SIMULATOR_STATUS" != "Booted" ]]; then
        run_step "Booting $SIMULATOR_NAME" xcrun simctl bootstatus "$SIMULATOR_UDID" -b ||
            die "$SIMULATOR_NAME did not boot." "xcrun simctl bootstatus $SIMULATOR_UDID -b"
    else
        ui_row ok "$SIMULATOR_NAME" "booted $UI_DOT $SIMULATOR_UDID"
    fi
}

generate_playground_project() {
    xcodegen generate --spec OffsiderPlaygroundApp/project.yml --quiet
}

# Function to clean build
clean_build() {
    if [[ "$CLEAN_BUILD" == true ]]; then
        run_step "Cleaning the Swift build" run_selected_swift package clean ||
            die "Could not clean the Swift build." "swift package clean"
        run_step "Cleaning the playground build" \
            xcodebuild clean -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID" ||
            die "Could not clean the playground build." "xcodebuild clean -project $PLAYGROUND_PROJECT -scheme $PLAYGROUND_SCHEME"
    fi
}

build_idb_xcframeworks() {
    # dev reuses a build here or in another checkout only when it matches the pin and this Xcode.
    if [[ "${OFFSIDER_REUSE_IDB:-0}" == "1" ]]; then
        scripts/build.sh dev
        return
    fi
    scripts/build.sh dev --rebuild

    run_step "Cleaning the Swift build" run_selected_swift package clean ||
        die "Could not clean the Swift build." "swift package clean"
}

# Function to build Offsider executable
build_offsider() {
    run_step "Building Offsider" run_selected_swift build --build-tests ||
        die "Could not build Offsider with Xcode $SELECTED_XCODE_VERSION." "swift build --build-tests"

    local offsider_bin_path
    offsider_bin_path="$(run_selected_swift build --show-bin-path)/offsider"

    # Verify the executable exists
    if [[ ! -f "$offsider_bin_path" ]]; then
        die "The build finished, but there is no Offsider at $offsider_bin_path." "swift build --build-tests"
    fi
}

ensure_test_framework_rpaths() {
    local build_dir
    build_dir="$(run_selected_swift build --show-bin-path)"

    local package_frameworks_dir="$build_dir/PackageFrameworks"
    mkdir -p "$package_frameworks_dir"

    local framework_names=(
        "FBControlCore.framework"
        "FBDeviceControl.framework"
        "FBSimulatorControl.framework"
        "XCTestBootstrap.framework"
    )

    local framework
    for framework in "$build_dir"/*.framework "$build_dir"/ExecutableModules/*.framework; do
        [[ -d "$framework" ]] || continue
        framework_names+=("$(basename "$framework")")
    done

    local framework_name
    for framework_name in "${framework_names[@]}"; do
        local link_path="$package_frameworks_dir/$framework_name"
        if [[ -e "$link_path" || -L "$link_path" ]]; then
            continue
        fi

        ln -s "../$framework_name" "$link_path"
    done
}

run_unit_tests() {
    ensure_test_framework_rpaths
    OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    export OFFSIDER_BIN_PATH
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    # Unit tests spawn offsider against held locks and expect it to fail at once.
    unset OFFSIDER_WAIT_LOCK OFFSIDER_ANDROID_PHONE

    local status=0
    run_swift_suite "Unit tests" "" || status=$?
    if [[ "$status" -ne 0 ]]; then
        die "Unit tests failed." "" "$status"
    fi
}

# Sets the named variable to its existing value, else to the React Native playground artefact, rebuilt when its sources changed.
# Usage: resolve_rn_artefact <variable> <ios|android> [--debug] [udid]
resolve_rn_artefact() {
    local variable="$1" platform="$2"
    shift 2
    local current="${!variable:-}"
    if [[ -n "$current" ]]; then
        [[ -e "$current" ]] || die "$variable is $current, which does not exist."
        return
    fi
    if [[ ! -x scripts/rn-playground.sh ]]; then
        die "Set $variable to the React Native playground's $platform build."
    fi
    # The build is skipped when its sources have not changed since the last one.
    run_step "Building the React Native playground for $platform" scripts/rn-playground.sh "build-$platform" --if-changed "$@" ||
        die "The React Native playground for $platform did not build." "scripts/rn-playground.sh build-$platform --if-changed${*:+ $*}"
    local flags=()
    [[ " $* " == *" --debug "* ]] && flags+=(--debug)
    current="$(scripts/rn-playground.sh "path-$platform" "${flags[@]}")"
    if [[ ! -e "$current" ]]; then
        die "$current is missing after the build. Set $variable to the React Native playground's $platform build."
    fi
    printf -v "$variable" '%s' "$current"
}

resolve_android_apk() {
    resolve_rn_artefact OFFSIDER_ANDROID_APK android
}

# Starts Metro on 8742 for the Debug builds unless one is already running; the EXIT trap stops a Metro this run started.
start_rn_metro() {
    if scripts/rn-playground.sh metro status >/dev/null; then
        ui_row ok "Metro" "already running $UI_DOT stays up after this run"
        return
    fi
    RN_METRO_STARTED=true
    run_step "Starting Metro" scripts/rn-playground.sh metro start ||
        die "Metro did not start." "scripts/rn-playground.sh metro start"
}

# Runs each suite with its own swift test; a suite that does not exist yet matches nothing, which swift test passes.
run_suite_list() {
    local suite output_log
    plan_suites "$@"
    for suite in "$@"; do
        output_log="$(mktemp "${TMPDIR:-/tmp}/offsider-e2e-suite.XXXXXX")"
        if ! run_swift_suite "$suite" "$output_log" --filter "$suite"; then
            local missing_on
            missing_on="$(grep -oE "${ANDROID_PLAYGROUND_PACKAGE//./\\.} is not installed on [A-Za-z0-9_:-]+" "$output_log" | head -1)"
            rm -f "$output_log"
            show_results
            if [[ -n "$missing_on" ]]; then
                die "$suite failed: the playground is not installed on ${missing_on##* }." "scripts/rn-playground.sh install-android ${missing_on##* }"
            fi
            die "$suite failed." "${RERUN:+$RERUN $suite}"
        fi
        rm -f "$output_log"
    done
}

# The React Native suites, or the one named by a ReactNative*Tests filter.
run_rn_suites() {
    if [[ "$ANDROID" == true ]]; then RERUN="$0 --android -t"; else RERUN="$0 --rn-ios -t"; fi
    if [[ -n "$TEST_FILTER" ]]; then
        run_suite_list "$TEST_FILTER"
    else
        run_suite_list "${RN_SUITES[@]}"
    fi
    RERUN=""
}

run_rn_ios_tests() {
    ensure_test_framework_rpaths

    export SIMULATOR_UDID
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    export OFFSIDER_ANDROID_E2E=0
    unset OFFSIDER_ANDROID_DEBUG_APK OFFSIDER_ANDROID_PHONE
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    if [[ ! -f "$OFFSIDER_BIN_PATH" ]]; then
        die "Offsider executable not found at $OFFSIDER_BIN_PATH. Run without --tests-only, run swift build first, or set OFFSIDER_BIN_PATH to a prebuilt payload."
    fi

    export OFFSIDER_RN_E2E=1
    if [[ "$RN_DEBUG" == true ]]; then
        resolve_rn_artefact OFFSIDER_RN_IOS_DEBUG_APP ios --debug "$SIMULATOR_UDID"
        export OFFSIDER_RN_IOS_DEBUG_APP
        export OFFSIDER_RN_DEBUG_E2E=1
        start_rn_metro
        log "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_RN_DEBUG_E2E=1, OFFSIDER_RN_IOS_DEBUG_APP=$OFFSIDER_RN_IOS_DEBUG_APP, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"
        run_suite_list "${RN_DEBUG_SUITES[@]}"
        return
    fi

    resolve_rn_artefact OFFSIDER_RN_IOS_APP ios "$SIMULATOR_UDID"
    export OFFSIDER_RN_IOS_APP
    export OFFSIDER_RN_DEBUG_E2E=0
    log "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_RN_E2E=1, OFFSIDER_RN_IOS_APP=$OFFSIDER_RN_IOS_APP, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"
    run_rn_suites
}

# Whether scripts/e2e-devices-core.sh knows the device: "true", "false", or nothing for a name it does not manage.
e2e_device_exists() {
    command -v jq >/dev/null 2>&1 || return 0
    scripts/e2e-devices-core.sh status 2>/dev/null | jq -r --arg name "$1" '.devices[] | select(.name == $name) | .exists' || true
}

# Boots the E2E AVD through offsider boot when OFFSIDER_ANDROID_DEVICE names it; a serial is left alone, and the suites still check the AVD name.
ensure_avd_running() {
    local avd="$1" output serial
    [[ "$OFFSIDER_ANDROID_DEVICE" == "$avd" ]] || return 0
    case "$avd" in
        Offsider_E2E|Offsider_E2E_Fold|Offsider_E2E_API28) ;;
        *) die "$avd is not an Offsider E2E AVD, so it is not booted." "OFFSIDER_ANDROID_E2E_AVD=Offsider_E2E $0 --android" ;;
    esac
    if [[ "$(e2e_device_exists "$avd")" == false ]]; then
        die "There is no $avd AVD yet." "scripts/e2e-devices.sh create"
    fi
    [[ -x "$OFFSIDER_BIN_PATH" ]] || die "Offsider is not built at $OFFSIDER_BIN_PATH." "swift build"
    # offsider boot shows its own progress on stderr, so no spinner here.
    log "Starting $avd"
    output="$("$OFFSIDER_BIN_PATH" boot "$avd")" || die "offsider boot $avd failed." "\"$OFFSIDER_BIN_PATH\" boot $avd"
    serial="$(printf '%s\n' "$output" | tail -1 | tr -d '\r')"
    [[ "$serial" =~ ^emulator-[0-9]+$ ]] || die "offsider boot $avd printed no emulator serial." "\"$OFFSIDER_BIN_PATH\" boot $avd"
    ui_row ok "$avd" "running $UI_DOT $serial"
}

run_android_tests() {
    export OFFSIDER_ANDROID_DEVICE="${OFFSIDER_ANDROID_DEVICE:-$ANDROID_E2E_AVD}"
    ensure_test_framework_rpaths

    export OFFSIDER_ANDROID_E2E=1
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    export OFFSIDER_RN_E2E=0
    unset OFFSIDER_RN_IOS_DEBUG_APP OFFSIDER_ANDROID_PHONE
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    ensure_avd_running "$ANDROID_E2E_AVD"

    if [[ "$RN_DEBUG" == true ]]; then
        resolve_rn_artefact OFFSIDER_ANDROID_DEBUG_APK android --debug
        export OFFSIDER_ANDROID_DEBUG_APK
        export OFFSIDER_RN_DEBUG_E2E=1
        start_rn_metro
        log "Environment: OFFSIDER_ANDROID_DEVICE=$OFFSIDER_ANDROID_DEVICE, OFFSIDER_ANDROID_E2E_AVD=$ANDROID_E2E_AVD, OFFSIDER_RN_DEBUG_E2E=1, OFFSIDER_ANDROID_DEBUG_APK=$OFFSIDER_ANDROID_DEBUG_APK"
        run_suite_list "${RN_DEBUG_SUITES[@]}"
        return
    fi

    resolve_android_apk
    export OFFSIDER_ANDROID_APK
    export OFFSIDER_RN_DEBUG_E2E=0
    log "Environment: OFFSIDER_ANDROID_DEVICE=$OFFSIDER_ANDROID_DEVICE, OFFSIDER_ANDROID_E2E_AVD=$ANDROID_E2E_AVD, OFFSIDER_ANDROID_APK=$OFFSIDER_ANDROID_APK"

    if [[ -n "$TEST_FILTER" ]]; then
        run_rn_suites
        return
    fi

    local suites=(
        "AndroidListDevicesTests"
        "AndroidDescribeUITests"
        "AndroidHelperTests"
        "AndroidTapTests"
        "AndroidSelectorTests"
        "AndroidTouchTests"
        "AndroidSwipeGestureTests"
        "AndroidSliderTests"
        "AndroidTypeTests"
        "AndroidKeyTests"
        "AndroidButtonTests"
        "AndroidScreenshotE2ETests"
        "AndroidVideoTests"
        "AndroidBatchTests"
        "AndroidVerifyTests"
        "AndroidDeviceStateE2ETests"
        "AndroidFallbackTests"
        "AndroidJWTTests"
        "AndroidBootTests"
        "AndroidLandscapeTests"
        "AndroidRunTests"
        "AndroidDoctorE2ETests"
    )
    local suite
    plan_suites "${suites[@]}" "${RN_SUITES[@]}"
    for suite in "${suites[@]}"; do
        if ! run_swift_suite "$suite" "" --filter "$suite"; then
            show_results
            die "$suite failed."
        fi
    done

    run_rn_suites
}

run_android_fold_tests() {
    ensure_test_framework_rpaths

    export OFFSIDER_ANDROID_DEVICE="${OFFSIDER_ANDROID_DEVICE:-$ANDROID_FOLD_AVD}"
    export OFFSIDER_ANDROID_E2E_AVD="$ANDROID_FOLD_AVD"
    export OFFSIDER_ANDROID_FOLD_E2E=1
    export OFFSIDER_ANDROID_E2E=0
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    export OFFSIDER_RN_E2E=0
    export OFFSIDER_RN_DEBUG_E2E=0
    unset OFFSIDER_ANDROID_PHONE
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    ensure_avd_running "$ANDROID_FOLD_AVD"
    resolve_android_apk
    export OFFSIDER_ANDROID_APK
    log "Environment: OFFSIDER_ANDROID_DEVICE=$OFFSIDER_ANDROID_DEVICE, OFFSIDER_ANDROID_E2E_AVD=$OFFSIDER_ANDROID_E2E_AVD, OFFSIDER_ANDROID_APK=$OFFSIDER_ANDROID_APK"
    run_suite_list "AndroidFoldableTests"
}

# A physical device runs E2E only while a person has allowed it for more than 30 minutes more (and, on an iPhone, the playground); there is no bypass.
require_device_allowance() {
    local device="$1"
    local app="${2:-}"
    local status
    if ! status="$("$OFFSIDER_BIN_PATH" device-access status --device "$device" --json 2>/dev/null)"; then
        print_error "$device is not on the allow-list. $RUN_YOURSELF, then run the suites again:"
        print_device_allow "$device" "$app"
        exit 1
    fi
    local name
    name="$(printf '%s' "$status" | plutil -extract devices.0.name raw -o - - 2>/dev/null)" || name=""
    local allow_name="${name:-$device}"
    local expires
    if expires="$(printf '%s' "$status" | plutil -extract devices.0.expires raw -o - - 2>/dev/null)"; then
        local expiry_epoch
        expiry_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null || echo 0)"
        if (( expiry_epoch - $(date -u +%s) <= 1800 )); then
            print_error "$allow_name's allowance ends at $expires, within 30 minutes. $RENEW_YOURSELF:"
            print_device_allow "$allow_name" "$app"
            exit 1
        fi
    elif ! printf '%s' "$status" | plutil -extract devices.0 json -o - - 2>/dev/null | grep -q '"expires":null'; then
        print_error "Could not read $allow_name's allowance. $RUN_YOURSELF:"
        print_device_allow "$allow_name" "$app"
        exit 1
    fi
    if [[ -n "$app" ]]; then
        local apps
        apps="$(printf '%s' "$status" | plutil -extract devices.0.apps json -o - - 2>/dev/null || echo '[]')"
        if [[ "$apps" != *"\"$app\""* ]]; then
            print_error "$allow_name's allowance does not include $app. $RUN_YOURSELF:"
            print_device_allow "$allow_name" "$app"
            exit 1
        fi
    fi
    ui_row ok "$allow_name" "allowed${expires:+ until $expires}"
}

# The phone suites alone, on the one USB phone OFFSIDER_ANDROID_PHONE names; the emulator suites stay off.
run_android_phone_tests() {
    ensure_test_framework_rpaths

    export OFFSIDER_ANDROID_E2E=0
    export OFFSIDER_ANDROID_FOLD_E2E=0
    export OFFSIDER_ANDROID_LANDSCAPE_E2E=0
    export OFFSIDER_ANDROID_BOOT_E2E=0
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    export OFFSIDER_RN_E2E=0
    export OFFSIDER_RN_DEBUG_E2E=0
    unset OFFSIDER_ANDROID_DEVICE OFFSIDER_ANDROID_DEBUG_APK
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    if [[ ! -f "$OFFSIDER_BIN_PATH" ]]; then
        die "Offsider executable not found at $OFFSIDER_BIN_PATH. Run without --tests-only, run swift build first, or set OFFSIDER_BIN_PATH to a prebuilt payload."
    fi
    if [[ -z "${OFFSIDER_ANDROID_PHONE:-}" ]]; then
        local picked
        if ! picked="$(allowed_device_for android "$ANDROID_PLAYGROUND_PACKAGE")"; then
            die "$picked Set OFFSIDER_ANDROID_PHONE to the phone's USB serial." "OFFSIDER_ANDROID_PHONE=<serial> $0 --android-phone"
        fi
        OFFSIDER_ANDROID_PHONE="${picked%%$'\t'*}"
        log "Using ${picked#*$'\t'}, the one Android phone on the allow-list"
    fi
    export OFFSIDER_ANDROID_PHONE
    require_device_allowance "$OFFSIDER_ANDROID_PHONE"
    resolve_android_apk
    export OFFSIDER_ANDROID_APK
    log "Environment: OFFSIDER_ANDROID_PHONE=$OFFSIDER_ANDROID_PHONE, OFFSIDER_ANDROID_APK=$OFFSIDER_ANDROID_APK"
    run_suite_list "AndroidPhoneInputTests" "AndroidPhoneScreenshotTests" "AndroidPhoneHelperTests" "AndroidPhoneTimingTests" \
        "AndroidPhoneVerifyTests" "AndroidPhoneFoldableTests"
}

# The device suites alone, on the one wired iPhone or iPad OFFSIDER_IOS_DEVICE names; every other E2E flag stays off.
run_ios_device_tests() {
    ensure_test_framework_rpaths

    export OFFSIDER_IOS_DEVICE_E2E=1
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    export OFFSIDER_RN_E2E=0
    export OFFSIDER_RN_DEBUG_E2E=0
    export OFFSIDER_ANDROID_E2E=0
    export OFFSIDER_ANDROID_FOLD_E2E=0
    export OFFSIDER_FOLDABLE_E2E=0
    unset OFFSIDER_ANDROID_PHONE OFFSIDER_ANDROID_DEVICE SIMULATOR_UDID
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    if [[ ! -f "$OFFSIDER_BIN_PATH" ]]; then
        die "Offsider executable not found at $OFFSIDER_BIN_PATH. Run without --tests-only, run swift build first, or set OFFSIDER_BIN_PATH to a prebuilt payload."
    fi
    if [[ -z "${OFFSIDER_IOS_DEVICE:-}" ]]; then
        local picked
        if ! picked="$(allowed_device_for ios "$BUNDLE_ID")"; then
            die "$picked Set OFFSIDER_IOS_DEVICE to the device's UDID." "OFFSIDER_IOS_DEVICE=<udid> $0 --ios-device"
        fi
        OFFSIDER_IOS_DEVICE="${picked%%$'\t'*}"
        log "Using ${picked#*$'\t'}, the one iPhone or iPad on the allow-list"
    fi
    export OFFSIDER_IOS_DEVICE
    require_device_allowance "$OFFSIDER_IOS_DEVICE" "$BUNDLE_ID"
    if [[ -z "${OFFSIDER_IOS_TEAM_ID:-}" ]]; then
        OFFSIDER_IOS_TEAM_ID="$(allowance_team "$OFFSIDER_IOS_DEVICE")"
        if [[ -z "$OFFSIDER_IOS_TEAM_ID" ]]; then
            print_error "No team signs the runner and the playground. $RUN_YOURSELF and choose a team in its menu, or set OFFSIDER_IOS_TEAM_ID:"
            print_person_command "$(offsider_command) device-access allow"
            exit 1
        fi
        log "Using the team the device's allowance records"
    fi
    export OFFSIDER_IOS_TEAM_ID
    log "Environment: OFFSIDER_IOS_DEVICE=$OFFSIDER_IOS_DEVICE, OFFSIDER_IOS_TEAM_ID=$OFFSIDER_IOS_TEAM_ID"
    run_suite_list "IOSDeviceListE2ETests" "IOSDeviceDoctorE2ETests" "IOSDeviceScreenshotE2ETests" "IOSDeviceSettingsE2ETests" \
        "IOSDeviceInputE2ETests" "IOSDeviceTreeE2ETests" "IOSDeviceRunnerE2ETests"
}

# Picks the Offsider Duo unless SIMULATOR_UDID already names a simulator.
select_foldable_simulator() {
    if [[ -n "$SIMULATOR_UDID" ]]; then
        return
    fi
    SIMULATOR_UDID="$(xcrun simctl list devices available -j | jq -r --arg name "$FOLDABLE_SIMULATOR_NAME" \
        '[.devices[][] | select(.name == $name)] | .[0].udid // empty')"
    if [[ -z "$SIMULATOR_UDID" ]]; then
        if [[ "$FOLDABLE_SIMULATOR_NAME" == "Offsider Duo" ]]; then
            die "There is no Offsider Duo simulator yet." "scripts/e2e-devices.sh create"
        fi
        die "No simulator is named $FOLDABLE_SIMULATOR_NAME." "scripts/e2e-devices.sh create && OFFSIDER_FOLDABLE_SIMULATOR_NAME= $0 --foldable"
    fi
}

run_foldable_tests() {
    ensure_test_framework_rpaths

    export SIMULATOR_UDID
    export OFFSIDER_FOLDABLE_E2E=1
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    export OFFSIDER_RN_E2E=0
    export OFFSIDER_ANDROID_E2E=0
    unset OFFSIDER_ANDROID_PHONE
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    log "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_FOLDABLE_E2E=1, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"
    ui_notice note "The unfolded half asks you to unfold the simulator in Device Hub and skips after 120 s."
    run_suite_list "FoldableTests"
}

# Function to build and install playground app
build_playground_app() {
    # Terminate existing app instance
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Build the app (not build-for-testing since this is a regular app); -quiet keeps the log short.
    local quiet=()
    [[ "$VERBOSE" == true ]] || quiet=(-quiet)
    run_step "Building the playground" xcodebuild build \
        -project "$PLAYGROUND_PROJECT" \
        -scheme "$PLAYGROUND_SCHEME" \
        -destination "id=$SIMULATOR_UDID" \
        ${quiet[@]+"${quiet[@]}"} ||
        die "The playground did not build." "xcodebuild build -project $PLAYGROUND_PROJECT -scheme $PLAYGROUND_SCHEME -destination id=$SIMULATOR_UDID"

    # Find the built app path using TARGET_BUILD_DIR + FULL_PRODUCT_NAME (more semantically correct)
    spinner_start "Finding the playground app"
    BUILD_SETTINGS=$(xcodebuild -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID" -showBuildSettings)
    spinner_stop
    TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep "TARGET_BUILD_DIR" | head -1 | sed 's/.*= //')
    FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | grep "FULL_PRODUCT_NAME" | head -1 | sed 's/.*= //')
    APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        print_error "The built playground is not at $APP_PATH."
        log "    TARGET_BUILD_DIR: $TARGET_BUILD_DIR"
        log "    FULL_PRODUCT_NAME: $FULL_PRODUCT_NAME"
        exit 1
    fi

    run_step "Installing the playground" xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH" ||
        die "The playground did not install on $SIMULATOR_NAME." "xcrun simctl install $SIMULATOR_UDID \"$APP_PATH\""
}

landscape_orientation_menu_available() {
    local enabled_items
    enabled_items=$(osascript \
        -e 'tell application "Simulator" to activate' \
        -e 'delay 0.5' \
        -e 'tell application "System Events" to tell process "Simulator" to get enabled of menu items of menu "Orientation" of menu item "Orientation" of menu "Device" of menu bar 1' \
        2>/dev/null || true)

    [[ "$enabled_items" == true,\ true,\ true,\ true* ]]
}

# Function to run tests
run_tests() {
    ensure_test_framework_rpaths

    # Set up environment
    export SIMULATOR_UDID="$SIMULATOR_UDID"
    export OFFSIDER_E2E=1
    export OFFSIDER_RN_E2E=0
    export OFFSIDER_RN_DEBUG_E2E=0
    unset OFFSIDER_ANDROID_PHONE
    if [[ -z "${OFFSIDER_BIN_PATH:-}" ]]; then
        OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    fi
    export OFFSIDER_BIN_PATH
    if [[ ! -f "$OFFSIDER_BIN_PATH" ]]; then
        die "Offsider executable not found at $OFFSIDER_BIN_PATH. Run without --tests-only, run swift build first, or set OFFSIDER_BIN_PATH to a prebuilt payload."
    fi

    local requested_landscape_e2e="${OFFSIDER_LANDSCAPE_E2E:-0}"
    local normalized_landscape_e2e
    normalized_landscape_e2e=$(printf '%s' "$requested_landscape_e2e" | tr '[:upper:]' '[:lower:]')
    case "$normalized_landscape_e2e" in
        1|true|yes)
            if landscape_orientation_menu_available; then
                export OFFSIDER_LANDSCAPE_E2E=1
            else
                warn "Landscape precision tests skipped: Simulator menu automation is not available. Open Simulator and allow it under Accessibility in System Settings, then run again." "OFFSIDER_LANDSCAPE_E2E=1 $0"
                export OFFSIDER_LANDSCAPE_E2E=0
            fi
            ;;
        *)
            export OFFSIDER_LANDSCAPE_E2E=0
            ;;
    esac

    log "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_E2E=$OFFSIDER_E2E, OFFSIDER_LANDSCAPE_E2E=$OFFSIDER_LANDSCAPE_E2E, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"

    if [[ -n "$TEST_FILTER" ]]; then
        run_swift_suite "$TEST_FILTER" "" --filter "$TEST_FILTER" || die "$TEST_FILTER failed."
        return
    fi

    if [[ "$SEQUENTIAL" == true ]]; then
        # One suite at a time, so they never contend for the simulator.
        local suites=(
            "BatchTests"
            "ButtonTests"
            "CommandNamingTests"
            "DescribeUITests"
            "DeviceControlTests"
            "DeviceStateE2ETests"
            "DoctorTests"
            "GestureTests"
            "InitTests"
            "KeyComboTests"
            "KeySequenceTests"
            "KeyTests"
            "ListDevicesTests"
            "LogsTests"
            "ParkedSheetTests"
            "PresentationFixtureTests"
            "PresentedSheetTests"
            "RecordVideoTests"
            "RunE2ETests"
            "StreamVideoDebugTests"
            "StreamVideoTests"
            "SwipeTests"
            "DragTests"
            "SliderTests"
            "TapTests"
            "TouchTests"
            "TypeTests"
            "VerifyTests"
        )

        local suite
        plan_suites "${suites[@]}"
        for suite in "${suites[@]}"; do
            if ! run_swift_suite "$suite" "" --filter "$suite"; then
                show_results
                die "$suite failed." "$0 -t $suite"
            fi
        done
        return
    fi

    run_swift_suite "All tests" "" || die "Some tests failed."
}

# The results, then a receipt with the whole run's time; a build alone says where it put Offsider and the playground.
show_summary() {
    local took passed=0 state headline built=""
    took="in $(ui_elapsed "$SECONDS")"
    if [[ "$TESTS_ONLY" != true ]]; then
        built="Offsider at $(ui_path "$(run_selected_swift build --show-bin-path)/offsider")"
    fi
    if [[ "$BUILD_ONLY" == true ]]; then
        ui_receipt "Built and installed" "$took" "$built" "Playground on $SIMULATOR_NAME"
        return 0
    fi
    show_results
    for state in ${RESULT_STATES[@]+"${RESULT_STATES[@]}"}; do
        if [[ "$state" == ok ]]; then passed=$(( passed + 1 )); fi
    done
    headline="All $passed suites passed"
    (( ${#RESULT_NAMES[@]} == 1 )) && headline="${RESULT_NAMES[0]} passed"
    if [[ -n "$built" ]]; then ui_receipt "$headline" "$took" "$built"; else ui_receipt "$headline" "$took"; fi
    return 0
}

# What the header says this run is: the mode, the device when it is known yet, and a suite filter.
run_summary() {
    local mode="Simulator" device="${SIMULATOR_UDID:-${OFFSIDER_SIMULATOR_NAME:-}}" summary
    if [[ "$UNIT_TESTS" == true ]]; then mode="Unit tests" device=""
    elif [[ "$ANDROID_PHONE" == true ]]; then mode="Android phone" device="${OFFSIDER_ANDROID_PHONE:-}"
    elif [[ "$IOS_DEVICE" == true ]]; then mode="iPhone or iPad" device="${OFFSIDER_IOS_DEVICE:-}"
    elif [[ "$ANDROID_FOLD" == true ]]; then mode="Android foldable" device="${OFFSIDER_ANDROID_DEVICE:-$ANDROID_FOLD_AVD}"
    elif [[ "$FOLDABLE" == true ]]; then mode="Foldable" device="${SIMULATOR_UDID:-$FOLDABLE_SIMULATOR_NAME}"
    elif [[ "$ANDROID" == true ]]; then mode="Android emulator" device="${OFFSIDER_ANDROID_DEVICE:-$ANDROID_E2E_AVD}"
    elif [[ "$RN_IOS" == true ]]; then mode="React Native iOS"
    fi
    [[ "$RN_DEBUG" == true ]] && mode="$mode debug"
    summary="$mode"
    [[ -n "$device" ]] && summary="$summary $UI_DOT $device"
    [[ -n "$TEST_FILTER" ]] && summary="$summary $UI_DOT $TEST_FILTER"
    [[ "$BUILD_ONLY" == true ]] && summary="$summary $UI_DOT build only"
    [[ "$TESTS_ONLY" == true ]] && summary="$summary $UI_DOT tests only"
    printf '%s' "$summary"
}

# Main execution
main() {
    ui_header "🧪" "Offsider tests" "$(run_summary)"

    # Always check prerequisites
    check_prerequisites

    if [[ "$ANDROID_PHONE" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_android_phone_tests
        show_summary
        return
    fi

    if [[ "$IOS_DEVICE" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            generate_playground_project
            build_offsider
        fi
        run_ios_device_tests
        show_summary
        return
    fi

    if [[ "$ANDROID_FOLD" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_android_fold_tests
        show_summary
        return
    fi

    if [[ "$FOLDABLE" == true ]]; then
        ensure_e2e_runtime_host || {
            die "Could not start the Xcode 27 Device Hub runtime host." "open \"$SELECTED_DEVELOPER_DIR/../Applications/DeviceHub.app\", then run $0 again"
        }
        select_foldable_simulator
        boot_simulator
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            generate_playground_project
            build_offsider
            ensure_test_framework_rpaths
            build_playground_app
        fi
        run_foldable_tests
        show_summary
        return
    fi

    if [[ "$ANDROID" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_android_tests
        show_summary
        return
    fi

    if [[ "$RN_IOS" == true ]]; then
        ensure_e2e_runtime_host || {
            die "Could not start the Xcode 27 Device Hub runtime host." "open \"$SELECTED_DEVELOPER_DIR/../Applications/DeviceHub.app\", then run $0 again"
        }
        boot_simulator
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_rn_ios_tests
        show_summary
        return
    fi

    if [[ "$UNIT_TESTS" == true ]]; then
        build_idb_xcframeworks
        build_offsider
        run_unit_tests
        show_summary
        return
    fi

    ensure_e2e_runtime_host || {
        die "Could not start the Xcode 27 Device Hub runtime host." "open \"$SELECTED_DEVELOPER_DIR/../Applications/DeviceHub.app\", then run $0 again"
    }

    # Always boot simulator (needed for both building and testing)
    boot_simulator

    if [[ "$TESTS_ONLY" != true ]]; then
        build_idb_xcframeworks
        generate_playground_project
        clean_build
        build_offsider
        ensure_test_framework_rpaths
        build_playground_app
    fi

    if [[ "$BUILD_ONLY" != true ]]; then
        run_tests
    fi

    show_summary
}

# Run main function
main "$@"
