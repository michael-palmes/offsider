#!/bin/bash
# shellcheck disable=SC2034 # the SELECTED_* and SIMULATOR_* values are read by test-runner.sh
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

e2e_xcode_version() {
    DEVELOPER_DIR="$1" xcodebuild -version | awk 'NR == 1 { print $2 }'
}

e2e_xcode_build() {
    DEVELOPER_DIR="$1" xcodebuild -version | awk '/Build version/ { print $3 }'
}

# Build and run tests with the same selected Xcode; exact build IDs are provenance only.
configure_e2e_environment() {
    SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
    [[ -d "$SELECTED_DEVELOPER_DIR" ]] || return 1
    SELECTED_DEVELOPER_DIR="$(cd "$SELECTED_DEVELOPER_DIR" && pwd)"
    SELECTED_XCODE_VERSION="$(e2e_xcode_version "$SELECTED_DEVELOPER_DIR")"
    SELECTED_XCODE_MAJOR="${SELECTED_XCODE_VERSION%%.*}"
    [[ "$SELECTED_XCODE_MAJOR" -ge 26 ]] || return 1

    SELECTED_SWIFT="$(DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" xcrun --find swift)"
    export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
}

# In CI, build and test refuse to resolve past Package.resolved, so a run uses exactly the pinned dependencies.
run_selected_swift() {
    if [[ "${CI:-}" == "true" ]] && { [[ "${1:-}" == "build" ]] || [[ "${1:-}" == "test" ]]; }; then
        DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" "$SELECTED_SWIFT" "$@" --force-resolved-versions
    else
        DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" "$SELECTED_SWIFT" "$@"
    fi
}

E2E_FALLBACK_SIMULATOR_NAME="Offsider E2E"

e2e_list_ios_devices() {
    xcrun simctl list devices available -j | jq -c \
        '[.devices | to_entries[]
          | (.key | capture("\\.iOS-(?<major>[0-9]+)-(?<minor>[0-9]+)$")) as $runtime
          | select($runtime != null)
          | .value[]
          | select(.isAvailable == true)
          | {udid, name, state,
             major: ($runtime.major | tonumber),
             minor: ($runtime.minor | tonumber)}]'
}

