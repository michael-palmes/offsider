#!/bin/bash
# Builds the required IDB Frameworks for the Offsider project.

set -e
set -o pipefail

# On a TTY, git eagerly spawns an interactive pager for diff/log commands,
# even with empty output, blocking the build until 'q' is pressed. Force
# plain output for this script and any child scripts.
export GIT_PAGER=cat

# Resolve paths relative to this script so the build works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Environment and Configuration
DEFAULT_IDB_CHECKOUT_DIR="${REPO_ROOT}/idb_checkout"
IDB_CHECKOUT_DIR="${IDB_CHECKOUT_DIR:-${DEFAULT_IDB_CHECKOUT_DIR}}"
IDB_CHECKOUT_DIR="$(cd "$(dirname "$IDB_CHECKOUT_DIR")" && pwd)/$(basename "$IDB_CHECKOUT_DIR")"
IDB_GIT_URL="${IDB_GIT_URL:-https://github.com/michael-palmes/idb.git}"
# Tag offsider-idb-v0.2.0 on branch offsider/xcode27
DEFAULT_IDB_GIT_REF="c50bca23e92903704338d0e09b121b59f087c26b"
IDB_GIT_REF="${IDB_GIT_REF:-${DEFAULT_IDB_GIT_REF}}"
IDB_UPSTREAM_BASE_REF="${IDB_UPSTREAM_BASE_REF:-e682506725e9efefb9c43b8b917c0b12eb2a5939}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-./build_products}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-./build_derived_data}"
BUILD_XCFRAMEWORK_DIR="${BUILD_XCFRAMEWORK_DIR:-${BUILD_OUTPUT_DIR}/XCFrameworks}"
FBSIMCONTROL_PROJECT="${IDB_CHECKOUT_DIR}/FBSimulatorControl.xcodeproj"
IDB_REPLACEMENT_ROOT=""

FRAMEWORK_SDK="macosx"
FRAMEWORK_CONFIGURATION="Release"
ARCHS="arm64"
# A signed debug build's identifier, never a release's, so it cannot satisfy a release's designated requirement.
DEV_SIGNING_IDENTIFIER="com.mpalmes.offsider.dev"

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/ui.sh"

IDB_BUILD_LOG="${REPO_ROOT}/.build/idb-build.log"

function remove_idb_replacement() {
  local replacement_root="$1"
  local checkout_parent
  checkout_parent="$(dirname "$IDB_CHECKOUT_DIR")"

  if [[ -L "$replacement_root" || ! -d "$replacement_root" ||
        "$(dirname "$replacement_root")" != "$checkout_parent" ||
        "$(basename "$replacement_root")" != .offsider-idb-replacement.* ]]; then
    print_warning "Refusing unsafe IDB replacement cleanup: $replacement_root"
    return 0
  fi

  rm -r "$replacement_root"
}

function cleanup_current_idb_replacement() {
  [[ -n "$IDB_REPLACEMENT_ROOT" ]] || return 0
  remove_idb_replacement "$IDB_REPLACEMENT_ROOT"
  IDB_REPLACEMENT_ROOT=""
}

function cleanup_stale_idb_replacements() {
  local checkout_parent candidate owner_pid
  checkout_parent="$(dirname "$IDB_CHECKOUT_DIR")"

  for candidate in "$checkout_parent"/.offsider-idb-replacement.*; do
    [[ ! -L "$candidate" && -d "$candidate" ]] || continue
    [[ ! -L "$candidate/.offsider-owner-pid" && -f "$candidate/.offsider-owner-pid" ]] || continue
    owner_pid="$(< "$candidate/.offsider-owner-pid")"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      continue
    fi
    print_info "Removing stale managed IDB replacement directory: $candidate"
    remove_idb_replacement "$candidate"
  done
}

# shellcheck disable=SC2329 # run by the EXIT trap
function on_exit() {
  cleanup_current_idb_replacement
  ui_cleanup
}

trap on_exit EXIT

function resolve_framework_binary() {
  local framework_path="$1"
  local framework_name="$2"
  local candidates=(
    "$framework_path/Versions/A/$framework_name"
    "$framework_path/Versions/Current/$framework_name"
    "$framework_path/$framework_name"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

function verify_macho_has_arch() {
  local binary_path="$1"
  local expected_arch="$2"

  if [[ ! -f "$binary_path" ]]; then
    print_error "Binary not found for architecture verification: $binary_path"
    exit 1
  fi

  local arch_info
  arch_info=$(lipo -info "$binary_path" 2>/dev/null || true)
  if [[ "$arch_info" != *"$expected_arch"* ]]; then
    print_error "Missing architecture '${expected_arch}' in $binary_path"
    echo "   lipo output: ${arch_info:-<empty>}" >&2
    exit 1
  fi
}

function verify_fbsimulatorcontrol_fork_features() {
  local binary_path="$1"

  if [[ ! -f "$binary_path" ]]; then
    print_error "FBSimulatorControl binary not found for fork feature verification: $binary_path"
    exit 1
  fi

  local required_references=(
    "setClientType:"
    "XCUIDeviceRemoteAutomationSession"
    "enableAutomationModeWithError:"
    "loadAccessibilityWithTimeout:reply:"
    "transportType"
    "dtuhidd did not answer a liveness probe in "
  )
  local reference
  for reference in "${required_references[@]}"; do
    if ! strings -a "$binary_path" | grep -F "$reference" >/dev/null; then
      print_error "FBSimulatorControl is missing required fork feature evidence: ${reference}"
      echo "   Checked binary: $binary_path" >&2
      echo "   Expected fork revision: ${IDB_GIT_URL}@${IDB_GIT_REF}" >&2
      ui_try "$0 dev --rebuild"
      exit 1
    fi
  done

  local framework_contents
  framework_contents=$(dirname "$binary_path")
  local public_module_artifacts=(
    "${framework_contents}/Modules/FBSimulatorControl.swiftmodule/arm64-apple-macos.swiftinterface"
    "${framework_contents}/Headers/FBSimulatorControl-Swift.h"
  )
  local compiled_swift_modules=(
    "${framework_contents}/Modules/FBSimulatorControl.swiftmodule/arm64-apple-macos.swiftmodule"
  )
  local compiled_swift_module
  for compiled_swift_module in "${compiled_swift_modules[@]}"; do
    if [[ ! -f "${compiled_swift_module}" ]]; then
      print_error "FBSimulatorControl compiled Swift module is missing: ${compiled_swift_module}"
      echo "   Textual reconstruction is not viable because the module and public class share a name." >&2
      exit 1
    fi
  done
  local artifact
  for artifact in "${public_module_artifacts[@]}"; do
    if [[ ! -f "$artifact" ]]; then
      print_error "FBSimulatorControl public module artifact is missing: ${artifact}"
      exit 1
    fi
    if grep -E 'AccessibilityPlatformTranslation|AXP[A-Za-z]' "$artifact" >/dev/null; then
      print_error "FBSimulatorControl leaks AccessibilityPlatformTranslation through its public interface"
      echo "   Leaking artifact: ${artifact}" >&2
      ui_try "$0 dev --rebuild"
      exit 1
    fi
  done

  if ! grep -F 'FBAccessibilityElement' "${public_module_artifacts[0]}" >/dev/null ||
    ! grep -F 'accessibilityElementForFrontmostApplication' "${public_module_artifacts[0]}" >/dev/null ||
    ! grep -F 'public func close() async' "${public_module_artifacts[0]}" >/dev/null
  then
    print_error "FBSimulatorControl lost the public Offsider accessibility command surface"
    echo "   Checked: ${public_module_artifacts[0]}" >&2
    exit 1
  fi

  print_success "FBSimulatorControl contains required fork features without leaking private accessibility framework types"
}

# Function to invoke xcodebuild, optionally with xcpretty
function invoke_xcodebuild() {
  local arguments=("$@")
  print_info "Executing: xcodebuild ${arguments[*]}"

  local exit_code
  if [[ -n $HAS_XCPRETTY ]]; then
    NSUnbufferedIO=YES xcodebuild "${arguments[@]}" | xcpretty -c
    exit_code=${PIPESTATUS[0]}
  else
    xcodebuild "${arguments[@]}" 2>&1
    exit_code=$?
  fi

  return "$exit_code"
}

function swift_build_bin_path() {
  local build_config="$1"
  local target_arch="$2"
  swift build --configuration "$build_config" --arch "$target_arch" --force-resolved-versions --show-bin-path
}

function copy_resource_bundle() {
  local output_base_dir="$1"
  local bundle_name="Offsider_Offsider.bundle"
  local bundle_dest="${output_base_dir}/${bundle_name}"
  local bundle_source
  bundle_source="$(swift_build_bin_path "release" "arm64")/${bundle_name}"

  if [[ ! -d "$bundle_source" ]]; then
    print_error "Offsider resource bundle not found in Swift build outputs"
    exit 1
  fi

  rm -rf "$bundle_dest"
  cp -R "$bundle_source" "$bundle_dest"
  print_success "Offsider resource bundle installed to ${bundle_dest}"
}

function fresh_clone_idb_repo() {
  if [[ -e "$IDB_CHECKOUT_DIR" ]]; then
    local existing_remote
    existing_remote="$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ ! -f "$IDB_CHECKOUT_DIR/.git/offsider-managed-checkout" &&
          ( "$IDB_CHECKOUT_DIR" != "$DEFAULT_IDB_CHECKOUT_DIR" || "$existing_remote" != "$IDB_GIT_URL" ) ]]; then
      die "$IDB_CHECKOUT_DIR was not made by this script, so it is left alone." "mv \"$IDB_CHECKOUT_DIR\" \"$IDB_CHECKOUT_DIR.bak\" && $0 dev"
    fi
  fi

  IDB_REPLACEMENT_ROOT="$(mktemp -d "$(dirname "$IDB_CHECKOUT_DIR")/.offsider-idb-replacement.XXXXXX")"
  printf '%s\n' "$$" > "$IDB_REPLACEMENT_ROOT/.offsider-owner-pid"
  local replacement_checkout
  replacement_checkout="${IDB_REPLACEMENT_ROOT}/checkout"
  print_info "Cloning Offsider's IDB fork into $IDB_CHECKOUT_DIR..."
  if ! git clone --no-checkout "$IDB_GIT_URL" "$replacement_checkout" ||
     ! git -C "$replacement_checkout" checkout --detach "$IDB_GIT_REF"; then
    cleanup_current_idb_replacement
    return 1
  fi
  touch "$replacement_checkout/.git/offsider-managed-checkout"
  if [[ -e "$IDB_CHECKOUT_DIR" ]]; then
    rm -r "$IDB_CHECKOUT_DIR"
  fi
  mv "$replacement_checkout" "$IDB_CHECKOUT_DIR"
  cleanup_current_idb_replacement
  print_success "IDB fork cloned at $IDB_GIT_REF."
}

