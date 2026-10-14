#!/usr/bin/env bash
# Tests for scripts/e2e-devices-core.sh with sdkmanager, avdmanager and xcrun stubbed: run with `bash scripts/e2e-devices-core.test.sh`.
set -uo pipefail

CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-devices-core.sh"
PASSED=0
FAILED=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$name" "$expected" "$actual"
    fi
}

# A fresh sandbox per case: an SDK with stub tools, an empty AVD home and a stub xcrun, each logging its arguments.
setup() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/offsider-e2e-devices-test.XXXXXX")"
    export ANDROID_HOME="$SANDBOX/sdk" ANDROID_AVD_HOME="$SANDBOX/avd" E2E_DEVICES_XCRUN="$SANDBOX/xcrun"
    unset ANDROID_SDK_ROOT ANDROID_USER_HOME
    mkdir -p "$ANDROID_HOME/cmdline-tools/latest/bin" "$ANDROID_AVD_HOME"
    CALLS="$SANDBOX/calls.log"
    : > "$CALLS"
    cat > "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" <<EOF
#!/bin/bash
echo "sdkmanager \$*" >> "$CALLS"
mkdir -p "$ANDROID_HOME/system-images/android-36/google_apis_ps16k/arm64-v8a"
EOF
    cat > "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" <<EOF
#!/bin/bash
echo "avdmanager \$* stdin=\$(cat)" >> "$CALLS"
name=""; while [ \$# -gt 0 ]; do [ "\$1" = -n ] && name="\$2"; shift; done
mkdir -p "$ANDROID_AVD_HOME/\$name.avd"
printf 'path=x\n' > "$ANDROID_AVD_HOME/\$name.ini"
printf 'hw.keyboard = no\nhw.ramSize=2048\nhw.device.name=x\n' > "$ANDROID_AVD_HOME/\$name.avd/config.ini"
EOF
    cat > "$E2E_DEVICES_XCRUN" <<EOF
#!/bin/bash
echo "xcrun \$*" >> "$CALLS"
case "\$*" in
  "simctl list devices -j") cat "$SANDBOX/devices.json" ;;
  "simctl list devicetypes -j") echo '{"devicetypes":[{"name":"iPhone 17 Pro","identifier":"type.pro"},{"name":"iPhone Duo","identifier":"type.duo"}]}' ;;
  "simctl list runtimes available -j") echo '{"runtimes":[
     {"platform":"iOS","isAvailable":true,"version":"27.1","identifier":"rt.27-1","supportedDeviceTypes":[{"identifier":"type.duo"}]},
     {"platform":"iOS","isAvailable":true,"version":"27.10","identifier":"rt.27-10","supportedDeviceTypes":[{"identifier":"type.duo"}]},
     {"platform":"iOS","isAvailable":true,"version":"28.0","identifier":"rt.28-0","supportedDeviceTypes":[{"identifier":"type.pro"}]}]}' ;;
  "simctl create"*) echo "NEW-UDID" ;;
  *) exit 1 ;;
esac
EOF
    chmod +x "$ANDROID_HOME/cmdline-tools/latest/bin/"* "$E2E_DEVICES_XCRUN"
    echo '{"devices":{"rt.27-1":[{"name":"Someone else","udid":"A"}]}}' > "$SANDBOX/devices.json"
}

teardown() { rm -rf "$SANDBOX"; }

setup
out="$("$CORE" status)"
check "status prints valid JSON" "0" "$(jq -e . <<<"$out" >/dev/null; echo $?)"
check "status lists the three devices as missing" '["Offsider_E2E","Offsider_E2E_Fold","Offsider Duo"]' "$(jq -c .missing <<<"$out")"
check "status runs no Android tool" "" "$(grep -v '^xcrun' "$CALLS")"
teardown

setup
mkdir -p "$ANDROID_HOME/system-images/android-36/google_apis_ps16k/arm64-v8a"
printf 'path=x\n' > "$ANDROID_AVD_HOME/Offsider_E2E.ini"
echo '{"devices":{"rt.27-1":[{"name":"Offsider Duo","udid":"B"}]}}' > "$SANDBOX/devices.json"
out="$("$CORE" create 2>/dev/null)"
check "create reports existing devices" '["Offsider_E2E","Offsider Duo"]' "$(jq -c .existing <<<"$out")"
check "create makes only the missing fold AVD" '["Offsider_E2E_Fold"]' "$(jq -c .created <<<"$out")"
check "the fold AVD gets the foldable profile" "1" "$(grep -c 'avdmanager create avd -n Offsider_E2E_Fold -k system-images;android-36;google_apis_ps16k;arm64-v8a -d pixel_9_pro_fold stdin=no' "$CALLS")"
check "an installed image is not installed again" "0" "$(grep -c '^sdkmanager' "$CALLS")"
check "no simulator is created when it exists" "0" "$(grep -c 'simctl create' "$CALLS")"
check "the AVD gets a hardware keyboard" "hw.keyboard=yes" "$(grep '^hw.keyboard' "$ANDROID_AVD_HOME/Offsider_E2E_Fold.avd/config.ini")"
check "the AVD gets 6 GB of RAM" "hw.ramSize=6144" "$(grep '^hw.ramSize' "$ANDROID_AVD_HOME/Offsider_E2E_Fold.avd/config.ini")"
check "the AVD gets a 6 GB data partition" "disk.dataPartition.size=6G" "$(grep '^disk.dataPartition' "$ANDROID_AVD_HOME/Offsider_E2E_Fold.avd/config.ini")"
check "other settings are kept" "hw.device.name=x" "$(grep '^hw.device.name' "$ANDROID_AVD_HOME/Offsider_E2E_Fold.avd/config.ini")"
teardown

setup
out="$("$CORE" create 2>/dev/null)"
check "create from nothing makes all three" '["Offsider_E2E","Offsider_E2E_Fold","Offsider Duo"]' "$(jq -c .created <<<"$out")"
check "the missing image is installed once" "1" "$(grep -c 'sdkmanager --install system-images;android-36;google_apis_ps16k;arm64-v8a' "$CALLS")"
check "the phone AVD gets the pixel_9 profile" "1" "$(grep -c 'create avd -n Offsider_E2E -k .* -d pixel_9 ' "$CALLS")"
check "the Duo goes on the newest runtime that supports it" "1" "$(grep -c 'simctl create Offsider Duo type.duo rt.27-10' "$CALLS")"
check "nothing is booted" "0" "$(grep -ciE 'boot|emulator' "$CALLS")"
teardown

setup
out="$("$CORE" create --dry-run 2>/dev/null)"
check "a dry run creates nothing" "0" "$(grep -c 'create' "$CALLS")"
check "a dry run says it is one" "true" "$(jq .dryRun <<<"$out")"
teardown

setup
rm -rf "$ANDROID_HOME/cmdline-tools"
"$CORE" create > "$SANDBOX/out.json" 2>/dev/null
rc=$?
check "missing Android tools exit 4" "4" "$rc"
check "missing Android tools name the fix" "true" "$(jq '.failed[0].error | contains("Command-line Tools")' "$SANDBOX/out.json")"
check "the simulator is still created" '["Offsider Duo"]' "$(jq -c .created "$SANDBOX/out.json")"
teardown

setup
"$CORE" frobnicate >/dev/null 2>&1
check "an unknown command exits 2" "2" "$?"
check "--help exits 0" "0" "$("$CORE" --help >/dev/null 2>&1; echo $?)"
teardown

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
