#!/bin/bash
# Builds the required IDB Frameworks for the Offsider project.

set -e
set -o pipefail

# On a TTY, git eagerly spawns an interactive pager for diff/log commands —
# even with empty output — blocking the build until 'q' is pressed. Force
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
# Tag offsider-idb-v0.1.0 on branch offsider/xcode27
DEFAULT_IDB_GIT_REF="604c51013438f0c3603b720a05a44b7c5b8f286d"
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

# --- Helper Functions ---

# Temporarily disable xcpretty to see actual errors in CI
# if hash xcpretty 2>/dev/null; then
#   HAS_XCPRETTY=true
# fi

# Function to print a section header with emoji
function print_section() {
  local emoji="$1"
  local title="$2"
  echo ""
  echo ""
  echo "${emoji} ${title}"
  echo "$(printf '·%.0s' {1..60})"
}

# Function to print a subsection header
function print_subsection() {
  local emoji="$1"
  local title="$2"
  echo ""
  echo "${emoji} ${title}"
}

# Function to print success message
function print_success() {
  local message="$1"
  echo "✅ ${message}"
}

# Function to print info message
function print_info() {
  local message="$1"
  echo "ℹ️  ${message}"
}

# Function to print warning message
function print_warning() {
  local message="$1"
  echo "⚠️  ${message}"
}

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

trap cleanup_current_idb_replacement EXIT

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
    echo "❌ Error: Binary not found for architecture verification: $binary_path"
    exit 1
  fi

  local arch_info
  arch_info=$(lipo -info "$binary_path" 2>/dev/null || true)
  if [[ "$arch_info" != *"$expected_arch"* ]]; then
    echo "❌ Error: Missing architecture '${expected_arch}' in $binary_path"
    echo "   lipo output: ${arch_info:-<empty>}"
    exit 1
  fi
}

function verify_fbsimulatorcontrol_fork_features() {
  local binary_path="$1"

  if [[ ! -f "$binary_path" ]]; then
    echo "❌ Error: FBSimulatorControl binary not found for fork feature verification: $binary_path"
    exit 1
  fi

  local required_references=(
    "setClientType:"
    "XCUIDeviceRemoteAutomationSession"
    "enableAutomationModeWithError:"
    "loadAccessibilityWithTimeout:reply:"
    "transportType"
  )
  local reference
  for reference in "${required_references[@]}"; do
    if ! strings -a "$binary_path" | grep -F "$reference" >/dev/null; then
      echo "❌ Error: FBSimulatorControl is missing required fork feature evidence: ${reference}"
      echo "   Checked binary: $binary_path"
      echo "   Expected fork revision: ${IDB_GIT_URL}@${IDB_GIT_REF}"
      echo "   Re-run setup, generation, and the framework build."
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
      echo "❌ Error: FBSimulatorControl compiled Swift module is missing: ${compiled_swift_module}"
      echo "   Textual reconstruction is not viable because the module and public class share a name."
      exit 1
    fi
  done
  local artifact
  for artifact in "${public_module_artifacts[@]}"; do
    if [[ ! -f "$artifact" ]]; then
      echo "❌ Error: FBSimulatorControl public module artifact is missing: ${artifact}"
      exit 1
    fi
    if grep -E 'AccessibilityPlatformTranslation|AXP[A-Za-z]' "$artifact" >/dev/null; then
      echo "❌ Error: FBSimulatorControl leaks AccessibilityPlatformTranslation through its public interface"
      echo "   Leaking artifact: ${artifact}"
      echo "   Rebuild from the pinned Offsider IDB fork revision."
      exit 1
    fi
  done

  if ! grep -F 'FBAccessibilityElement' "${public_module_artifacts[0]}" >/dev/null ||
    ! grep -F 'accessibilityElementForFrontmostApplication' "${public_module_artifacts[0]}" >/dev/null
  then
    echo "❌ Error: FBSimulatorControl lost the public Offsider accessibility command surface"
    echo "   Checked: ${public_module_artifacts[0]}"
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

  return $exit_code
}

function swift_build_bin_path() {
  local build_config="$1"
  local target_arch="$2"
  swift build --configuration "$build_config" --arch "$target_arch" --show-bin-path
}

