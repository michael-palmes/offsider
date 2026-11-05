#!/usr/bin/env bash
# Tests for scripts/lib/adb.sh with a stub adb: run with `bash scripts/lib/adb.test.sh`.
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adb.sh"
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

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/offsider-adb-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME/Library/Caches/TemporaryItems/avd/running"
printf 'avd.id=Offsider_E2E_Fold\nport.serial=5556\navd.name=Offsider_E2E_Fold\n' > "$HOME/Library/Caches/TemporaryItems/avd/running/pid_4242.ini"
printf '#!/bin/bash\nexec sleep 30\n' > "$SANDBOX/frozen"
printf '#!/bin/bash\necho "$*"\nexit 3\n' > "$SANDBOX/answers"
chmod +x "$SANDBOX/frozen" "$SANDBOX/answers"

start=$(date +%s)
out="$(adb_limited 1 "$SANDBOX/frozen" -s emulator-5556 emu avd name 2>&1)"
code=$?
check "a read with no answer stops at the limit" "124 1" "$code $(( $(date +%s) - start < 10 ))"
check "it names the AVD and the restart in one line" \
    "Offsider_E2E_Fold (emulator-5556) did not answer in 1 s, so it may be frozen. Start it again: offsider shutdown emulator-5556 && offsider boot Offsider_E2E_Fold" "$out"

out="$(ADB_FIX_OFFSIDER=/repo/.build/debug/offsider adb_limited 1 "$SANDBOX/frozen" -s emulator-5556 shell true 2>&1)"
check "the restart names the offsider it is given" "true" "$([[ "$out" == *"/repo/.build/debug/offsider shutdown emulator-5556 && /repo/.build/debug/offsider boot"* ]] && echo true)"

out="$(adb_limited 1 "$SANDBOX/frozen" -s emulator-5598 shell true 2>&1)"
check "an emulator with no pid file gets no guessed AVD" "emulator-5598 did not answer in 1 s. Check it is running, unlocked and connected, then run this again." "$out"

out="$(adb_limited 5 "$SANDBOX/answers" -s emulator-5556 shell getprop 2>&1)"
code=$?
check "a read that answers keeps its output and its status" "3 -s emulator-5556 shell getprop" "$code $out"

printf '#!/bin/bash\necho noise >&2\nexec sleep 30\n' > "$SANDBOX/noisy"
chmod +x "$SANDBOX/noisy"
out="$(ADB_QUIET=1 adb_limited 1 "$SANDBOX/noisy" -s emulator-5556 emu avd name 2>&1)"
check "quiet drops adb's own stderr but keeps the fix" "Offsider_E2E_Fold (emulator-5556) did not answer in 1 s, so it may be frozen. Start it again: offsider shutdown emulator-5556 && offsider boot Offsider_E2E_Fold" "$out"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
