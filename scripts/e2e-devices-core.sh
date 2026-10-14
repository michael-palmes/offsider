#!/usr/bin/env bash
# Reports and creates the E2E devices (Offsider_E2E, Offsider_E2E_Fold, Offsider Duo); JSON to stdout, never boots or touches another device.
# shellcheck disable=SC2016 # jq programs use $name, expanded by jq not the shell
set -euo pipefail

AVD_NAME="Offsider_E2E"
FOLD_AVD_NAME="Offsider_E2E_Fold"
DUO_NAME="Offsider Duo"
AVD_PROFILE="pixel_9"
FOLD_AVD_PROFILE="pixel_9_pro_fold"
DUO_DEVICE_TYPE_NAME="iPhone Duo"
SYSTEM_IMAGE="system-images;android-36;google_apis_ps16k;arm64-v8a"
SYSTEM_IMAGE_DIR="system-images/android-36/google_apis_ps16k/arm64-v8a"
# The settings the E2E AVDs are tested with: a hardware keyboard so gRPC keys arrive, 6 GB RAM and data.
AVD_SETTINGS=("hw.keyboard=yes" "hw.ramSize=6144" "disk.dataPartition.size=6G")

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AVD_HOME="${ANDROID_AVD_HOME:-${ANDROID_USER_HOME:-$HOME/.android}/avd}"
XCRUN="${E2E_DEVICES_XCRUN:-/usr/bin/xcrun}"

usage() {
    cat <<EOF
Usage: $0 status|create [--dry-run]

  status   Print which E2E devices exist, as JSON.
  create   Create the missing ones: the AVDs ${AVD_NAME} (${AVD_PROFILE}) and ${FOLD_AVD_NAME} (${FOLD_AVD_PROFILE})
           on ${SYSTEM_IMAGE}, and the "${DUO_NAME}" simulator (${DUO_DEVICE_TYPE_NAME}, newest iOS runtime).
           Nothing is booted and no other device is touched. --dry-run prints the commands instead.

Exit codes: 0 done, 1 a device could not be created, 2 usage, 4 a tool is missing.
EOF
}