function copy_resource_bundle() {
  local output_base_dir="$1"
  local bundle_name="Offsider_Offsider.bundle"
  local bundle_dest="${output_base_dir}/${bundle_name}"
  local bundle_source
  bundle_source="$(swift_build_bin_path "release" "arm64")/${bundle_name}"

  if [[ ! -d "$bundle_source" ]]; then
    echo "❌ Error: Offsider resource bundle not found in Swift build outputs"
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
      echo "❌ Error: Refusing to replace an unmanaged IDB checkout: $IDB_CHECKOUT_DIR" >&2
      echo "   Remove or repair that checkout manually, then retry." >&2
      return 1
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
          echo "Error: Refusing to repair an unmanaged IDB checkout: $IDB_CHECKOUT_DIR" >&2
          echo "   Clean or repair that checkout manually, then retry." >&2
          return 1
        fi
        print_warning "The pinned IDB checkout is dirty; repairing the managed checkout locally."
        if ! git -C "$IDB_CHECKOUT_DIR" restore --source=HEAD --staged --worktree -- . ||
           ! git -C "$IDB_CHECKOUT_DIR" clean -fd; then
          if [[ "$IDB_CHECKOUT_DIR" == "$DEFAULT_IDB_CHECKOUT_DIR" ]]; then
            fresh_clone_idb_repo
          else
            echo "Error: Unable to repair managed IDB checkout: $IDB_CHECKOUT_DIR" >&2
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
    echo "❌ Error: IDB checkout SHA mismatch"
    echo "   Expected: $IDB_GIT_REF"
    echo "   Actual:   $actual_ref"
    exit 1
  fi

  local actual_remote
  actual_remote=$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin)
  if [[ "$actual_remote" != "$IDB_GIT_URL" ]]; then
    echo "❌ Error: IDB checkout remote mismatch"
    echo "   Expected: $IDB_GIT_URL"
    echo "   Actual:   $actual_remote"
    exit 1
  fi
  if ! git -C "$IDB_CHECKOUT_DIR" merge-base --is-ancestor "$IDB_UPSTREAM_BASE_REF" "$actual_ref"; then
    echo "❌ Error: Pinned IDB fork revision is not based on $IDB_UPSTREAM_BASE_REF"
    exit 1
  fi

  local source_checks=(
    "FBControlCore/Utility/FBXcodeDirectory.swift|environment[\"DEVELOPER_DIR\"]"
    "FBSimulatorControl/Commands/FBAXTranslationDispatcher.swift|clientType = 2"
    "FBSimulatorControl/Commands/FBAXTranslationRequest.swift|@_implementationOnly import AccessibilityPlatformTranslation"
    "FBSimulatorControl/HID/FBSimulatorHID.swift|public let transportType"
    "FBSimulatorControl/HID/FBSimulatorHIDEvent.swift|event.event(for: transportType)"
    "FBSimulatorControl/Utility/FBSimulatorControlFrameworkLoader.m|XCUIDeviceRemoteAutomationSession"
  )
  local check source_file source_marker
  for check in "${source_checks[@]}"; do
    source_file="${check%%|*}"
    source_marker="${check#*|}"
    if ! grep -Fq "$source_marker" "${IDB_CHECKOUT_DIR}/${source_file}"; then
      echo "❌ Error: Pinned IDB fork verification failed"
      echo "   Missing '${source_marker}' in ${source_file}"
      echo "   Fork revision: ${IDB_GIT_URL}@${IDB_GIT_REF}"
      exit 1
    fi
  done

  if ! git -C "$IDB_CHECKOUT_DIR" diff --check; then
    echo "❌ Error: Pinned IDB fork checkout contains uncommitted whitespace errors"
    exit 1
  fi
  if [[ -n "$(git -C "$IDB_CHECKOUT_DIR" status --porcelain)" ]]; then
    echo "❌ Error: Pinned IDB fork checkout is not clean"
    exit 1
  fi

  print_success "Verified IDB fork ${IDB_GIT_URL}@${actual_ref} from upstream base ${IDB_UPSTREAM_BASE_REF}"
}