# Picks SIMULATOR_UDID from SIMULATOR_UDID, OFFSIDER_SIMULATOR_NAME, or a stock iPhone on the selected Xcode's iOS major.
select_e2e_simulator() {
    local devices
    devices="$(e2e_list_ios_devices)" || return 1

    if [[ -n "$SIMULATOR_UDID" ]]; then
        SIMULATOR_NAME="$(jq -r --arg udid "$SIMULATOR_UDID" \
            'map(select(.udid == $udid)) | .[0].name // empty' <<< "$devices")"
        return 0
    fi

    local selected
    if [[ -n "${OFFSIDER_SIMULATOR_NAME:-}" ]]; then
        selected="$(jq -r --arg name "$OFFSIDER_SIMULATOR_NAME" --argjson major "$SELECTED_XCODE_MAJOR" \
            'map(select(.name == $name))
             | sort_by([
                 (if .state == "Booted" then 0 else 1 end),
                 (if .major == $major then 0 else 1 end),
                 -.major, -.minor])
             | .[0] // empty | "\(.udid)\t\(.name)"' <<< "$devices")"
        if [[ -z "$selected" ]]; then
            print_error "No available iOS simulator is named \"$OFFSIDER_SIMULATOR_NAME\". These are:"
            jq -r '.[] | "  \(.name) (\(.udid), iOS \(.major).\(.minor), \(.state))"' <<< "$devices" >&2
            ui_try "OFFSIDER_SIMULATOR_NAME=\"<one of these>\" ./test-runner.sh"
            return 1
        fi
    else
        selected="$(jq -r --argjson major "$SELECTED_XCODE_MAJOR" --arg fallback "$E2E_FALLBACK_SIMULATOR_NAME" \
            'map(select(.major == $major and ((.name | test("^iPhone [0-9]+")) or .name == $fallback)))
             | sort_by([
                 (if .state == "Booted" then 0 else 1 end),
                 (if .name == $fallback then 1 else 0 end),
                 (if .name | test("^iPhone [0-9]+ Pro$") then 0 else 1 end),
                 -((.name | capture("^iPhone (?<model>[0-9]+)").model // "0") | tonumber),
                 -.minor])
             | .[0] // empty | "\(.udid)\t\(.name)"' <<< "$devices")"
        if [[ -z "$selected" ]]; then
            selected="$(create_e2e_simulator)" || return 1
        fi
    fi

    SIMULATOR_UDID="${selected%%$'\t'*}"
    SIMULATOR_NAME="${selected#*$'\t'}"
}

# Creates the fallback iPhone on the newest iOS runtime matching the selected Xcode's major; prints "udid<TAB>name".
create_e2e_simulator() {
    local runtime_and_type
    runtime_and_type="$(xcrun simctl list runtimes available -j | jq -r --argjson major "$SELECTED_XCODE_MAJOR" \
        '[.runtimes[]
          | select(.platform == "iOS" and .isAvailable == true)
          | (.version | split(".") | map(tonumber)) as $version
          | select($version[0] == $major)
          | {identifier, $version,
             types: [.supportedDeviceTypes[]?
                     | select(.name | test("^iPhone [0-9]+ Pro$"))
                     | {identifier, model: (.name | capture("^iPhone (?<m>[0-9]+)").m | tonumber)}]}
          | select(.types | length > 0)]
         | sort_by(.version) | last // empty
         | "\(.identifier) \(.types | sort_by(.model) | last | .identifier)"')"
    if [[ -z "$runtime_and_type" ]]; then
        print_error "No iOS ${SELECTED_XCODE_MAJOR} runtime with an iPhone Pro device type is installed."
        ui_try "xcodebuild -downloadPlatform iOS"
        return 1
    fi

    local runtime="${runtime_and_type%% *}"
    local device_type="${runtime_and_type#* }"
    log "Creating simulator \"$E2E_FALLBACK_SIMULATOR_NAME\" ($device_type, $runtime)"
    local udid
    udid="$(xcrun simctl create "$E2E_FALLBACK_SIMULATOR_NAME" "$device_type" "$runtime")" || return 1
    printf '%s\t%s\n' "$udid" "$E2E_FALLBACK_SIMULATOR_NAME"
}

ensure_e2e_runtime_host() {
    [[ "$SELECTED_XCODE_MAJOR" -ge 27 ]] || return 0

    local device_hub_app="${SELECTED_DEVELOPER_DIR%/Contents/Developer}/Contents/Applications/DeviceHub.app"
    [[ -d "$device_hub_app" ]] || return 1
    if pgrep -x Simulator >/dev/null; then
        print_error "Simulator.app is running: Xcode 27 tests run through Device Hub instead."
        ui_try "osascript -e 'quit app \"Simulator\"'"
        return 1
    fi
    open -g "$device_hub_app"

    local attempts_remaining=5
    while [[ "$attempts_remaining" -gt 0 ]]; do
        pgrep -f "$device_hub_app/Contents/MacOS/DeviceHub" >/dev/null && return 0
        sleep 1
        attempts_remaining=$((attempts_remaining - 1))
    done
    return 1
}

# The Offsider this run tests, as a command a person can paste: an older offsider on PATH may lack what the runner asks for.
offsider_command() {
    printf '%q' "${OFFSIDER_BIN_PATH:-offsider}"
}

# Prints "id<TAB>name" of the one active allowance for a platform (ios or android) that pins `app`.
# Anything else prints why in one line and fails, so a device a person allowed for another app is never driven.
allowed_device_for() {
    local platform="$1" app="$2"
    local status count i
    status="$("$OFFSIDER_BIN_PATH" device-access status --json 2>/dev/null)" || status=""
    count="$(printf '%s' "$status" | plutil -extract devices raw -o - - 2>/dev/null)" || count=0
    local ids=() names=() apps=()
    for (( i = 0; i < count; i++ )); do
        [[ "$(printf '%s' "$status" | plutil -extract "devices.$i.platform" raw -o - - 2>/dev/null)" == "$platform" ]] || continue
        [[ "$(printf '%s' "$status" | plutil -extract "devices.$i.active" raw -o - - 2>/dev/null)" == true ]] || continue
        ids+=("$(printf '%s' "$status" | plutil -extract "devices.$i.id" raw -o - - 2>/dev/null)")
        names+=("$(printf '%s' "$status" | plutil -extract "devices.$i.name" raw -o - - 2>/dev/null)")
        apps+=("$(printf '%s' "$status" | plutil -extract "devices.$i.apps" json -o - - 2>/dev/null || echo '[]')")
    done
    local label="Android phone"
    [[ "$platform" == ios ]] && label="iPhone or iPad"
    if (( ${#ids[@]} == 0 )); then
        printf 'No %s is allowed now.\n' "$label"
        return 1
    fi
    if (( ${#ids[@]} > 1 )); then
        local joined
        joined="$(printf '%s, ' "${names[@]}")"
        printf 'More than one %s is allowed (%s), so none is picked.\n' "$label" "${joined%, }"
        return 1
    fi
    if [[ "${apps[0]}" != *"\"$app\""* ]]; then
        printf '%s is allowed, but its allowance does not pin %s, so it is not picked.\n' "${names[0]}" "$app"
        return 1
    fi
    printf '%s\t%s\n' "${ids[0]}" "${names[0]}"
}

# The team an iPhone or iPad's allowance records, or nothing.
allowance_team() {
    "$OFFSIDER_BIN_PATH" device-access status --device "$1" --json 2>/dev/null | plutil -extract devices.0.team raw -o - - 2>/dev/null || true
}

# The command a person runs to allow a device, with what to choose in its menus.
print_device_allow() {
    local name="$1"
    local app="${2:-}"
    print_error "  $(offsider_command) device-access allow"
    if [[ -n "$app" ]]; then
        print_error "  Then choose $name, pin $app, and allow at least 2 hours."
    else
        print_error "  Then choose $name and allow at least 2 hours."
    fi
}