function clone_idb_repo() {
  cleanup_stale_idb_replacements
  if [[ ! -d "$IDB_CHECKOUT_DIR/.git" ]]; then
    fresh_clone_idb_repo
  else
    local actual_ref actual_remote
    actual_ref="$(git -C "$IDB_CHECKOUT_DIR" rev-parse HEAD 2>/dev/null || true)"
    actual_remote="$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ "$actual_ref" == "$IDB_GIT_REF" && "$actual_remote" == "$IDB_GIT_URL" ]] &&
       git -C "$IDB_CHECKOUT_DIR" cat-file -e "${IDB_GIT_REF}^{tree}" 2>/dev/null; then
      if [[ -n "$(git -C "$IDB_CHECKOUT_DIR" status --porcelain)" ]]; then
        if [[ "$IDB_CHECKOUT_DIR" != "$DEFAULT_IDB_CHECKOUT_DIR" &&
              ! -f "$IDB_CHECKOUT_DIR/.git/offsider-managed-checkout" ]]; then
          die "$IDB_CHECKOUT_DIR has local changes and was not made by this script, so it is left alone." "mv \"$IDB_CHECKOUT_DIR\" \"$IDB_CHECKOUT_DIR.bak\" && $0 dev"
        fi
        print_warning "The pinned IDB checkout is dirty; repairing the managed checkout locally."
        if ! git -C "$IDB_CHECKOUT_DIR" restore --source=HEAD --staged --worktree -- . ||
           ! git -C "$IDB_CHECKOUT_DIR" clean -fd; then
          if [[ "$IDB_CHECKOUT_DIR" == "$DEFAULT_IDB_CHECKOUT_DIR" ]]; then
            fresh_clone_idb_repo
          else
            print_error "Unable to repair managed IDB checkout: $IDB_CHECKOUT_DIR"
            return 1
          fi
        fi
      fi
      touch "$IDB_CHECKOUT_DIR/.git/offsider-managed-checkout"
      print_info "Reusing pinned IDB fork checkout at $IDB_GIT_REF."
      verify_idb_source_state
      return 0
    fi

    print_info "Updating Offsider's IDB fork to $IDB_GIT_REF..."
    git -C "$IDB_CHECKOUT_DIR" remote set-url origin "$IDB_GIT_URL"
    if ! (cd "$IDB_CHECKOUT_DIR" && git fetch origin --tags --prune && git checkout -- . && git clean -fd && git checkout --detach "$IDB_GIT_REF"); then
      print_warning "The cached IDB checkout is incomplete; replacing it with a clean clone."
      fresh_clone_idb_repo
    else
      print_success "IDB fork updated to $IDB_GIT_REF."
    fi
  fi
  verify_idb_source_state
}

function verify_idb_source_state() {
  local actual_ref
  actual_ref=$(git -C "$IDB_CHECKOUT_DIR" rev-parse HEAD)
  if [[ "$actual_ref" != "$IDB_GIT_REF" ]]; then
    print_error "IDB checkout SHA mismatch"
    echo "   Expected: $IDB_GIT_REF" >&2
    echo "   Actual:   $actual_ref" >&2
    exit 1
  fi

  local actual_remote
  actual_remote=$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin)
  if [[ "$actual_remote" != "$IDB_GIT_URL" ]]; then
    print_error "IDB checkout remote mismatch"
    echo "   Expected: $IDB_GIT_URL" >&2
    echo "   Actual:   $actual_remote" >&2
    exit 1
  fi
  if ! git -C "$IDB_CHECKOUT_DIR" merge-base --is-ancestor "$IDB_UPSTREAM_BASE_REF" "$actual_ref"; then
    print_error "Pinned IDB fork revision is not based on $IDB_UPSTREAM_BASE_REF"
    exit 1
  fi

  local source_checks=(
    "FBControlCore/Utility/FBXcodeDirectory.swift|environment[\"DEVELOPER_DIR\"]"
    "FBSimulatorControl/Commands/FBAXTranslationDispatcher.swift|clientType = 2"
    "FBSimulatorControl/Commands/FBAXTranslationRequest.swift|@_implementationOnly import AccessibilityPlatformTranslation"
    "FBSimulatorControl/HID/FBSimulatorHID.swift|public let transportType"
    "FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift|func confirmLiveness()"
    "FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift|struct DTUHIDTiming"
    "FBSimulatorControl/HID/FBSimulatorHID.swift|public func close() async"
    "FBSimulatorControl/HID/FBSimulatorHIDEvent.swift|event.event(for: transportType)"
    "FBSimulatorControl/Utility/FBSimulatorControlFrameworkLoader.m|XCUIDeviceRemoteAutomationSession"
  )
  local check source_file source_marker
  for check in "${source_checks[@]}"; do
    source_file="${check%%|*}"
    source_marker="${check#*|}"
    if ! grep -Fq "$source_marker" "${IDB_CHECKOUT_DIR}/${source_file}"; then
      print_error "Pinned IDB fork verification failed"
      echo "   Missing '${source_marker}' in ${source_file}" >&2
      echo "   Fork revision: ${IDB_GIT_URL}@${IDB_GIT_REF}" >&2
      exit 1
    fi
  done

  if ! git -C "$IDB_CHECKOUT_DIR" diff --check; then
    print_error "Pinned IDB fork checkout contains uncommitted whitespace errors"
    exit 1
  fi
  if [[ -n "$(git -C "$IDB_CHECKOUT_DIR" status --porcelain)" ]]; then
    print_error "Pinned IDB fork checkout is not clean"
    exit 1
  fi

  print_success "Verified IDB fork ${IDB_GIT_URL}@${actual_ref} from upstream base ${IDB_UPSTREAM_BASE_REF}"
}