function generate_idb_projects() {
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "❌ Error: XcodeGen is required to generate the pinned IDB fork projects."
    echo "   Install XcodeGen or make an existing installation available in PATH."
    exit 1
  fi

  verify_idb_source_state
  print_info "Generating pinned IDB fork projects with $(xcodegen --version)..."
  (cd "$IDB_CHECKOUT_DIR" && ./build.sh generate)
  if [[ ! -f "${FBSIMCONTROL_PROJECT}/project.pbxproj" ]]; then
    echo "❌ Error: IDB project generation did not produce ${FBSIMCONTROL_PROJECT}/project.pbxproj"
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

  print_subsection "🔨" "Building framework: ${scheme_name}"
  print_info "Project: ${project_file}"

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
    echo "❌ Error: Framework ${scheme_name} build failed with exit code ${build_exit_code}"
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
    echo "❌ Error: Built framework not found at ${built_framework_path} for installation."
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

  print_subsection "📦" "Creating XCFramework for ${scheme_name}"
  if [[ ! -d "${signed_framework_path}" ]]; then
    echo "❌ Error: Signed framework not found at ${signed_framework_path} for XCFramework creation."
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
    echo "❌ Error: XCFramework creation for ${scheme_name} failed with exit code ${xcframework_exit_code}"
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

  print_subsection "⚡" "Building Offsider executable"
  print_info "Using Swift Package Manager to build Offsider..."

  # Clean any existing build products to ensure fresh build
  print_info "Cleaning previous build products..."
  swift package clean

  print_info "Building arm64 executable..."
  swift build --configuration "${build_config}" --arch arm64
  bin_path="$(swift_build_bin_path "$build_config" "arm64")/offsider"
  if [[ ! -f "${bin_path}" ]]; then
    echo "❌ Error: arm64 Offsider executable not found at ${bin_path}"
    exit 1
  fi
  cp "${bin_path}" "${executable_dest}"

  copy_resource_bundle "${output_base_dir}"

  verify_macho_has_arch "${executable_dest}" "arm64"
  print_success "Offsider executable installed to ${executable_dest}"

  # Configure rpath for organized framework loading
  print_info "Configuring executable rpath for organized framework loading..."

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
  local rpath_output=$(otool -l "${executable_dest}" | grep -A2 LC_RPATH | grep path | awk '{print $2}')
  if [[ -n "$rpath_output" ]]; then
    print_success "Executable rpath configuration verified:"
    echo "$rpath_output" | while read -r path; do
      print_info "  → ${path}"
    done
  else
    print_warning "No rpath entries found in executable"
  fi

  print_success "Executable rpath configured for organized framework deployment"
}

