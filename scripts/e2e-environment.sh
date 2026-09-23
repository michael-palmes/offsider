#!/bin/bash

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

run_selected_swift() {
    DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" "$SELECTED_SWIFT" "$@"
}

E2E_FALLBACK_SIMULATOR_NAME="Offsider E2E iPhone"

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
            printf 'No available iOS simulator is named "%s". Available iOS simulators:\n' \
                "$OFFSIDER_SIMULATOR_NAME" >&2
            jq -r '.[] | "  \(.name) (\(.udid), iOS \(.major).\(.minor), \(.state))"' <<< "$devices" >&2
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
        printf 'No iOS %s runtime with an iPhone Pro device type is installed.\n' "$SELECTED_XCODE_MAJOR" >&2
        return 1
    fi

    local runtime="${runtime_and_type%% *}"
    local device_type="${runtime_and_type#* }"
    printf 'Creating simulator "%s" (%s, %s)\n' "$E2E_FALLBACK_SIMULATOR_NAME" "$device_type" "$runtime" >&2
    local udid
    udid="$(xcrun simctl create "$E2E_FALLBACK_SIMULATOR_NAME" "$device_type" "$runtime")" || return 1
    printf '%s\t%s\n' "$udid" "$E2E_FALLBACK_SIMULATOR_NAME"
}

ensure_e2e_runtime_host() {
    [[ "$SELECTED_XCODE_MAJOR" -ge 27 ]] || return 0

    local device_hub_app="${SELECTED_DEVELOPER_DIR%/Contents/Developer}/Contents/Applications/DeviceHub.app"
    [[ -d "$device_hub_app" ]] || return 1
    if pgrep -x Simulator >/dev/null; then
        printf 'Simulator.app is running; quit it before testing Xcode 27 through Device Hub.\n' >&2
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