function generate_idb_projects() {
  if ! command -v xcodegen >/dev/null 2>&1; then
    print_error "XcodeGen is required to generate the pinned IDB fork projects."
    ui_try "brew install xcodegen"
    exit 1
  fi

  verify_idb_source_state
  print_info "Generating pinned IDB fork projects with $(xcodegen --version)..."
  (cd "$IDB_CHECKOUT_DIR" && ./build.sh generate)
  if [[ ! -f "${FBSIMCONTROL_PROJECT}/project.pbxproj" ]]; then
    print_error "IDB project generation did not produce ${FBSIMCONTROL_PROJECT}/project.pbxproj"
    exit 1
  fi
  print_success "Generated pinned IDB fork projects before framework compilation"
}

function write_idb_build_evidence() {
  local evidence_path="${BUILD_XCFRAMEWORK_DIR}/IDB_BUILD_EVIDENCE.txt"
  mkdir -p "$BUILD_XCFRAMEWORK_DIR"
  {
    echo "IDB_SHA=${IDB_GIT_REF}"
    echo "IDB_GIT_URL=${IDB_GIT_URL}"
    echo "IDB_UPSTREAM_BASE_SHA=${IDB_UPSTREAM_BASE_REF}"
    echo "DEVELOPER_DIR=${DEVELOPER_DIR:-<not set>}"
    echo "XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ')"
    echo "SWIFT_VERSION=$(swiftc --version 2>&1 | head -1)"
    echo "XCODEGEN_VERSION=$(xcodegen --version)"
    git -C "$IDB_CHECKOUT_DIR" log --reverse \
      --format='IDB_DOWNSTREAM_COMMIT=%H %s' \
      "${IDB_UPSTREAM_BASE_REF}..${IDB_GIT_REF}"
  } > "$evidence_path"
  print_success "Recorded pinned IDB fork build evidence at ${evidence_path}"
}

# Function to build a single framework
# $1: Scheme name
# $2: Project file path
# $3: Base output directory (for .framework and .xcframework)
function framework_build() {
  local scheme_name="$1"
  local project_file="$2"
  local output_base_dir="$3"

  ui_heading "🔨" "Building framework: ${scheme_name}"
  print_info "Project: ${project_file}"

  # shellcheck disable=SC2016 # $(inherited) is for xcodebuild, not the shell
  invoke_xcodebuild \
    -project "${project_file}" \
    -scheme "${scheme_name}" \
    -sdk "${FRAMEWORK_SDK}" \
    -destination "generic/platform=macOS" \
    -configuration "${FRAMEWORK_CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    build \
    SKIP_INSTALL=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS="${ARCHS}" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    GCC_WARN_ABOUT_MISSING_FIELD_INITIALIZERS=NO \
    CLANG_WARN_DOCUMENTATION_COMMENTS=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
    OTHER_LDFLAGS='$(inherited) -Wl,-headerpad_max_install_names'
  local build_exit_code=$?

  if [ $build_exit_code -eq 0 ]; then
    print_success "Framework ${scheme_name} built successfully!"
  else
    print_error "Framework ${scheme_name} build failed with exit code ${build_exit_code}"
    exit $build_exit_code
  fi
}

# Function to install a single framework to Frameworks/
# $1: Scheme name (used to find the .framework in derived data)
# $2: Base output directory
function install_framework() {
  local scheme_name="$1"
  local output_base_dir="$2"
  local built_framework_path="${DERIVED_DATA_PATH}/Build/Products/${FRAMEWORK_CONFIGURATION}/${scheme_name}.framework"
  local final_framework_install_dir="${output_base_dir}/Frameworks"

  print_info "Installing framework ${scheme_name}.framework to ${final_framework_install_dir}..."
  if [[ ! -d "${built_framework_path}" ]]; then
    print_error "Built framework not found at ${built_framework_path} for installation."
    exit 1
  fi

  mkdir -p "${final_framework_install_dir}"
  print_info "Copying ${built_framework_path} to ${final_framework_install_dir}/"
  cp -R "${built_framework_path}" "${final_framework_install_dir}/"
  print_success "Framework ${scheme_name}.framework installed to ${final_framework_install_dir}/"
}