function verify_xcframework_inputs() {
  local output_base_dir="$1"
  local xcframeworks_dir="${output_base_dir}/XCFrameworks"
  local expected_frameworks=("FBControlCore" "XCTestBootstrap" "FBSimulatorControl" "FBDeviceControl")

  print_subsection "🧪" "Validating XCFramework inputs"

  if [[ ! -d "${xcframeworks_dir}" ]]; then
    echo "❌ Error: XCFrameworks directory not found under ${output_base_dir}"
    exit 1
  fi

  for framework_name in "${expected_frameworks[@]}"; do
    local xcframework_path="${xcframeworks_dir}/${framework_name}.xcframework"
    if [[ ! -d "${xcframework_path}" ]]; then
      echo "❌ Error: Expected XCFramework missing from ${xcframeworks_dir}: ${framework_name}.xcframework"
      exit 1
    fi
    local framework_binary
    framework_binary="$(find "${xcframework_path}" -type f -name "${framework_name}" -path "*/macos-*/*.framework/*" | head -1)"
    if [[ -z "${framework_binary}" ]]; then
      echo "❌ Error: Could not locate framework binary inside ${xcframework_path}"
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

  print_subsection "🧪" "Validating release artifact architectures"
  verify_macho_has_arch "${executable_path}" "arm64"

  if [[ ! -d "${frameworks_dir}" ]]; then
    echo "❌ Error: Frameworks directory not found under ${output_base_dir}"
    exit 1
  fi

  for framework_name in "${expected_frameworks[@]}"; do
    local framework_path="${frameworks_dir}/${framework_name}.framework"
    if [[ ! -d "${framework_path}" ]]; then
      echo "❌ Error: Expected framework missing from ${frameworks_dir}: ${framework_name}.framework"
      exit 1
    fi
    local framework_binary
    framework_binary="$(resolve_framework_binary "${framework_path}" "${framework_name}" || true)"
    if [[ -z "${framework_binary}" ]]; then
      echo "❌ Error: Could not locate framework binary in ${framework_path}"
      exit 1
    fi
    verify_macho_has_arch "${framework_binary}" "arm64"
    if [[ "${framework_name}" == "FBSimulatorControl" ]]; then
      verify_fbsimulatorcontrol_fork_features "${framework_binary}"
    fi
  done

  print_success "Release artifacts include the arm64 slice"
}

# Function to print usage information
function print_usage() {
cat <<EOF
./build.sh usage:
  ./build.sh <command>

Commands:
  help
    Print this usage information.

  setup
    Clone the IDB repository and set up directories.

  clean
    Clean previous build products and derived data.

  generate
    Verify the pinned IDB fork revision, then regenerate projects using XcodeGen.

  frameworks
    Generate the pinned fork project, then build all IDB frameworks (FBControlCore, XCTestBootstrap, FBSimulatorControl, FBDeviceControl).

  install
    Install built frameworks to the Frameworks directory.

  strip
    Strip nested frameworks from the built frameworks.

  xcframeworks
    Create XCFrameworks from the built frameworks.

  dev
    Run setup, clean, frameworks, install, strip and xcframeworks. Frameworks stay unsigned beyond the linker's ad hoc signature.

  executable
    Build the arm64 Offsider executable using Swift Package Manager.

  verify-xcframeworks
    Verify XCFramework inputs include the arm64 slice.

  verify-arches
    Verify the executable and frameworks include the arm64 slice.

Environment Variables:
  IDB_CHECKOUT_DIR       Directory for IDB repository (default: ./idb_checkout)
  IDB_GIT_URL            IDB fork URL (default: https://github.com/michael-palmes/idb.git)
  IDB_GIT_REF            Exact fork revision (default: ${DEFAULT_IDB_GIT_REF})
  IDB_UPSTREAM_BASE_REF  Verified upstream base (default: e682506725e9efefb9c43b8b917c0b12eb2a5939)
  BUILD_OUTPUT_DIR       Directory for build outputs (default: ./build_products)
  DERIVED_DATA_PATH      Directory for derived data (default: ./build_derived_data)

Examples:
  ./build.sh dev                # Build the IDB frameworks and XCFrameworks
  ./build.sh executable         # Build build_products/offsider
  ./build.sh verify-arches      # Check the built payload
EOF
}

# Individual command functions
function cmd_setup() {
  print_section "📥" "Repository Setup"
  clone_idb_repo
}

function cmd_clean() {
  print_section "🧹" "Cleaning Previous Build Products"
  print_info "Cleaning previous build products and derived data..."
  rm -rf "${BUILD_OUTPUT_DIR}"
  rm -rf "${DERIVED_DATA_PATH}"
  mkdir -p "${BUILD_OUTPUT_DIR}"
  mkdir -p "${BUILD_XCFRAMEWORK_DIR}"
  mkdir -p "${DERIVED_DATA_PATH}"
  print_success "Build directories cleaned and recreated"
}

function cmd_frameworks() {
  print_section "🔧" "Building Frameworks"
  generate_idb_projects
  framework_build "FBControlCore" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "XCTestBootstrap" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "FBSimulatorControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
  framework_build "FBDeviceControl" "${FBSIMCONTROL_PROJECT}" "${BUILD_OUTPUT_DIR}"
}

function cmd_install() {
  print_section "📦" "Installing Frameworks"
  install_framework "FBControlCore" "${BUILD_OUTPUT_DIR}"
  install_framework "XCTestBootstrap" "${BUILD_OUTPUT_DIR}"
  install_framework "FBSimulatorControl" "${BUILD_OUTPUT_DIR}"
  install_framework "FBDeviceControl" "${BUILD_OUTPUT_DIR}"
}

function cmd_strip() {
  print_section "✂️" "Stripping Nested Frameworks"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework/Versions/Current/Frameworks/XCTestBootstrap.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBSimulatorControl.framework/Versions/Current/Frameworks/FBControlCore.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework/Versions/Current/Frameworks/XCTestBootstrap.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "FBDeviceControl.framework/Versions/Current/Frameworks/FBControlCore.framework"
  strip_framework "${BUILD_OUTPUT_DIR}" "XCTestBootstrap.framework/Versions/Current/Frameworks/FBControlCore.framework"
}

function cmd_xcframeworks() {
  print_section "📦" "Creating XCFrameworks"
  create_xcframework "FBControlCore" "${BUILD_OUTPUT_DIR}"
  create_xcframework "XCTestBootstrap" "${BUILD_OUTPUT_DIR}"
  create_xcframework "FBSimulatorControl" "${BUILD_OUTPUT_DIR}"
  create_xcframework "FBDeviceControl" "${BUILD_OUTPUT_DIR}"
  write_idb_build_evidence
}

function cmd_generate() {
  print_section "🧬" "Generating Candidate IDB Projects"
  generate_idb_projects
}

function cmd_executable() {
  print_section "⚡" "Building Offsider Executable"
  build_offsider_executable "${BUILD_OUTPUT_DIR}"
}

function cmd_verify_xcframeworks() {
  print_section "🧪" "Verifying XCFramework Inputs"
  verify_xcframework_inputs "${BUILD_OUTPUT_DIR}"
}

function cmd_verify_arches() {
  print_section "🧪" "Verifying Architecture Slices"
  verify_release_architectures "${BUILD_OUTPUT_DIR}"
}

# Parse command line arguments
if [[ $# -eq 0 ]]; then
  print_usage
  exit 1
fi
COMMAND="$1"

case $COMMAND in
  help)
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
    cmd_setup
    cmd_clean
    cmd_frameworks
    cmd_install
    cmd_strip
    cmd_xcframeworks;;
  executable)
    cmd_executable;;
  verify-xcframeworks)
    cmd_verify_xcframeworks;;
  verify-arches)
    cmd_verify_arches;;
  *)
    echo "Unknown command: $COMMAND"
    echo ""
    print_usage
    exit 1;;
esac

exit 0
