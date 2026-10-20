#!/usr/bin/env bash
# Tests for the allow-list helpers in scripts/e2e-environment.sh with a stub offsider: run with `bash scripts/e2e-environment.test.sh`.
set -uo pipefail

ENVIRONMENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-environment.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/offsider-e2e-environment-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
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

# A stub offsider in a folder with a space, whose `devices status --json` prints the devices given.
mkdir -p "$WORK/my build"
STUB="$WORK/my build/offsider"
devices() {
    printf '#!/bin/bash\ncat <<JSON\n{"version":1,"devices":[%s]}\nJSON\n' "$1" > "$STUB"
    chmod +x "$STUB"
}
phone() { printf '{"platform":"android","id":"%s","name":"%s","apps":%s,"active":%s}' "$1" "$2" "$3" "${4:-true}"; }
iphone() { printf '{"platform":"ios","id":"%s","name":"%s","apps":%s,"active":true}' "$1" "$2" "$3"; }

pick() {
    OFFSIDER_BIN_PATH="$STUB" bash -c 'source "$1" >/dev/null 2>&1; allowed_device_for "$2" "$3"; echo "rc=$?"' _ "$ENVIRONMENT" "$@"
}

RN=com.mpalmes.offsider.playground.rn
devices "$(phone SERIAL01 "Test Pixel" "[\"$RN\"]")"
check "one phone pinned to the playground is picked" $'SERIAL01\tTest Pixel\nrc=0' "$(pick android "$RN")"

devices "$(phone SERIAL01 "Test Pixel" '["com.example.app"]')"
check "a phone allowed for another app is never picked" \
    $'Test Pixel is allowed, but its allowance does not pin com.mpalmes.offsider.playground.rn, so it is not picked.\nrc=1' "$(pick android "$RN")"

devices "$(phone SERIAL01 "Test Pixel" '[]')"
check "a phone allowed for any app is not picked" "rc=1" "$(pick android "$RN" | tail -1)"

devices "$(phone SERIAL01 "Test Pixel" "[\"$RN\"]"),$(phone SERIAL02 "Other Pixel" "[\"$RN\"]")"
check "two phones name both and pick neither" $'More than one Android phone is allowed (Test Pixel, Other Pixel), so none is picked.\nrc=1' "$(pick android "$RN")"

devices "$(phone SERIAL01 "Test Pixel" "[\"$RN\"]" false),$(iphone 00008140-000000000000ABCD "Test iPhone" '["com.mpalmes.offsider.playground"]')"
check "an expired phone and an iPhone leave no phone" $'No Android phone is allowed now.\nrc=1' "$(pick android "$RN")"
check "the iPhone pinned to the playground is picked" $'00008140-000000000000ABCD\tTest iPhone\nrc=0' "$(pick ios com.mpalmes.offsider.playground)"
check "the iOS playground pin does not count for the RN package" "rc=1" "$(pick ios "$RN" | tail -1)"

allow="$(OFFSIDER_BIN_PATH="$STUB" bash -c 'source "$1" >/dev/null 2>&1; print_device_allow "Test Pixel" "$2" 2>&1' _ "$ENVIRONMENT" "$RN")"
check "the allow command names the tested build by its absolute path" "1" "$(grep -cF "  $WORK/my\\ build/offsider devices add" <<<"$allow")"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