# Function to create a single XCFramework
# $1: Scheme name
# $2: Base output directory (where XCFrameworks/ subdirectory will be created)
function create_xcframework() {
  local scheme_name="$1"
  local output_base_dir="$2"
  local signed_framework_path="${output_base_dir}/Frameworks/${scheme_name}.framework"
  local final_xcframework_output_dir="${output_base_dir}/XCFrameworks"
  local xcframework_path="${final_xcframework_output_dir}/${scheme_name}.xcframework"

  ui_heading "📦" "Creating XCFramework for ${scheme_name}"
  if [[ ! -d "${signed_framework_path}" ]]; then
    print_error "Signed framework not found at ${signed_framework_path} for XCFramework creation."
    exit 1
  fi

  mkdir -p "${final_xcframework_output_dir}"
  rm -rf "${xcframework_path}"

  print_info "Packaging ${signed_framework_path} into ${xcframework_path}"
  invoke_xcodebuild \
    -create-xcframework \
    -framework "${signed_framework_path}" \
    -output "${xcframework_path}"
  local xcframework_exit_code=$?

  if [ $xcframework_exit_code -eq 0 ]; then
    local source_swiftmodule_dir="${signed_framework_path}/Modules/${scheme_name}.swiftmodule"
    if [[ -d "${source_swiftmodule_dir}" ]]; then
      local library_identifier
      library_identifier=$(/usr/libexec/PlistBuddy \
        -c "Print :AvailableLibraries:0:LibraryIdentifier" \
        "${xcframework_path}/Info.plist")
      local packaged_swiftmodule_dir="${xcframework_path}/${library_identifier}/${scheme_name}.framework/Modules/${scheme_name}.swiftmodule"
      mkdir -p "${packaged_swiftmodule_dir}"

      local compiled_swiftmodule
      for compiled_swiftmodule in "${source_swiftmodule_dir}"/*.swiftmodule; do
        [[ -f "${compiled_swiftmodule}" ]] || continue
        cp "${compiled_swiftmodule}" "${packaged_swiftmodule_dir}/"
      done
      print_info "Preserved compiled Swift modules for ${scheme_name}.xcframework"
    fi
    print_success "XCFramework ${scheme_name}.xcframework created at ${xcframework_path}"
  else
    print_error "XCFramework creation for ${scheme_name} failed with exit code ${xcframework_exit_code}"
    exit $xcframework_exit_code
  fi
}

# Function to strip a framework of nested frameworks
# $1: Base output directory
# $2: Framework path
function strip_framework() {
  local output_base_dir="$1"
  local framework_path="${output_base_dir}/Frameworks/${2}"

  if [ -d "$framework_path" ]; then
    print_info "Stripping Framework $framework_path"
    rm -r "$framework_path"
  fi
}

function remove_xcode_rpaths() {
  local target="$1"
  if [[ ! -f "$target" ]]; then
    return
  fi

  local rpaths
  rpaths=$(otool -l "$target" 2>/dev/null | awk 'BEGIN{r=0} /LC_RPATH/{r=1} r==1 && /path/{print $2; r=0}' | grep "/Applications/Xcode" || true)
  if [[ -n "$rpaths" ]]; then
    while IFS= read -r path; do
      install_name_tool -delete_rpath "$path" "$target" || true
    done <<< "$rpaths"
  fi
}

# Function to build the Offsider executable using Swift Package Manager
# $1: Base output directory
function build_offsider_executable() {
  local output_base_dir="$1"
  local build_config="release"
  local executable_dest="${output_base_dir}/offsider"
  local bin_path

  ui_heading "⚡" "Building Offsider executable"
  print_info "Using Swift Package Manager to build Offsider..."

  # Clean any existing build products to ensure fresh build
  print_info "Cleaning previous build products..."
  swift package clean

  print_info "Building arm64 executable..."
  swift build --configuration "${build_config}" --arch arm64 --force-resolved-versions
  bin_path="$(swift_build_bin_path "$build_config" "arm64")/offsider"
  if [[ ! -f "${bin_path}" ]]; then
    print_error "arm64 Offsider executable not found at ${bin_path}"
    exit 1
  fi
  cp "${bin_path}" "${executable_dest}"

  copy_resource_bundle "${output_base_dir}"

  verify_macho_has_arch "${executable_dest}" "arm64"
  print_success "Offsider executable installed to ${executable_dest}"

  # Configure rpath for organised framework loading
  print_info "Configuring executable rpath for organised framework loading..."

  # Remove any existing rpaths first
  install_name_tool -delete_rpath "@executable_path/Frameworks" "${executable_dest}" 2>/dev/null || true
  install_name_tool -delete_rpath "@loader_path/Frameworks" "${executable_dest}" 2>/dev/null || true

  # Add primary rpath: look for frameworks in Frameworks/ subdirectory relative to executable
  install_name_tool -add_rpath "@executable_path/Frameworks" "${executable_dest}"
  print_success "Added rpath: @executable_path/Frameworks"

  # Add fallback rpath: look for frameworks in Frameworks/ relative to current library
  install_name_tool -add_rpath "@loader_path/Frameworks" "${executable_dest}"
  print_success "Added rpath: @loader_path/Frameworks"

  # Strip any Xcode toolchain rpaths that can trigger Homebrew relocation
  remove_xcode_rpaths "${executable_dest}"

  # Verify rpath configuration
  print_info "Verifying rpath configuration..."
  local rpath_output
  rpath_output=$(otool -l "${executable_dest}" | grep -A2 LC_RPATH | grep path | awk '{print $2}')
  if [[ -n "$rpath_output" ]]; then
    print_success "Executable rpath configuration verified:"
    echo "$rpath_output" | while read -r path; do
      print_info "  → ${path}"
    done
  else
    print_warning "No rpath entries found in executable"
  fi

  print_success "Executable rpath configured for organised framework deployment"
}

function verify_xcframework_inputs() {
  local output_base_dir="$1"
  local xcframeworks_dir="${output_base_dir}/XCFrameworks"
  local expected_frameworks=("FBControlCore" "XCTestBootstrap" "FBSimulatorControl" "FBDeviceControl")

  ui_heading "🧪" "Validating XCFramework inputs"

  if [[ ! -d "${xcframeworks_dir}" ]]; then
    print_error "XCFrameworks directory not found under ${output_base_dir}"
    exit 1
  fi

  for framework_name in "${expected_frameworks[@]}"; do
    local xcframework_path="${xcframeworks_dir}/${framework_name}.xcframework"
    if [[ ! -d "${xcframework_path}" ]]; then
      print_error "Expected XCFramework missing from ${xcframeworks_dir}: ${framework_name}.xcframework"
      exit 1
    fi
    local framework_binary
    framework_binary="$(find "${xcframework_path}" -type f -name "${framework_name}" -path "*/macos-*/*.framework/*" | head -1)"
    if [[ -z "${framework_binary}" ]]; then
      print_error "Could not locate framework binary inside ${xcframework_path}"
      exit 1
    fi
    verify_macho_has_arch "${framework_binary}" "arm64"
    if [[ "${framework_name}" == "FBSimulatorControl" ]]; then
      verify_fbsimulatorcontrol_fork_features "${framework_binary}"
    fi
  done

  print_success "XCFramework inputs include the arm64 slice"
}

function verify_release_architectures() {
  local output_base_dir="$1"
  local frameworks_dir="${output_base_dir}/Frameworks"
  local executable_path="${output_base_dir}/offsider"
  local expected_frameworks=("FBControlCore" "XCTestBootstrap" "FBSimulatorControl" "FBDeviceControl")

  ui_heading "🧪" "Validating release artifact architectures"
  verify_macho_has_arch "${executable_path}" "arm64"

  if [[ ! -d "${frameworks_dir}" ]]; then
    print_error "Frameworks directory not found under ${output_base_dir}"
    exit 1
  fi

  for framework_name in "${expected_frameworks[@]}"; do
    local framework_path="${frameworks_dir}/${framework_name}.framework"
    if [[ ! -d "${framework_path}" ]]; then
      print_error "Expected framework missing from ${frameworks_dir}: ${framework_name}.framework"
      exit 1
    fi
    local framework_binary
    framework_binary="$(resolve_framework_binary "${framework_path}" "${framework_name}" || true)"
    if [[ -z "${framework_binary}" ]]; then
      print_error "Could not locate framework binary in ${framework_path}"
      exit 1
    fi
    verify_macho_has_arch "${framework_binary}" "arm64"
    if [[ "${framework_name}" == "FBSimulatorControl" ]]; then
      verify_fbsimulatorcontrol_fork_features "${framework_binary}"
    fi
  done

  print_success "Release artifacts include the arm64 slice"
}

# Android helper: Java 8 source compiled to a committed dex with a pinned JDK, d8 and android.jar.
HELPER_SOURCE_DIR="${REPO_ROOT}/AndroidHelper/src"
HELPER_OUTPUT_DIR="${REPO_ROOT}/Sources/Offsider/Resources/helper"
HELPER_BUILD_DIR="${REPO_ROOT}/.build/offsider-helper"
HELPER_MAIN_SOURCE="com/mpalmes/offsider/helper/OffsiderHelper.java"
HELPER_JDK_MAJOR="17"
HELPER_BUILD_TOOLS="37.0.0"
HELPER_D8_VERSION="9.2.4-dev"
HELPER_D8_SHA256="a26ee56252adcff6752c379ae255a0ad538ebec60189e078ec6855487107637d"
HELPER_PLATFORM="android-37.0"
HELPER_ANDROID_JAR_SHA256="bf1b4387cc7ca94fc6ef684f040d9d16fbf16248e181819f020736ea2053f177"
HELPER_MIN_API="26"

function helper_fail() {
  print_error "$*"
  exit 1
}

function helper_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | awk '{ print $1 }'
  else
    sha256sum "$@" | awk '{ print $1 }'
  fi
}

function helper_source_paths() {
  (cd "$HELPER_SOURCE_DIR" && find . -type f -name '*.java' | sed 's|^\./||' | LC_ALL=C sort)
}

# SHA-256 over each source's path relative to src, a NUL, its bytes and a NUL, in byte order of the paths.
function helper_sources_sha256() {
  helper_source_paths | while IFS= read -r path; do
    printf '%s\0' "$path"
    cat "${HELPER_SOURCE_DIR}/${path}"
    printf '\0'
  done | helper_sha256
}

function helper_resolve_toolchain() {
  local sdk javac_version
  HELPER_JDK="${OFFSIDER_HELPER_JDK:-${JAVA_HOME:-}}"
  if [[ -z "$HELPER_JDK" && -x /usr/libexec/java_home ]]; then
    HELPER_JDK="$(/usr/libexec/java_home -v "$HELPER_JDK_MAJOR" 2>/dev/null || true)"
  fi
  [[ -n "$HELPER_JDK" && -x "${HELPER_JDK}/bin/javac" && -x "${HELPER_JDK}/bin/java" ]] \
    || die "No JDK ${HELPER_JDK_MAJOR} found." "brew install --cask zulu@${HELPER_JDK_MAJOR}"
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
  HELPER_D8_JAR="${sdk}/build-tools/${HELPER_BUILD_TOOLS}/lib/d8.jar"
  HELPER_ANDROID_JAR="${sdk}/platforms/${HELPER_PLATFORM}/android.jar"
  [[ -f "$HELPER_D8_JAR" ]] \
    || helper_fail "Missing ${HELPER_D8_JAR}: install build-tools ${HELPER_BUILD_TOOLS} with sdkmanager, or set ANDROID_HOME."
  [[ -f "$HELPER_ANDROID_JAR" ]] \
    || helper_fail "Missing ${HELPER_ANDROID_JAR}: install ${HELPER_PLATFORM} with sdkmanager, or set ANDROID_HOME."
  javac_version="$("${HELPER_JDK}/bin/javac" -version 2>&1 | awk '{ print $2 }')"
  [[ "${javac_version%%.*}" == "$HELPER_JDK_MAJOR" ]] \
    || helper_fail "javac ${javac_version} in ${HELPER_JDK} is not JDK ${HELPER_JDK_MAJOR}: set OFFSIDER_HELPER_JDK to a JDK ${HELPER_JDK_MAJOR} home."
  [[ "$(helper_sha256 "$HELPER_D8_JAR")" == "$HELPER_D8_SHA256" ]] \
    || helper_fail "${HELPER_D8_JAR} is not d8 ${HELPER_D8_VERSION} from build-tools ${HELPER_BUILD_TOOLS} (sha256 ${HELPER_D8_SHA256})."
  if [[ "$(helper_sha256 "$HELPER_ANDROID_JAR")" != "$HELPER_ANDROID_JAR_SHA256" ]]; then
    print_warning "${HELPER_ANDROID_JAR} is not the pinned ${HELPER_PLATFORM} (sha256 ${HELPER_ANDROID_JAR_SHA256}); the dex comparison still decides."
  fi
  print_info "JDK ${javac_version} in ${HELPER_JDK}, d8 ${HELPER_D8_VERSION}, ${HELPER_PLATFORM}"
}

function helper_manifest() {
  local dex="$1" file_count="$2" main version protocol
  main="${HELPER_SOURCE_DIR}/${HELPER_MAIN_SOURCE}"
  version="$(sed -n 's/^ *static final String VERSION = "\([^"]*\)";$/\1/p' "$main" | head -1)"
  protocol="$(sed -n 's/^ *static final int PROTOCOL = \([0-9][0-9]*\);$/\1/p' "$main" | head -1)"
  [[ -n "$version" && -n "$protocol" ]] || helper_fail "Could not read VERSION and PROTOCOL from ${main}"
  printf '{\n'
  printf '  "helper": "offsider-helper",\n'
  printf '  "helperVersion": "%s",\n' "$version"
  printf '  "protocol": %s,\n' "$protocol"
  printf '  "dex": {"file": "offsider-helper.dex", "bytes": %s, "sha256": "%s"},\n' \
    "$(wc -c < "$dex" | tr -d ' ')" "$(helper_sha256 "$dex")"
  printf '  "sources": {"files": %s, "sha256": "%s"},\n' "$file_count" "$(helper_sources_sha256)"
  printf '  "jdkMajor": %s,\n' "$HELPER_JDK_MAJOR"
  printf '  "d8": {"buildTools": "%s", "version": "%s", "sha256": "%s"},\n' \
    "$HELPER_BUILD_TOOLS" "$HELPER_D8_VERSION" "$HELPER_D8_SHA256"
  printf '  "androidJar": {"platform": "%s", "sha256": "%s"},\n' "$HELPER_PLATFORM" "$HELPER_ANDROID_JAR_SHA256"
  printf '  "minApi": %s\n' "$HELPER_MIN_API"
  printf '}\n'
}

# Builds into .build/offsider-helper/ only: classes, dex, offsider-helper.dex and manifest.json.
function helper_build() {
  local work="$HELPER_BUILD_DIR" path
  local sources=() classes=()
  while IFS= read -r path; do sources+=("$path"); done < <(helper_source_paths)
  [[ ${#sources[@]} -gt 0 ]] || helper_fail "No Java sources under ${HELPER_SOURCE_DIR}"
  rm -rf "$work"
  mkdir -p "${work}/classes" "${work}/dex"
  (cd "$HELPER_SOURCE_DIR" && LC_ALL=C TZ=UTC "${HELPER_JDK}/bin/javac" --release 8 -encoding UTF-8 \
    -Xlint:all,-options -Werror -implicit:none -cp "$HELPER_ANDROID_JAR" -d "${work}/classes" "${sources[@]}")
  while IFS= read -r path; do classes+=("$path"); done \
    < <(cd "${work}/classes" && find . -type f -name '*.class' | sed 's|^\./||' | LC_ALL=C sort)
  (cd "${work}/classes" && LC_ALL=C TZ=UTC "${HELPER_JDK}/bin/java" -cp "$HELPER_D8_JAR" com.android.tools.r8.D8 \
    --release --min-api "$HELPER_MIN_API" --lib "$HELPER_ANDROID_JAR" --output "${work}/dex" "${classes[@]}")
  [[ -f "${work}/dex/classes.dex" ]] || helper_fail "d8 wrote no classes.dex"
  cp "${work}/dex/classes.dex" "${work}/offsider-helper.dex"
  helper_manifest "${work}/offsider-helper.dex" "${#sources[@]}" > "${work}/manifest.json"
}

function cmd_helper() {
  local check=0 summary current_sources committed_sources
  local committed_dex="${HELPER_OUTPUT_DIR}/offsider-helper.dex"
  local committed_manifest="${HELPER_OUTPUT_DIR}/manifest.json"
  local built_dex="${HELPER_BUILD_DIR}/offsider-helper.dex"
  local built_manifest="${HELPER_BUILD_DIR}/manifest.json"
  local differs=()
  case "${1:-}" in
    "") ;;
    --check) check=1 ;;
    *) helper_fail "Unknown option for helper: $1 (use --check)" ;;
  esac
  [[ $# -le 1 ]] || helper_fail "helper takes at most one option (--check)"
  ui_section "☕" "Building the Android Helper"
  helper_resolve_toolchain
  helper_build
  summary="offsider-helper.dex $(wc -c < "$built_dex" | tr -d ' ') bytes sha256 $(helper_sha256 "$built_dex")"

  if [[ "$check" == 1 ]]; then
    cmp -s "$built_dex" "$committed_dex" || differs+=("offsider-helper.dex")
    cmp -s "$built_manifest" "$committed_manifest" || differs+=("manifest.json")
    if [[ ${#differs[@]} -gt 0 ]]; then
      print_error "the rebuilt helper differs from the committed ${differs[*]} in ${HELPER_OUTPUT_DIR}"
      echo "   Rebuilt: ${summary}" >&2
      diff "$committed_manifest" "$built_manifest" >&2 || true
      echo "   Rebuild with $0 helper (JDK ${HELPER_JDK_MAJOR}, build-tools ${HELPER_BUILD_TOOLS}, d8 ${HELPER_D8_VERSION}) and commit the dex and manifest with the Java source." >&2
      exit 1
    fi
    print_success "${summary} matches the committed dex and manifest"
    return 0
  fi

  current_sources="$(helper_sources_sha256)"
  committed_sources=""
  if [[ -f "$committed_manifest" ]]; then
    committed_sources="$(sed -n 's/^  "sources": {"files": [0-9]*, "sha256": "\([0-9a-f]*\)"},$/\1/p' "$committed_manifest")"
  fi
  if [[ -f "$committed_dex" && "$committed_sources" == "$current_sources" ]]; then
    cmp -s "$built_dex" "$committed_dex" \
      || helper_fail "The rebuilt helper differs from the committed dex although the Java source is unchanged: use JDK ${HELPER_JDK_MAJOR} and build-tools ${HELPER_BUILD_TOOLS} (d8 ${HELPER_D8_VERSION})."
    if cmp -s "$built_manifest" "$committed_manifest"; then
      print_success "${summary} (unchanged)"
    else
      cp "$built_manifest" "$committed_manifest"
      print_success "${summary} (manifest updated)"
    fi
    return 0
  fi
  mkdir -p "$HELPER_OUTPUT_DIR"
  cp "$built_dex" "$committed_dex"
  cp "$built_manifest" "$committed_manifest"
  print_success "${summary} (updated)"
}

# XCUITest runner: an XcodeGen project.yml with the generated OffsiderRunner.xcodeproj committed beside it.
RUNNER_DIR="${REPO_ROOT}/Sources/Offsider/Resources/runner"
RUNNER_TRACKED=("project.pbxproj" "xcshareddata/xcschemes/OffsiderRunner.xcscheme")

function runner_fail() {
  print_error "$*"
  exit 1
}

function cmd_runner() {
  local check=0 work path
  local differs=()
  case "${1:-}" in
    "") ;;
    --check) check=1 ;;
    *) runner_fail "Unknown option for runner: $1 (use --check)" ;;
  esac
  [[ $# -le 1 ]] || runner_fail "runner takes at most one option (--check)"
  command -v xcodegen > /dev/null || die "XcodeGen is not installed." "brew install xcodegen"
  ui_section "🏃" "Generating the XCUITest runner project"
  work="$(mktemp -d "${TMPDIR:-/tmp}/offsider-runner.XXXXXX")"
  cp "${RUNNER_DIR}/project.yml" "$work/"
  cp -R "${RUNNER_DIR}/Host" "${RUNNER_DIR}/UITests" "$work/"
  if ! (cd "$work" && xcodegen generate --quiet --spec project.yml); then
    rm -rf "$work"
    runner_fail "xcodegen failed for ${RUNNER_DIR}/project.yml"
  fi

  if [[ "$check" == 1 ]]; then
    for path in "${RUNNER_TRACKED[@]}"; do
      cmp -s "$work/OffsiderRunner.xcodeproj/$path" "${RUNNER_DIR}/OffsiderRunner.xcodeproj/$path" || differs+=("$path")
    done
    rm -rf "$work"
    if [[ ${#differs[@]} -gt 0 ]]; then
      print_error "the regenerated runner project differs from the committed ${differs[*]}"
      echo "   Regenerate with $0 runner and commit OffsiderRunner.xcodeproj with project.yml." >&2
      exit 1
    fi
    print_success "OffsiderRunner.xcodeproj matches project.yml"
    return 0
  fi
  for path in "${RUNNER_TRACKED[@]}"; do
    mkdir -p "$(dirname "${RUNNER_DIR}/OffsiderRunner.xcodeproj/$path")"
    cp "$work/OffsiderRunner.xcodeproj/$path" "${RUNNER_DIR}/OffsiderRunner.xcodeproj/$path"
  done
  rm -rf "$work"
  print_success "OffsiderRunner.xcodeproj regenerated"
}

function print_start_here() {
  cat <<EOF
Start here:
  $0 dev       Build the idb frameworks Offsider links (once per clone), then: swift build
  $0 helper    Rebuild the Android helper after changing AndroidHelper/
  $0 runner    Regenerate the iPhone runner project after changing its project.yml
  $0 help      Every step and setting
EOF
}

function print_usage() {
cat <<EOF
Usage: $0 <command>

Everyday:
  dev [--rebuild] [--verbose]
      Check the tools, fetch the pinned idb fork and build its XCFrameworks into build_products/.
      Reuses build_products/ when it already matches the pin and this Xcode, or copies a matching one
      from another checkout of this repository (git worktree list), verified the same way.
      --rebuild always builds; --verbose streams xcodebuild instead of logging to .build/idb-build.log.
  helper [--check]
      Rebuild the Android helper dex from AndroidHelper/src with JDK ${HELPER_JDK_MAJOR}, build-tools ${HELPER_BUILD_TOOLS} (d8) and ${HELPER_PLATFORM}
      in .build/offsider-helper/, then update Sources/Offsider/Resources/helper/ when the Java source changed.
      --check rebuilds and compares with the committed dex and manifest without writing them.
  runner [--check]
      Regenerate Sources/Offsider/Resources/runner/OffsiderRunner.xcodeproj from its project.yml with XcodeGen.
      --check regenerates in a temporary directory and compares with the committed project without writing it.
  dev-sign [--if-set] [--scratch-path <dir>]
      Sign the debug offsider with the Apple Development identity OFFSIDER_DEV_SIGNING_IDENTITY names in .env, so a
      login a signed build saved reads without a Keychain prompt after any rebuild. Off until set; make build runs it.
      --if-set does nothing when it is not set. Plain swift build goes back to ad hoc after a source change.

The steps dev runs, one at a time (CI uses these):
  setup                Clone the pinned idb fork into idb_checkout/.
  clean                Remove build_products/ and build_derived_data/.
  generate             Verify the pinned fork, then generate its projects with XcodeGen.
  frameworks           Generate, then build FBControlCore, XCTestBootstrap, FBSimulatorControl and FBDeviceControl.
  install              Copy the built frameworks to build_products/Frameworks.
  strip                Remove nested frameworks from the built frameworks.
  xcframeworks         Package the XCFrameworks and record IDB_BUILD_EVIDENCE.txt.
  verify-xcframeworks  Check the XCFrameworks came from the pin and have the arm64 slice.

Release:
  executable           Build build_products/offsider (arm64) with Swift Package Manager.
  verify-arches        Check the executable and frameworks have the arm64 slice.

Environment:
  IDB_CHECKOUT_DIR       Folder for the idb fork (default: idb_checkout/ in the repository)
  IDB_GIT_URL            idb fork URL (default: https://github.com/michael-palmes/idb.git)
  IDB_GIT_REF            Exact fork revision (default: ${DEFAULT_IDB_GIT_REF})
  IDB_UPSTREAM_BASE_REF  Verified upstream base (default: e682506725e9efefb9c43b8b917c0b12eb2a5939)
  BUILD_OUTPUT_DIR       Build outputs (default: ./build_products)
  DERIVED_DATA_PATH      Derived data (default: ./build_derived_data)
  OFFSIDER_HELPER_JDK    JDK ${HELPER_JDK_MAJOR} home for helper (default: JAVA_HOME, then /usr/libexec/java_home -v ${HELPER_JDK_MAJOR})
  ANDROID_HOME           Android SDK for helper (default: ANDROID_SDK_ROOT, then ~/Library/Android/sdk)
  OFFSIDER_DEV_SIGNING_IDENTITY  Apple Development identity for dev-sign, by name or hash (default: .env, then the main checkout's .env; none is off)

Examples:
  $0 dev                  # Build the idb XCFrameworks, then run: swift build
  $0 dev --rebuild        # Build them from scratch even when a matching build exists
  $0 helper --check       # Rebuild the Android helper and compare it with the committed dex
  $0 runner --check       # Regenerate the runner project and compare it with the committed one
EOF
}

# Individual command functions
function cmd_setup() {
  ui_section "📥" "Repository Setup"
  clone_idb_repo
}

function cmd_clean() {
  ui_section "🧹" "Cleaning Previous Build Products"
  print_info "Cleaning previous build products and derived data..."
  rm -rf "${BUILD_OUTPUT_DIR}"
  rm -rf "${DERIVED_DATA_PATH}"
  mkdir -p "${BUILD_OUTPUT_DIR}"
  mkdir -p "${BUILD_XCFRAMEWORK_DIR}"
  mkdir -p "${DERIVED_DATA_PATH}"
  print_success "Build directories cleaned and recreated"
}

function cmd_frameworks() {
  ui_section "🔧" "Building Frameworks"
  generate_idb_projects
  framework_build "FBControlCore" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "XCTestBootstrap" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "FBSimulatorControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "FBDeviceControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
}

function cmd_install() {
  ui_section "📦" "Installing Frameworks"
  install_framework "FBControlCore" "${BUILD_OUTPUT_DIR}"
  install_framework "XCTestBootstrap" "${BUILD_OUTPUT_DIR}"
  install_framework "FBSimulatorControl" "${BUILD_OUTPUT_DIR}"
  install_framework "FBDeviceControl" "${BUILD_OUTPUT_DIR}"
}

function cmd_strip() {
  ui_section "✂️" "Stripping Nested Frameworks"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework/Versions/Current/Frameworks/XCTestBootstrap.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework/Versions/Current/Frameworks/FBControlCore.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework/Versions/Current/Frameworks/XCTestBootstrap.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework/Versions/Current/Frameworks/FBControlCore.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "XCTestBootstrap.framework/Versions/Current/Frameworks/FBControlCore.framework"
}

function cmd_xcframeworks() {
  ui_section "📦" "Creating XCFrameworks"
  create_xcframework "FBControlCore" "${BUILD_OUTPUT_DIR}"
  create_xcframework "XCTestBootstrap" "${BUILD_OUTPUT_DIR}"
  create_xcframework "FBSimulatorControl" "${BUILD_OUTPUT_DIR}"
  create_xcframework "FBDeviceControl" "${BUILD_OUTPUT_DIR}"
  write_idb_build_evidence
}

function cmd_generate() {
  ui_section "🧬" "Generating Candidate IDB Projects"
  generate_idb_projects
}

function cmd_executable() {
  ui_section "⚡" "Building Offsider Executable"
  build_offsider_executable "${BUILD_OUTPUT_DIR}"
}

function cmd_verify_xcframeworks() {
  ui_section "🧪" "Verifying XCFramework Inputs"
  if ! grep -Fxq "IDB_SHA=${IDB_GIT_REF}" "${BUILD_XCFRAMEWORK_DIR}/IDB_BUILD_EVIDENCE.txt" 2>/dev/null; then
    print_error "XCFrameworks were not built from the pinned IDB fork revision ${IDB_GIT_REF}"
    ui_try "$0 dev --rebuild"
    exit 1
  fi
  verify_xcframework_inputs "${BUILD_OUTPUT_DIR}"
}

function cmd_verify_arches() {
  ui_section "🧪" "Verifying Architecture Slices"
  verify_release_architectures "${BUILD_OUTPUT_DIR}"
}

# Every missing tool is listed once, with one command that installs them all.
function preflight() {
  local problems=0 missing=() tool developer_dir xcode_version="" free_gb xcode_app
  developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
  if [[ "$developer_dir" == *.app/Contents/Developer && -d "$developer_dir" ]]; then
    xcode_version="$(DEVELOPER_DIR="$developer_dir" xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  fi
  if [[ -z "$xcode_version" ]]; then
    problems=1
    xcode_app="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
    if [[ -n "$xcode_app" ]]; then
      print_error "Xcode is installed but not selected."
      ui_try "sudo xcode-select -s \"${xcode_app}/Contents/Developer\""
    else
      print_error "Xcode is not installed."
      ui_try "open macappstore://apps.apple.com/app/id497799835"
    fi
  elif [[ "${xcode_version%%.*}" -lt 26 ]]; then
    problems=1
    print_error "Xcode ${xcode_version} is too old: Offsider needs 26 or later."
    ui_try "open macappstore://apps.apple.com/app/id497799835"
  fi
  for tool in xcodegen jq git; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    problems=1
    print_error "Missing: ${missing[*]}"
    if command -v brew >/dev/null 2>&1; then
      ui_try "brew install ${missing[*]}"
    else
      ui_try "open https://brew.sh   (then: brew install ${missing[*]})"
    fi
  fi
  free_gb="$(df -g "$REPO_ROOT" | awk 'NR == 2 { print $4 }')"
  if [[ "$free_gb" =~ ^[0-9]+$ && "$free_gb" -lt 10 ]]; then
    problems=1
    print_error "Only ${free_gb} GB free: the idb build needs about 10 GB."
    ui_try "open x-apple.systempreferences:com.apple.settings.Storage"
  fi
  [[ "$problems" == 0 ]] || exit 1
  ui_row ok "Tools ready" "Xcode ${xcode_version} ${UI_DOT} xcodegen, jq, git ${UI_DOT} ${free_gb} GB free"
}

# True when <build_products> holds XCFrameworks recorded for this pin, fork URL and Xcode.
function build_matches_pin() {
  local evidence="$1/XCFrameworks/IDB_BUILD_EVIDENCE.txt"
  [[ -f "$evidence" && ! -L "$1" ]] || return 1
  grep -Fxq "IDB_SHA=${IDB_GIT_REF}" "$evidence" &&
    grep -Fxq "IDB_GIT_URL=${IDB_GIT_URL}" "$evidence" &&
    grep -Fxq "XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ')" "$evidence"
}

# Another checkout of this repository whose build_products matches the pin, or nothing.
function matching_build_elsewhere() {
  local tree own
  own="$(cd "$BUILD_OUTPUT_DIR" 2>/dev/null && pwd -P || true)"
  while IFS= read -r tree; do
    [[ -n "$tree" && -d "$tree/build_products" ]] || continue
    [[ "$(cd "$tree/build_products" && pwd -P)" != "$own" ]] || continue
    if build_matches_pin "$tree/build_products"; then
      printf '%s\n' "$tree/build_products"
      return 0
    fi
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  return 0
}

function verify_xcframeworks_quietly() {
  cmd_verify_xcframeworks >>"$IDB_BUILD_LOG" 2>&1
}

# shellcheck disable=SC2329 # run through dev_step
function package_frameworks() {
  cmd_install
  cmd_strip
  cmd_xcframeworks
}

# Quiet mode logs a step behind a spinner and leaves a status row; verbose mode (CI, a pipe or --verbose) streams it as before.
function dev_step() {
  local label="$1" status=0
  shift
  if [[ "$DEV_QUIET" == 1 ]]; then
    # Not `ui_run_logged … || die`: bash ignores set -e under ||, so a step would run on past a failure.
    set +e
    ui_run_logged "$label" "$IDB_BUILD_LOG" "$@"
    status=$?
    set -e
    [[ "$status" == 0 ]] || die "Could not finish: ${label#\[*\] }." "$0 dev --verbose"
  else
    ui_section "" "$label"
    "$@"
  fi
}

function cmd_dev() {
  local rebuild=0 donor
  # A person at a terminal and an agent get rows over a log; CI and a pipe get the full stream.
  DEV_QUIET=0
  if [[ -z "${CI:-}" ]] && [[ -t 1 || "$UI_AGENT" == 1 ]]; then DEV_QUIET=1; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rebuild) rebuild=1 ;;
      --verbose) DEV_QUIET=0 ;;
      *) die "Unknown option for dev: $1" "$0 dev --rebuild" ;;
    esac
    shift
  done
  mkdir -p "$(dirname "$IDB_BUILD_LOG")"
  : > "$IDB_BUILD_LOG"
  local pin="$IDB_GIT_REF"
  [[ "$pin" =~ ^[0-9a-f]{40}$ ]] && pin="${pin:0:7}"
  ui_banner "🛠️" "Offsider dev build" "idb ${pin}"
  preflight
  dev_step "Fetching the pinned idb fork" cmd_setup

  if [[ "$rebuild" == 0 ]]; then
    if build_matches_pin "$BUILD_OUTPUT_DIR" && verify_xcframeworks_quietly; then
      ui_receipt "Frameworks already built" "build_products matches the idb pin and this Xcode"
      ui_next "swift build"
      return 0
    fi
    donor="$(matching_build_elsewhere)"
    if [[ -n "$donor" ]]; then
      rm -rf "$BUILD_OUTPUT_DIR"
      cp -R "$donor" "$BUILD_OUTPUT_DIR"
      if verify_xcframeworks_quietly; then
        ui_receipt "Frameworks reused" "from $(ui_path "$donor")"
        ui_next "swift build"
        return 0
      fi
      print_warning "The build in ${donor} failed verification, so this one builds from scratch."
    fi
  fi

  if [[ "$DEV_QUIET" == 1 ]]; then
    cmd_clean >>"$IDB_BUILD_LOG" 2>&1
  else
    cmd_clean
  fi
  dev_step "[1/6] Generating the idb projects" generate_idb_projects
  dev_step "[2/6] Building FBControlCore" framework_build "FBControlCore" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  dev_step "[3/6] Building XCTestBootstrap" framework_build "XCTestBootstrap" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  dev_step "[4/6] Building FBSimulatorControl" framework_build "FBSimulatorControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  dev_step "[5/6] Building FBDeviceControl" framework_build "FBDeviceControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  dev_step "[6/6] Packaging the XCFrameworks" package_frameworks
  if [[ "$DEV_QUIET" == 1 ]]; then
    ui_receipt "Frameworks ready" "in $(ui_path "$BUILD_XCFRAMEWORK_DIR")" "log $(ui_path "$IDB_BUILD_LOG")"
  else
    ui_receipt "Frameworks ready" "in $(ui_path "$BUILD_XCFRAMEWORK_DIR")"
  fi
  ui_next "swift build"
}

# One key of a .env, read and never run: the file may hold anything.
function env_file_value() {
  local value
  [[ -f "$2" ]] || return 0
  value="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$2" 2>/dev/null | tail -n 1)" || return 0
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "$value"
}

# The environment, this checkout's .env, then the main checkout's, since a worktree has no .env of its own.
function dev_signing_identity() {
  local value="${OFFSIDER_DEV_SIGNING_IDENTITY:-}" common
  [[ -n "$value" ]] || value="$(env_file_value OFFSIDER_DEV_SIGNING_IDENTITY "${REPO_ROOT}/.env")"
  if [[ -z "$value" ]] && common="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    value="$(env_file_value OFFSIDER_DEV_SIGNING_IDENTITY "$(dirname "$common")/.env")"
  fi
  printf '%s' "$value"
}

function cmd_dev_sign() {
  local if_set=0 identity rows matches count sha name bin_dir bin output
  local scratch=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --if-set) if_set=1; shift;;
      --scratch-path)
        [[ $# -ge 2 ]] || die "--scratch-path needs a folder." "$0 dev-sign --scratch-path <dir>"
        scratch=(--scratch-path "$2"); shift 2;;
      *) die "Unknown option for dev-sign: $1" "$0 help";;
    esac
  done

  identity="$(dev_signing_identity)"
  if [[ -z "$identity" ]]; then
    [[ "$if_set" == 1 ]] && return 0
    die "OFFSIDER_DEV_SIGNING_IDENTITY is not set, so debug builds stay ad hoc." "Add your Apple Development identity to .env (see .env.example)"
  fi

  rows="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$/\1|\2/p')" || rows=""
  matches="$(printf '%s\n' "$rows" | WANT="$identity" awk -F'|' 'length($1) && ($1 == ENVIRON["WANT"] || $2 == ENVIRON["WANT"])')"
  count="$(printf '%s' "$matches" | grep -c '|' || true)"
  [[ "$count" -gt 0 ]] || die "OFFSIDER_DEV_SIGNING_IDENTITY names no valid signing identity on this Mac, so this build stays ad hoc." "security find-identity -v -p codesigning"
  [[ "$count" -eq 1 ]] || die "OFFSIDER_DEV_SIGNING_IDENTITY matches $count identities. Use the 40-character hash of one in .env." "security find-identity -v -p codesigning"
  sha="${matches%%|*}"
  name="${matches#*|}"
  [[ "$name" == "Apple Development:"* ]] || die "A debug build signs with an Apple Development identity only, so nothing was signed." "security find-identity -v -p codesigning"

  bin_dir="$(swift build "${scratch[@]}" --show-bin-path)" || die "swift could not name the build folder." "swift build"
  bin="${bin_dir}/offsider"
  [[ -f "$bin" ]] || die "There is no debug Offsider to sign yet." "swift build"

  # Hardened, so DYLD_INSERT_LIBRARIES and debuggers cannot reach it. Library validation stays off, since swift build restores ad hoc frameworks without relinking: whatever can write to .build runs inside it.
  output="$(codesign --force --sign "$sha" --timestamp=none --options runtime --identifier "$DEV_SIGNING_IDENTIFIER" --entitlements "${REPO_ROOT}/entitlements-adhoc.plist" "$bin" 2>&1)" ||
    die "codesign could not use that identity: ${output##*$'\n'}" "security find-identity -v -p codesigning"
  "$bin" --version >/dev/null 2>&1 || die "The signed build does not start." "swift build"
  ui_receipt "Signed the debug Offsider" "$(ui_path "$bin")"
}

# Parse command line arguments
if [[ $# -eq 0 ]]; then
  print_start_here
  exit 0
fi
COMMAND="$1"

case $COMMAND in
  help|-h|--help)
    print_usage
    exit 0;;
  setup)
    cmd_setup;;
  generate)
    cmd_generate;;
  clean)
    cmd_clean;;
  frameworks)
    cmd_frameworks;;
  install)
    cmd_install;;
  strip)
    cmd_strip;;
  xcframeworks)
    cmd_xcframeworks;;
  dev)
    shift
    cmd_dev "$@";;
  executable)
    cmd_executable;;
  verify-xcframeworks)
    cmd_verify_xcframeworks;;
  verify-arches)
    cmd_verify_arches;;
  helper)
    shift
    cmd_helper "$@";;
  runner)
    shift
    cmd_runner "$@";;
  dev-sign)
    shift
    cmd_dev_sign "$@";;
  *)
    die "Unknown command: $COMMAND" "$0 help";;
esac

exit 0