err() { printf '%s\n' "$*" >&2; }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# The newest Android command-line tools, as an absolute path to the named tool, or nothing.
android_tool() {
    local name="$1" candidate
    if [[ -x "$SDK/cmdline-tools/latest/bin/$name" ]]; then
        printf '%s' "$SDK/cmdline-tools/latest/bin/$name"
        return 0
    fi
    for candidate in "$SDK"/cmdline-tools/*/bin/"$name"; do
        [[ -x "$candidate" ]] && printf '%s' "$candidate"
    done
    return 0
}

JQ="$(command -v jq || true)"

avd_exists() { [[ -f "$AVD_HOME/$1.ini" ]]; }

simulator_exists() {
    [[ -x "$XCRUN" && -n "$JQ" ]] || return 1
    "$XCRUN" simctl list devices -j 2>/dev/null |
        "$JQ" -e --arg name "$1" '[.devices[][] | select(.name == $name)] | length > 0' >/dev/null
}

device_json() {
    local name="$1" kind="$2" profile="$3" exists="$4"
    printf '{"name":"%s","kind":"%s","profile":"%s","exists":%s}' \
        "$(json_escape "$name")" "$kind" "$(json_escape "$profile")" "$exists"
}

cmd_status() {
    local e2e=false fold=false duo=false missing=()
    avd_exists "$AVD_NAME" && e2e=true
    avd_exists "$FOLD_AVD_NAME" && fold=true
    simulator_exists "$DUO_NAME" && duo=true
    [[ "$e2e" == true ]] || missing+=("\"$AVD_NAME\"")
    [[ "$fold" == true ]] || missing+=("\"$FOLD_AVD_NAME\"")
    [[ "$duo" == true ]] || missing+=("\"$DUO_NAME\"")
    local joined=""
    if [[ ${#missing[@]} -gt 0 ]]; then joined="$(IFS=,; printf '%s' "${missing[*]}")"; fi
    printf '{"devices":[%s,%s,%s],"missing":[%s],"sdk":"%s","avdHome":"%s"}\n' \
        "$(device_json "$AVD_NAME" avd "$AVD_PROFILE" "$e2e")" \
        "$(device_json "$FOLD_AVD_NAME" avd "$FOLD_AVD_PROFILE" "$fold")" \
        "$(device_json "$DUO_NAME" simulator "$DUO_DEVICE_TYPE_NAME" "$duo")" \
        "$joined" "$(json_escape "$SDK")" "$(json_escape "$AVD_HOME")"
}

DRY_RUN=0
run() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf 'would run: %s\n' "$*" >&2
        return 0
    fi
    "$@"
}

# Sets key=value in an AVD's config.ini, replacing either spelling ("key=value" or "key = value").
set_ini() {
    local file="$1" key="$2" value="$3" tmp
    [[ "$DRY_RUN" == 1 ]] && { printf 'would set: %s=%s in %s\n' "$key" "$value" "$file" >&2; return 0; }
    tmp="$(mktemp "${file}.XXXXXX")"
    awk -v key="$key" -v value="$value" '
        BEGIN { done = 0 }
        { split($0, parts, "="); name = parts[1]; gsub(/[ \t]+$/, "", name) }
        name == key { print key "=" value; done = 1; next }
        { print }
        END { if (!done) print key "=" value }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

CREATE_ERROR=""

create_avd() {
    local name="$1" profile="$2" sdkmanager avdmanager setting
    sdkmanager="$(android_tool sdkmanager)"
    avdmanager="$(android_tool avdmanager)"
    if [[ -z "$sdkmanager" || -z "$avdmanager" ]]; then
        CREATE_ERROR="Android SDK Command-line Tools not found under $SDK/cmdline-tools. Install them in Android Studio (Settings, Android SDK, SDK Tools), or set ANDROID_HOME."
        return 4
    fi
    if [[ ! -d "$SDK/$SYSTEM_IMAGE_DIR" ]]; then
        err "Installing $SYSTEM_IMAGE"
        if ! run "$sdkmanager" --install "$SYSTEM_IMAGE" </dev/null >&2; then
            CREATE_ERROR="sdkmanager could not install $SYSTEM_IMAGE. Accept its licences first: $sdkmanager --licenses"
            return 1
        fi
    fi
    err "Creating $name ($profile)"
    if [[ "$DRY_RUN" == 1 ]]; then
        run "$avdmanager" create avd -n "$name" -k "$SYSTEM_IMAGE" -d "$profile"
    elif ! printf 'no\n' | "$avdmanager" create avd -n "$name" -k "$SYSTEM_IMAGE" -d "$profile" >&2; then
        CREATE_ERROR="avdmanager could not create $name."
        return 1
    fi
    local config="$AVD_HOME/$name.avd/config.ini"
    if [[ "$DRY_RUN" != 1 && ! -f "$config" ]]; then
        CREATE_ERROR="avdmanager created $name but $config is missing."
        return 1
    fi
    for setting in "${AVD_SETTINGS[@]}"; do
        set_ini "$config" "${setting%%=*}" "${setting#*=}"
    done
}

create_duo() {
    local type runtime udid
    if [[ ! -x "$XCRUN" || -z "$JQ" ]]; then
        CREATE_ERROR="xcrun or jq not found. Install Xcode and jq (brew install jq)."
        return 4
    fi
    type="$("$XCRUN" simctl list devicetypes -j | "$JQ" -r --arg name "$DUO_DEVICE_TYPE_NAME" \
        '[.devicetypes[] | select(.name == $name)] | .[0].identifier // empty')"
    if [[ -z "$type" ]]; then
        CREATE_ERROR="This Xcode has no $DUO_DEVICE_TYPE_NAME device type. Install Xcode 27 or later."
        return 1
    fi
    runtime="$("$XCRUN" simctl list runtimes available -j | "$JQ" -r --arg type "$type" \
        '[.runtimes[] | select(.platform == "iOS" and .isAvailable == true)
          | select([.supportedDeviceTypes[]?.identifier] | index($type))]
         | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')"
    if [[ -z "$runtime" ]]; then
        CREATE_ERROR="No installed iOS runtime supports the $DUO_DEVICE_TYPE_NAME. Install the newest one: xcodebuild -downloadPlatform iOS"
        return 1
    fi
    err "Creating \"$DUO_NAME\" ($type, $runtime)"
    if ! udid="$(run "$XCRUN" simctl create "$DUO_NAME" "$type" "$runtime")"; then
        CREATE_ERROR="simctl could not create \"$DUO_NAME\"."
        return 1
    fi
    [[ -n "$udid" ]] && err "Created $udid"
    return 0
}

cmd_create() {
    local created=() skipped=() failed=() name rc worst=0
    for name in "$AVD_NAME" "$FOLD_AVD_NAME" "$DUO_NAME"; do
        CREATE_ERROR=""
        case "$name" in
            "$DUO_NAME")
                if simulator_exists "$name"; then skipped+=("\"$name\""); continue; fi
                rc=0; create_duo || rc=$?
                ;;
            *)
                if avd_exists "$name"; then skipped+=("\"$(json_escape "$name")\""); continue; fi
                local profile="$AVD_PROFILE"
                [[ "$name" == "$FOLD_AVD_NAME" ]] && profile="$FOLD_AVD_PROFILE"
                rc=0; create_avd "$name" "$profile" || rc=$?
                ;;
        esac
        if [[ "$rc" -eq 0 ]]; then
            created+=("\"$(json_escape "$name")\"")
        else
            failed+=("{\"name\":\"$(json_escape "$name")\",\"error\":\"$(json_escape "$CREATE_ERROR")\"}")
            (( rc > worst )) && worst=$rc
        fi
    done
    local c="" s="" f=""
    if [[ ${#created[@]} -gt 0 ]]; then c="$(IFS=,; printf '%s' "${created[*]}")"; fi
    if [[ ${#skipped[@]} -gt 0 ]]; then s="$(IFS=,; printf '%s' "${skipped[*]}")"; fi
    if [[ ${#failed[@]} -gt 0 ]]; then f="$(IFS=,; printf '%s' "${failed[*]}")"; fi
    printf '{"dryRun":%s,"created":[%s],"existing":[%s],"failed":[%s]}\n' \
        "$([[ "$DRY_RUN" == 1 ]] && echo true || echo false)" "$c" "$s" "$f"
    return "$worst"
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) err "Unknown option: $arg"; usage >&2; exit 2 ;;
    esac
done

case "$command" in
    status) cmd_status ;;
    create) cmd_create ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
