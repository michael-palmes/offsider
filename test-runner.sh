#!/bin/bash

# Offsider Test Runner Script
# Automates building Offsider executable, playground app, and running tests

set -e  # Exit on any error

source "$(dirname "${BASH_SOURCE[0]}")/scripts/e2e-environment.sh"

# Any adb server the suites start sends no mDNS multicast on the LAN.
export ADB_MDNS=0
# An accidental overlap with another runner on the same device waits rather than failing with exit 8.
export OFFSIDER_WAIT_LOCK="${OFFSIDER_WAIT_LOCK:-30}"
# Suites name their devices; a shell's default device must not pick one.
unset OFFSIDER_DEVICE
# Captures from the suites never land in a developer's evidence run; suites that test runs set their own folder.
export OFFSIDER_RUN=off

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SIMULATOR_UDID="${SIMULATOR_UDID:-}"
PLAYGROUND_PROJECT="OffsiderPlaygroundApp/OffsiderPlayground.xcodeproj"
PLAYGROUND_SCHEME="OffsiderPlayground"
BUNDLE_ID="com.mpalmes.offsider.playground"

# Print colored messages
print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_header() {
    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${BLUE}🎯 $1${NC}"
    echo -e "${BLUE}================================================${NC}\n"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [TEST_FILTER]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  -b, --build-only    Only build Offsider and playground app (skip tests)"
    echo "  -t, --tests-only    Only run tests (skip building)"
    echo "  -u, --unit-tests    Build dependencies and run non-E2E Swift tests without a simulator"
    echo "  -a, --android       Build Offsider and run the Android emulator E2E suites, then the React Native suites (no simulator)"
    echo "      --rn-ios        Build Offsider and run the React Native playground suites on an iOS simulator"
    echo "      --rn-debug      With --rn-ios or --android: build the Debug app, start Metro on 8742 and run only ReactNativeDebugSmokeTests"
    echo "      --foldable      Build Offsider and the playground, then run FoldableTests on the Offsider Duo iPhone"
    echo "      --android-fold  Build Offsider and run AndroidFoldableTests on the Offsider_E2E_Pixel_9_Pro_Fold AVD"
    echo "      --android-phone Build Offsider and run the AndroidPhone*Tests suites on the USB phone OFFSIDER_ANDROID_PHONE names"
    echo "      --ios-device    Build Offsider and run the IOSDevice*E2ETests suites on the wired iPhone or iPad OFFSIDER_IOS_DEVICE names"
    echo "  -c, --clean         Clean build before building"
    echo "  -s, --sequential    Run suites one-by-one (single simulator-safe flow)"
    echo "  -v, --verbose       Verbose output"
    echo ""
    echo "Environment:"
    echo "  DEVELOPER_DIR             Xcode used to build and run tests (Xcode 27 uses Device Hub)"
    echo "  OFFSIDER_BIN_PATH         Prebuilt Offsider executable to test with --tests-only"
    echo "  OFFSIDER_LANDSCAPE_E2E=1  Run gated landscape orientation precision tests when Simulator menu automation is available"
    echo "  OFFSIDER_REUSE_IDB=1      Skip the IDB framework rebuild when existing XCFrameworks pass verification"
    echo "  OFFSIDER_SIMULATOR_NAME   Exact name of the simulator to test on (default: a stock iPhone on the Xcode's iOS major, booted first)"
    echo "  SIMULATOR_UDID            UDID of the simulator to test on (overrides OFFSIDER_SIMULATOR_NAME)"
    echo ""
    echo "Android (--android):"
    echo "  OFFSIDER_ANDROID_DEVICE   Required: the E2E emulator's serial or AVD name, for example Offsider_E2E_Pixel_9"
    echo "  OFFSIDER_ANDROID_APK      The React Native playground's release APK (default: OffsiderPlaygroundRN/build/android/OffsiderPlaygroundRN-release.apk)"
    echo "  OFFSIDER_ANDROID_E2E_AVD  The only AVD the suites may drive: Offsider_E2E_Pixel_9 (default) or Offsider_E2E_Pixel_9_Pro_Fold"
    echo "  OFFSIDER_ANDROID_LANDSCAPE_E2E=1  Also run the landscape suite on Settings"
    echo "  OFFSIDER_ANDROID_BOOT_E2E=1       Also stop and cold-boot the E2E AVD"
    echo "  OFFSIDER_ANDROID_DEBUG_APK        The Debug APK for --rn-debug (default: built by scripts/rn-playground.sh build-android --debug)"
    echo ""
    echo "Foldables (--foldable, --android-fold):"
    echo "  SIMULATOR_UDID            The iPhone Duo simulator for --foldable (default: the one named Offsider Duo iPhone, booted first)"
    echo "  OFFSIDER_ANDROID_DEVICE   For --android-fold: the fold emulator's serial or AVD name (default: Offsider_E2E_Pixel_9_Pro_Fold)"
    echo ""
    echo "Android phone (--android-phone):"
    echo "  OFFSIDER_ANDROID_PHONE    Required: the phone's exact USB serial from adb devices -l; no other device is touched"
    echo "  OFFSIDER_ANDROID_APK      The React Native playground's release APK, installed once and left in place"
    echo ""
    echo "iPhone or iPad (--ios-device, needs XcodeGen):"
    echo "  OFFSIDER_IOS_DEVICE       Required: the device's exact UDID from devicectl list devices; no other device is touched"
    echo "  OFFSIDER_IOS_TEAM_ID      Required: the team that signs the runner and the playground, installed once and left in place"
    echo ""
    echo "React Native on iOS (--rn-ios, needs pnpm):"
    echo "  OFFSIDER_RN_IOS_APP       The Release simulator app (default: built by scripts/rn-playground.sh build-ios --if-changed)"
    echo "  OFFSIDER_RN_IOS_DEBUG_APP The Debug simulator app for --rn-debug (default: built by build-ios --debug --if-changed)"
    echo ""
    echo "Test Filters (optional):"
    echo "  SwipeTests          Run only swipe tests"
    echo "  DragTests           Run only drag tests"
    echo "  SliderTests         Run only slider tests"
    echo "  DescribeUITests     Run only describe-ui tests"
    echo "  DoctorTests         Run only doctor tests"
    echo "  InitTests           Run only init tests"
    echo "  KeyComboTests       Run only key-combo tests"
    echo "  KeySequenceTests    Run only key-sequence tests"
    echo "  TapTests            Run only tap tests"
    echo "  KeyTests            Run only key tests"
    echo "  TouchTests          Run only touch tests"
    echo "  TypeTests           Run only type tests"
    echo "  VerifyTests         Run only --verify tests"
    echo "  BatchTests          Run only batch tests"
    echo "  ButtonTests         Run only button tests"
    echo "  CommandNamingTests  Run only command naming tests"
    echo "  GestureTests        Run only gesture tests"
    echo "  ListDevicesTests    Run only list devices tests"
    echo "  PresentationFixtureTests Run only presentation fixture tests"
    echo "  RecordVideoTests    Run only record video tests"
    echo "  StreamVideoDebugTests Run only stream video debug tests"
    echo "  StreamVideoTests    Run only stream video tests"
    echo "  ReactNative*Tests   Run only that React Native suite (with --rn-ios or --android), for example ReactNativeFixtureSmokeTests"
    echo ""
    echo "Examples:"
    echo "  $0                  # Build everything and run all tests"
    echo "  $0 SwipeTests       # Build everything and run only swipe tests"
    echo "  $0 DragTests        # Build everything and run only drag tests"
    echo "  $0 -t SwipeTests    # Skip building, run only swipe tests"
    echo "  $0 -u               # Build and run non-E2E Swift tests without a simulator"
    echo "  $0 --android        # Build and run the Android E2E suites against OFFSIDER_ANDROID_DEVICE"
    echo "  $0 --rn-ios         # Build and run the React Native suites on an iOS simulator"
    echo "  $0 --rn-ios --rn-debug   # Debug build with Metro on 8742, run ReactNativeDebugSmokeTests"
    echo "  $0 --android ReactNativeRowsTests   # Run one React Native suite on the Android emulator"
    echo "  $0 --foldable       # Run the foldable suite on the Offsider Duo iPhone (unfold it in Device Hub when asked)"
    echo "  $0 --android-fold   # Run the foldable suite on the Pixel 9 Pro Fold AVD"
    echo "  OFFSIDER_ANDROID_PHONE=<serial> $0 --android-phone   # Run the phone suites on one USB phone"
    echo "  OFFSIDER_IOS_DEVICE=<udid> OFFSIDER_IOS_TEAM_ID=<team> $0 --ios-device   # Run the device suites on one wired iPhone or iPad"
    echo "  $0 -b               # Only build, skip tests"
    echo "  $0 -c               # Clean build and run all tests"
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
FOLDABLE_SIMULATOR_NAME="Offsider Duo iPhone"
ANDROID_FOLD_AVD="Offsider_E2E_Pixel_9_Pro_Fold"
CLEAN_BUILD=false
SEQUENTIAL=true
VERBOSE=false
TEST_FILTER=""
SWIFT_BUILD_LOG=""

# React Native suites run by --rn-ios and after the Android suites; a suite not added yet matches nothing and passes.
RN_SUITES=(
    "ReactNativeFixtureSmokeTests"
    "ReactNativeOffscreenTests"
    "ReactNativeOverlayTests"
    "ReactNativeRowsTests"
    "ReactNativeEnvironmentTests"
    "ReactNativeChoiceTests"
    "ReactNativeGestureTests"
)
RN_DEBUG_SUITES=(
    "ReactNativeDebugSmokeTests"
)

cleanup_test_runner() {
    if [[ -n "$SWIFT_BUILD_LOG" && -f "$SWIFT_BUILD_LOG" ]]; then
        rm "$SWIFT_BUILD_LOG"
    fi
    if [[ "$RN_METRO_STARTED" == true ]]; then
        scripts/rn-playground.sh metro stop || true
    fi
}

trap cleanup_test_runner EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
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
        BatchTests|ButtonTests|CommandNamingTests|DescribeUITests|DeviceControlTests|DoctorTests|GestureTests|InitTests|KeyComboTests|KeySequenceTests|KeyTests|ListDevicesTests|LogsTests|ParkedSheetTests|PresentationFixtureTests|RecordVideoTests|StreamVideoDebugTests|StreamVideoTests|SwipeTests|DragTests|SliderTests|TapTests|TouchTests|TypeTests|VerifyTests)
            TEST_FILTER="$1"
            shift
            ;;
        ReactNative*Tests)
            TEST_FILTER="$1"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [[ "$UNIT_TESTS" == true ]] &&
   [[ "$BUILD_ONLY" == true || "$TESTS_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
    print_error "--unit-tests cannot be combined with build, E2E test, clean, or test-filter options."
    exit 1
fi

if [[ "$FOLDABLE" == true || "$ANDROID_FOLD" == true ]]; then
    if [[ "$FOLDABLE" == true && "$ANDROID_FOLD" == true ]]; then
        print_error "--foldable and --android-fold cannot be combined; run them one at a time."
        exit 1
    fi
    if [[ "$ANDROID" == true || "$RN_IOS" == true || "$RN_DEBUG" == true || "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
        print_error "--foldable and --android-fold can only be combined with --tests-only and --verbose."
        exit 1
    fi
fi

if [[ "$ANDROID_PHONE" == true ]]; then
    if [[ "$FOLDABLE" == true || "$ANDROID_FOLD" == true || "$ANDROID" == true || "$RN_IOS" == true || "$RN_DEBUG" == true || "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
        print_error "--android-phone can only be combined with --tests-only and --verbose."
        exit 1
    fi
    if [[ -z "${OFFSIDER_ANDROID_PHONE:-}" ]]; then
        print_error "Set OFFSIDER_ANDROID_PHONE to the phone's USB serial from 'adb devices -l'."
        exit 1
    fi
fi

if [[ "$IOS_DEVICE" == true ]]; then
    if [[ "$ANDROID_PHONE" == true || "$FOLDABLE" == true || "$ANDROID_FOLD" == true || "$ANDROID" == true || "$RN_IOS" == true || "$RN_DEBUG" == true || "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true || -n "$TEST_FILTER" ]]; then
        print_error "--ios-device can only be combined with --tests-only and --verbose."
        exit 1
    fi
    if [[ -z "${OFFSIDER_IOS_DEVICE:-}" ]]; then
        print_error "Set OFFSIDER_IOS_DEVICE to the device's UDID from 'xcrun devicectl list devices'."
        exit 1
    fi
    if [[ -z "${OFFSIDER_IOS_TEAM_ID:-}" ]]; then
        print_error "Set OFFSIDER_IOS_TEAM_ID to the team that signs the runner and the playground."
        exit 1
    fi
fi

RN_FILTER=false
[[ "$TEST_FILTER" == ReactNative*Tests ]] && RN_FILTER=true

if [[ "$ANDROID" == true && "$RN_IOS" == true ]]; then
    print_error "--android and --rn-ios cannot be combined; run them one at a time."
    exit 1
fi

if [[ "$ANDROID" == true || "$RN_IOS" == true ]] &&
   [[ "$UNIT_TESTS" == true || "$BUILD_ONLY" == true || "$CLEAN_BUILD" == true ]]; then
    print_error "--android and --rn-ios can only be combined with --rn-debug, --tests-only, --verbose and a ReactNative*Tests filter."
    exit 1
fi

if [[ "$RN_FILTER" == true && "$ANDROID" != true && "$RN_IOS" != true ]]; then
    print_error "$TEST_FILTER needs --rn-ios or --android."
    exit 1
fi

if [[ -n "$TEST_FILTER" && "$RN_FILTER" != true ]] && [[ "$ANDROID" == true || "$RN_IOS" == true ]]; then
    print_error "$TEST_FILTER is a native iOS suite; --android and --rn-ios only take a ReactNative*Tests filter."
    exit 1
fi

if [[ "$RN_DEBUG" == true ]]; then
    if [[ "$ANDROID" != true && "$RN_IOS" != true ]]; then
        print_error "--rn-debug needs --rn-ios or --android."
        exit 1
    fi
    if [[ -n "$TEST_FILTER" ]]; then
        print_error "--rn-debug runs only ReactNativeDebugSmokeTests and takes no test filter."
        exit 1
    fi
fi

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check if we're in the right directory
    if [[ ! -f "Package.swift" ]]; then
        print_error "Package.swift not found. Please run this script from the Offsider project root."
        exit 1
    fi

    # Check if Xcode is available
    if ! command -v xcodebuild &> /dev/null; then
        print_error "xcodebuild not found. Please install Xcode."
        exit 1
    fi

    # Check if Swift is available
    if ! command -v swift &> /dev/null; then
        print_error "swift not found. Please install Swift."
        exit 1
    fi

    if [[ "$UNIT_TESTS" != true && "$ANDROID" != true && "$ANDROID_FOLD" != true && "$ANDROID_PHONE" != true && "$IOS_DEVICE" != true ]] && ! command -v jq &> /dev/null; then
        print_error "jq not found. Install jq to select the matching simulator runtime."
        exit 1
    fi

    if [[ "$RN_IOS" == true || "$RN_DEBUG" == true ]] && ! command -v pnpm &> /dev/null; then
        print_error "pnpm not found. Install pnpm 11 (brew install pnpm) to build the React Native playground."
        exit 1
    fi

    if [[ "$UNIT_TESTS" != true && "$ANDROID" != true && "$ANDROID_FOLD" != true && "$ANDROID_PHONE" != true && "$RN_IOS" != true ]] && ! command -v xcodegen &> /dev/null; then
        print_error "xcodegen not found. Install it with 'brew install xcodegen' to generate the playground project."
        exit 1
    fi

    if ! configure_e2e_environment; then
        print_error "Xcode 26 or later is required to build and test Offsider. Set DEVELOPER_DIR to its Contents/Developer directory."
        exit 1
    fi

    print_info "Selected toolchain: Xcode $SELECTED_XCODE_VERSION ($(e2e_xcode_build "$SELECTED_DEVELOPER_DIR"))"

    print_success "All prerequisites satisfied"
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
        print_error "Simulator $udid is in a crash loop:"
        echo "$looping"
        print_info "Erase it (this removes its apps and settings), then run again: xcrun simctl shutdown $udid && xcrun simctl erase $udid"
        exit 1
    fi
}

# Function to boot simulator
boot_simulator() {
    print_header "Setting Up Simulator"

    if ! select_e2e_simulator; then
        print_error "Could not select an iOS simulator for E2E tests."
        exit 1
    fi
    print_info "Selected simulator: $SIMULATOR_NAME ($SIMULATOR_UDID)"

    print_info "Checking simulator status..."
    SIMULATOR_STATUS=$(xcrun simctl list devices | grep "$SIMULATOR_UDID" | grep -o "Booted\|Shutdown" || echo "NotFound")

    if [[ -z "$SIMULATOR_UDID" || "$SIMULATOR_STATUS" == "NotFound" ]]; then
        print_error "Simulator with UDID $SIMULATOR_UDID not found"
        print_info "Available simulators:"
        xcrun simctl list devices | grep "iPhone"
        exit 1
    fi

    check_simulator_crash_loop "$SIMULATOR_UDID"

    if [[ "$SIMULATOR_STATUS" != "Booted" ]]; then
        print_info "Booting simulator $SIMULATOR_NAME..."
        xcrun simctl bootstatus "$SIMULATOR_UDID" -b
        print_success "Simulator booted"
    else
        print_success "Simulator already booted"
    fi
}

generate_playground_project() {
    xcodegen generate --spec OffsiderPlaygroundApp/project.yml --quiet
}

# Function to clean build
clean_build() {
    if [[ "$CLEAN_BUILD" == true ]]; then
        print_header "Cleaning Build"

        print_info "Cleaning Swift build..."
        run_selected_swift package clean

        print_info "Cleaning Xcode build..."
        xcodebuild clean -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID"

        print_success "Build cleaned"
    fi
}

build_idb_xcframeworks() {
    print_header "Building IDB Frameworks"

    if [[ "${OFFSIDER_REUSE_IDB:-0}" == "1" ]]; then
        scripts/build.sh setup
        if scripts/build.sh verify-xcframeworks; then
            print_success "Reusing verified IDB XCFrameworks"
            return
        fi
        print_warning "Existing IDB XCFrameworks failed verification; rebuilding"
    fi

    if ! command -v xcodegen &> /dev/null; then
        print_error "XcodeGen is required to build IDB frameworks. Install it with 'brew install xcodegen'."
        exit 1
    fi

    local command
    for command in setup clean frameworks install strip xcframeworks; do
        scripts/build.sh "$command"
    done

    run_selected_swift package clean
    print_success "IDB frameworks built with Xcode $SELECTED_XCODE_VERSION"
}

# Function to build Offsider executable
build_offsider() {
    print_header "Building Offsider Executable"

    print_info "Building Offsider CLI tool..."
    if [[ "$VERBOSE" == true ]]; then
        run_selected_swift build --build-tests
    else
        SWIFT_BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/offsider-e2e-swift-build.XXXXXX")"
        if ! run_selected_swift build --build-tests > "$SWIFT_BUILD_LOG" 2>&1; then
            print_error "Failed to build Offsider with Xcode $SELECTED_XCODE_VERSION. Build output:"
            tail -80 "$SWIFT_BUILD_LOG"
            exit 1
        fi
        rm "$SWIFT_BUILD_LOG"
        SWIFT_BUILD_LOG=""
    fi

    local offsider_bin_path
    offsider_bin_path="$(run_selected_swift build --show-bin-path)/offsider"

    # Verify the executable exists
    if [[ -f "$offsider_bin_path" ]]; then
        print_success "Offsider executable built successfully"
        print_info "Location: $offsider_bin_path"
    else
        print_error "Failed to build Offsider executable"
        exit 1
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
    print_header "Running Non-E2E Swift Tests"

    ensure_test_framework_rpaths
    OFFSIDER_BIN_PATH="$(run_selected_swift build --show-bin-path)/offsider"
    export OFFSIDER_BIN_PATH
    export OFFSIDER_E2E=0
    export OFFSIDER_LANDSCAPE_E2E=0
    # Unit tests spawn offsider against held locks and expect it to fail at once.
    unset OFFSIDER_WAIT_LOCK OFFSIDER_ANDROID_PHONE

    local args=(--skip-build --no-parallel)
    [[ "$VERBOSE" == true ]] && args+=(--verbose)
    print_info "Test command: swift test ${args[*]}"
    run_selected_swift test "${args[@]}"
    print_success "Non-E2E Swift tests passed"
}

# Sets the named variable to its existing value, else to the React Native playground artefact, rebuilt when its sources changed.
# Usage: resolve_rn_artefact <variable> <ios|android> [--debug] [udid]
resolve_rn_artefact() {
    local variable="$1" platform="$2"
    shift 2
    local current="${!variable:-}"
    if [[ -n "$current" ]]; then
        [[ -e "$current" ]] || { print_error "$variable is $current, which does not exist."; exit 1; }
        return
    fi
    if [[ ! -x scripts/rn-playground.sh ]]; then
        print_error "Set $variable to the React Native playground's $platform build."
        exit 1
    fi
    print_info "Building the React Native playground for $platform if its sources changed..."
    scripts/rn-playground.sh "build-$platform" --if-changed "$@"
    local flags=()
    [[ " $* " == *" --debug "* ]] && flags+=(--debug)
    current="$(scripts/rn-playground.sh "path-$platform" "${flags[@]}")"
    if [[ ! -e "$current" ]]; then
        print_error "$current is missing after the build. Set $variable to the React Native playground's $platform build."
        exit 1
    fi
    printf -v "$variable" '%s' "$current"
}

resolve_android_apk() {
    resolve_rn_artefact OFFSIDER_ANDROID_APK android
}

# Starts Metro on 8742 for the Debug builds unless one is already running; the EXIT trap stops a Metro this run started.
start_rn_metro() {
    print_header "Starting Metro"
    if scripts/rn-playground.sh metro status; then
        print_info "Reusing the running Metro; it stays up after this run"
        return
    fi
    RN_METRO_STARTED=true
    scripts/rn-playground.sh metro start
}

# Runs each suite with its own swift test; a suite that does not exist yet matches nothing, which swift test passes.
run_suite_list() {
    local suite output_log status
    for suite in "$@"; do
        print_header "Running $suite"
        local args=(--skip-build --no-parallel --filter "$suite")
        [[ "$VERBOSE" == true ]] && args+=(--verbose)
        print_info "Test command: swift test ${args[*]}"
        output_log="$(mktemp "${TMPDIR:-/tmp}/offsider-e2e-suite.XXXXXX")"
        set +e
        run_selected_swift test "${args[@]}" 2>&1 | tee "$output_log"
        status=${PIPESTATUS[0]}
        set -e
        if [[ "$status" -ne 0 ]]; then
            rm -f "$output_log"
            print_error "$suite failed"
            exit 1
        fi
        if grep -q "No matching test cases were run" "$output_log" && ! grep -q "Test run with [1-9]" "$output_log"; then
            print_warning "$suite matched no tests (not added yet?)"
        fi
        rm -f "$output_log"
    done
}

# The React Native suites, or the one named by a ReactNative*Tests filter.
run_rn_suites() {
    if [[ -n "$TEST_FILTER" ]]; then
        run_suite_list "$TEST_FILTER"
    else
        run_suite_list "${RN_SUITES[@]}"
    fi
    print_success "React Native suites passed"
}

run_rn_ios_tests() {
    print_header "Running React Native E2E Tests (iOS)"
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
        print_error "Offsider executable not found at $OFFSIDER_BIN_PATH. Run without --tests-only, run swift build first, or set OFFSIDER_BIN_PATH to a prebuilt payload."
        exit 1
    fi

    export OFFSIDER_RN_E2E=1
    if [[ "$RN_DEBUG" == true ]]; then
        resolve_rn_artefact OFFSIDER_RN_IOS_DEBUG_APP ios --debug "$SIMULATOR_UDID"
        export OFFSIDER_RN_IOS_DEBUG_APP
        export OFFSIDER_RN_DEBUG_E2E=1
        start_rn_metro
        print_info "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_RN_DEBUG_E2E=1, OFFSIDER_RN_IOS_DEBUG_APP=$OFFSIDER_RN_IOS_DEBUG_APP, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"
        run_suite_list "${RN_DEBUG_SUITES[@]}"
        print_success "React Native debug suites passed"
        return
    fi

    resolve_rn_artefact OFFSIDER_RN_IOS_APP ios "$SIMULATOR_UDID"
    export OFFSIDER_RN_IOS_APP
    export OFFSIDER_RN_DEBUG_E2E=0
    print_info "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_RN_E2E=1, OFFSIDER_RN_IOS_APP=$OFFSIDER_RN_IOS_APP, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"
    run_rn_suites
}

run_android_tests() {
    print_header "Running Android E2E Tests"

    if [[ -z "${OFFSIDER_ANDROID_DEVICE:-}" ]]; then
        print_error "Set OFFSIDER_ANDROID_DEVICE to the E2E emulator's serial or AVD name, for example Offsider_E2E_Pixel_9."
        exit 1
    fi
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

    if [[ "$RN_DEBUG" == true ]]; then
        resolve_rn_artefact OFFSIDER_ANDROID_DEBUG_APK android --debug
        export OFFSIDER_ANDROID_DEBUG_APK
        export OFFSIDER_RN_DEBUG_E2E=1
        start_rn_metro
        print_info "Environment: OFFSIDER_ANDROID_DEVICE=$OFFSIDER_ANDROID_DEVICE, OFFSIDER_ANDROID_E2E_AVD=${OFFSIDER_ANDROID_E2E_AVD:-Offsider_E2E_Pixel_9}, OFFSIDER_RN_DEBUG_E2E=1, OFFSIDER_ANDROID_DEBUG_APK=$OFFSIDER_ANDROID_DEBUG_APK"
        run_suite_list "${RN_DEBUG_SUITES[@]}"
        print_success "React Native debug suites passed"
        return
    fi

    resolve_android_apk
    export OFFSIDER_ANDROID_APK
    export OFFSIDER_RN_DEBUG_E2E=0
    print_info "Environment: OFFSIDER_ANDROID_DEVICE=$OFFSIDER_ANDROID_DEVICE, OFFSIDER_ANDROID_E2E_AVD=${OFFSIDER_ANDROID_E2E_AVD:-Offsider_E2E_Pixel_9}, OFFSIDER_ANDROID_APK=$OFFSIDER_ANDROID_APK"

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
    )
    local suite
    for suite in "${suites[@]}"; do
        print_header "Running $suite"
        local args=(--skip-build --no-parallel --filter "$suite")
        [[ "$VERBOSE" == true ]] && args+=(--verbose)
        if ! run_selected_swift test "${args[@]}"; then
            print_error "$suite failed"
            exit 1
        fi
    done
    print_success "All Android suites passed"

    run_rn_suites
}

run_android_fold_tests() {
    print_header "Running Android Foldable E2E Tests"
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
    resolve_android_apk
    export OFFSIDER_ANDROID_APK
    print_info "Environment: OFFSIDER_ANDROID_DEVICE=$OFFSIDER_ANDROID_DEVICE, OFFSIDER_ANDROID_E2E_AVD=$OFFSIDER_ANDROID_E2E_AVD, OFFSIDER_ANDROID_APK=$OFFSIDER_ANDROID_APK"
    run_suite_list "AndroidFoldableTests"
    print_success "Android foldable suite passed"
}

# The phone suites alone, on the one USB phone OFFSIDER_ANDROID_PHONE names; the emulator suites stay off.
run_android_phone_tests() {
    print_header "Running Android Phone E2E Tests"
    ensure_test_framework_rpaths

    export OFFSIDER_ANDROID_PHONE
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
    resolve_android_apk
    export OFFSIDER_ANDROID_APK
    print_info "Environment: OFFSIDER_ANDROID_PHONE=$OFFSIDER_ANDROID_PHONE, OFFSIDER_ANDROID_APK=$OFFSIDER_ANDROID_APK"
    run_suite_list "AndroidPhoneInputTests" "AndroidPhoneScreenshotTests" "AndroidPhoneHelperTests" "AndroidPhoneTimingTests"
    print_success "Android phone suites passed"
}

# The device suites alone, on the one wired iPhone or iPad OFFSIDER_IOS_DEVICE names; every other E2E flag stays off.
run_ios_device_tests() {
    print_header "Running iOS Device E2E Tests"
    ensure_test_framework_rpaths

    export OFFSIDER_IOS_DEVICE_E2E=1
    export OFFSIDER_IOS_DEVICE
    export OFFSIDER_IOS_TEAM_ID
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
    print_info "Environment: OFFSIDER_IOS_DEVICE=$OFFSIDER_IOS_DEVICE, OFFSIDER_IOS_TEAM_ID=$OFFSIDER_IOS_TEAM_ID"
    run_suite_list "IOSDeviceListE2ETests" "IOSDeviceDoctorE2ETests" "IOSDeviceScreenshotE2ETests" "IOSDeviceSettingsE2ETests" \
        "IOSDeviceInputE2ETests" "IOSDeviceTreeE2ETests" "IOSDeviceRunnerE2ETests"
    print_success "iOS device suites passed"
}

# Picks the Offsider Duo iPhone unless SIMULATOR_UDID already names a simulator.
select_foldable_simulator() {
    if [[ -n "$SIMULATOR_UDID" ]]; then
        return
    fi
    SIMULATOR_UDID="$(xcrun simctl list devices available -j | jq -r --arg name "$FOLDABLE_SIMULATOR_NAME" \
        '[.devices[][] | select(.name == $name)] | .[0].udid // empty')"
    if [[ -z "$SIMULATOR_UDID" ]]; then
        print_error "No simulator is named $FOLDABLE_SIMULATOR_NAME. Create an iPhone Duo simulator with that name, or set SIMULATOR_UDID."
        exit 1
    fi
}

run_foldable_tests() {
    print_header "Running Foldable E2E Tests"
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
    print_info "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_FOLDABLE_E2E=1, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"
    print_info "The unfolded half asks you to unfold the simulator in Device Hub and skips after 120 s"
    run_suite_list "FoldableTests"
    print_success "Foldable suite passed"
}

# Function to build and install playground app
build_playground_app() {
    print_header "Building and Installing Playground App"

    # Terminate existing app instance
    print_info "Terminating existing app instance..."
    xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Build the app (not build-for-testing since this is a regular app)
    print_info "Building OffsiderPlayground app..."
    if [[ "$VERBOSE" == true ]]; then
        xcodebuild build \
            -project "$PLAYGROUND_PROJECT" \
            -scheme "$PLAYGROUND_SCHEME" \
            -destination "id=$SIMULATOR_UDID"
    else
        xcodebuild build \
            -project "$PLAYGROUND_PROJECT" \
            -scheme "$PLAYGROUND_SCHEME" \
            -destination "id=$SIMULATOR_UDID" \
            -quiet > /dev/null 2>&1
    fi

    # Find the built app path using TARGET_BUILD_DIR + FULL_PRODUCT_NAME (more semantically correct)
    print_info "Getting app bundle path..."
    BUILD_SETTINGS=$(xcodebuild -project "$PLAYGROUND_PROJECT" -scheme "$PLAYGROUND_SCHEME" -destination "id=$SIMULATOR_UDID" -showBuildSettings)
    TARGET_BUILD_DIR=$(echo "$BUILD_SETTINGS" | grep "TARGET_BUILD_DIR" | head -1 | sed 's/.*= //')
    FULL_PRODUCT_NAME=$(echo "$BUILD_SETTINGS" | grep "FULL_PRODUCT_NAME" | head -1 | sed 's/.*= //')
    APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        print_error "Built app not found at: $APP_PATH"
        print_info "TARGET_BUILD_DIR: $TARGET_BUILD_DIR"
        print_info "FULL_PRODUCT_NAME: $FULL_PRODUCT_NAME"
        exit 1
    fi

    # Install the app
    print_info "Installing OffsiderPlayground app on simulator..."
    if [[ "$VERBOSE" == true ]]; then
        xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
    else
        xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH" > /dev/null 2>&1
    fi

    print_success "Playground app built and installed successfully"
    print_info "App path: $APP_PATH"
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
    print_header "Running Tests"

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
        print_error "Offsider executable not found at $OFFSIDER_BIN_PATH. Run without --tests-only, run swift build first, or set OFFSIDER_BIN_PATH to a prebuilt payload."
        exit 1
    fi

    local requested_landscape_e2e="${OFFSIDER_LANDSCAPE_E2E:-0}"
    local normalized_landscape_e2e
    normalized_landscape_e2e=$(printf '%s' "$requested_landscape_e2e" | tr '[:upper:]' '[:lower:]')
    case "$normalized_landscape_e2e" in
        1|true|yes)
            if landscape_orientation_menu_available; then
                export OFFSIDER_LANDSCAPE_E2E=1
            else
                print_warning "Skipping landscape orientation precision tests because Simulator menu automation is unavailable. Open Simulator and grant macOS Accessibility permissions, then rerun with OFFSIDER_LANDSCAPE_E2E=1."
                export OFFSIDER_LANDSCAPE_E2E=0
            fi
            ;;
        *)
            export OFFSIDER_LANDSCAPE_E2E=0
            ;;
    esac

    print_info "Environment: SIMULATOR_UDID=$SIMULATOR_UDID, OFFSIDER_E2E=$OFFSIDER_E2E, OFFSIDER_LANDSCAPE_E2E=$OFFSIDER_LANDSCAPE_E2E, OFFSIDER_BIN_PATH=$OFFSIDER_BIN_PATH"

    run_swift_test() {
        local filter="$1"
        local args=(--filter "$filter")
        [[ "$VERBOSE" == true ]] && args+=(--verbose)
        print_info "Test command: swift test --skip-build --no-parallel --filter $filter"
        run_selected_swift test --skip-build --no-parallel "${args[@]}"
    }

    if [[ -n "$TEST_FILTER" ]]; then
        print_info "Running test filter: $TEST_FILTER"
        echo ""
        if run_swift_test "$TEST_FILTER"; then
            print_success "Selected tests passed"
        else
            print_error "Selected tests failed"
            exit 1
        fi
        return
    fi

    if [[ "$SEQUENTIAL" == true ]]; then
        print_info "Running E2E suites one-by-one to avoid simulator contention"
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
            "RecordVideoTests"
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

        echo ""
        for suite in "${suites[@]}"; do
            print_header "Running $suite"
            if ! run_swift_test "$suite"; then
                print_error "$suite failed"
                exit 1
            fi
        done

        print_success "All test suites passed"
        return
    fi

    print_info "Running all tests"
    local args=()
    [[ "$VERBOSE" == true ]] && args+=(--verbose)
    print_info "Test command: swift test --skip-build --no-parallel"
    echo ""
    if run_selected_swift test --skip-build --no-parallel "${args[@]}"; then
        print_success "All tests passed"
    else
        print_error "Some tests failed"
        exit 1
    fi
}

# Function to show summary
show_summary() {
    print_header "Summary"

    if [[ "$BUILD_ONLY" == true ]]; then
        print_success "Build completed successfully"
        print_info "Offsider executable: $(run_selected_swift build --show-bin-path)/offsider"
        print_info "Playground app installed on: $SIMULATOR_NAME ($SIMULATOR_UDID)"
    elif [[ "$TESTS_ONLY" == true ]]; then
        if [[ -n "$TEST_FILTER" ]]; then
            print_success "Test suite '$TEST_FILTER' completed successfully"
        else
            print_success "All test suites completed successfully"
        fi
    else
        print_success "Build and test cycle completed successfully"
        print_info "Offsider executable: $(run_selected_swift build --show-bin-path)/offsider"
        print_info "Playground app: Installed and tested on $SIMULATOR_NAME"
        if [[ -n "$TEST_FILTER" ]]; then
            print_info "Test suite: $TEST_FILTER"
        else
            print_info "Test coverage: All test suites"
        fi
    fi
}

# Main execution
main() {
    print_header "Offsider Test Runner"
    print_info "Starting automated build and test cycle..."

    # Always check prerequisites
    check_prerequisites

    if [[ "$ANDROID_PHONE" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_android_phone_tests
        return
    fi

    if [[ "$IOS_DEVICE" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            generate_playground_project
            build_offsider
        fi
        run_ios_device_tests
        return
    fi

    if [[ "$ANDROID_FOLD" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_android_fold_tests
        return
    fi

    if [[ "$FOLDABLE" == true ]]; then
        ensure_e2e_runtime_host || {
            print_error "Could not start the Xcode 27 Device Hub runtime host."
            exit 1
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
        return
    fi

    if [[ "$ANDROID" == true ]]; then
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_android_tests
        return
    fi

    if [[ "$RN_IOS" == true ]]; then
        ensure_e2e_runtime_host || {
            print_error "Could not start the Xcode 27 Device Hub runtime host."
            exit 1
        }
        boot_simulator
        if [[ "$TESTS_ONLY" != true ]]; then
            build_idb_xcframeworks
            build_offsider
        fi
        run_rn_ios_tests
        return
    fi

    if [[ "$UNIT_TESTS" == true ]]; then
        build_idb_xcframeworks
        build_offsider
        run_unit_tests
        print_header "Summary"
        print_success "Non-E2E Swift build and tests completed successfully"
        print_info "Offsider executable: $(run_selected_swift build --show-bin-path)/offsider"
        return
    fi

    ensure_e2e_runtime_host || {
        print_error "Could not start the Xcode 27 Device Hub runtime host."
        exit 1
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
