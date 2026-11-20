#!/usr/bin/env bash
# Tests for scripts/lib/e2e-host.sh with a stub sysctl, sleep and reports folder: run with `bash scripts/lib/e2e-host.test.sh`.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
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

export OFFSIDER_OUTPUT=agent
# shellcheck source=/dev/null
source "$REPO/scripts/e2e-environment.sh"
# shellcheck source=/dev/null
source "$REPO/scripts/lib/e2e-host.sh"

# A Mac with CORES cores whose 1-minute load reads each of LOADS in turn, holding the last; sleep only counts.
# The reads run in command substitutions, so their count lives in a file.
CORES=18
LOADS=()
SLEPT=0
sysctl() {
    case "$2" in
        hw.logicalcpu) printf '%s\n' "$CORES" ;;
        vm.loadavg)
            local reads i
            reads="$(cat "$WORK/reads")"
            i=$(( reads < ${#LOADS[@]} ? reads : ${#LOADS[@]} - 1 ))
            printf '%s' $(( reads + 1 )) > "$WORK/reads"
            printf '{ %s 9.00 8.00 }\n' "${LOADS[$i]}"
            ;;
    esac
}
sleep() { SLEPT=$(( SLEPT + $1 )); }

wait_for() {
    LOADS=("$@") SLEPT=0 E2E_BUSY_MESSAGE=""
    printf 0 > "$WORK/reads"
    if e2e_wait_for_quiet_mac "Test Phone" 60 2>"$WORK/stderr" >"$WORK/stdout"; then RESULT=ok; else RESULT=refused; fi
}

wait_for 36.00
check "a load at twice the cores boots at once" "ok slept 0" "$RESULT slept $SLEPT"
check "a quiet Mac prints nothing" "" "$(cat "$WORK/stderr" "$WORK/stdout")"

wait_for 52.40 40.00 30.10
check "a busy Mac waits on the clock until the load falls" "ok slept 30" "$RESULT slept $SLEPT"
check "the wait is one line saying why" "Waiting for a quiet Mac to boot Test Phone: load 52.40, boots below 36" "$(cat "$WORK/stderr")"

wait_for 52.40
check "a Mac that stays busy is refused at the limit" "refused slept 60" "$RESULT slept $SLEPT"
check "the refusal names the load, the ceiling and the cores" \
    "The Mac stayed busy for 1m 00s (load 52.40; boots wait for 36, twice its 18 cores), so Test Phone was not booted. Let other builds and simulators finish, then run again." \
    "$E2E_BUSY_MESSAGE"

LOADS=(36.00); printf 0 > "$WORK/reads"
check "a load at the ceiling is quiet" "quiet" "$(e2e_mac_is_quiet && echo quiet || echo busy)"
LOADS=(36.01); printf 0 > "$WORK/reads"
check "a load over it is not" "busy" "$(e2e_mac_is_quiet && echo quiet || echo busy)"

CORES=8
wait_for 17
check "the ceiling follows the cores" "refused" "$RESULT"
CORES=garbage
wait_for 15.9
check "unreadable cores count as 8" "ok slept 0" "$RESULT slept $SLEPT"
CORES=18

# A reports folder: a simulator report is a JSON header line, then the body.
UDID=00000000-0000-0000-0000-000000000001
OTHER=11111111-2222-3333-4444-555555555555
REPORTS="$WORK/reports"
mkdir -p "$REPORTS"
COUNT=0
report() {
    local process="$1" udid="${2:-$UDID}" bundle="${3:-com.apple.$1}"
    COUNT=$(( COUNT + 1 ))
    printf '{"app_name":"%s","bug_type":"309","bundleID":"%s"}\n{\n  "procName" : "%s",\n  "coalitionName" : "com.apple.CoreSimulator.SimDevice.%s"\n}\n' \
        "$process" "$bundle" "$process" "$udid" > "$REPORTS/$process-$COUNT.ips"
}

for _ in 1 2 3 4; do report SpringBoard; done
report PosterBoard
for _ in 1 2 3 4 5; do report routined "$OTHER"; done
check "four crashes of one process are not a loop" "" "$(e2e_crash_loop "$REPORTS" "$UDID")"
report SpringBoard
check "five are, and another simulator's never count" "SpringBoard crashed 5 times in the last 10 minutes" "$(e2e_crash_loop "$REPORTS" "$UDID")"
check "a missing folder has no loop" "" "$(e2e_crash_loop "$WORK/none" "$UDID")"

refusal="$(e2e_refuse_crash_loop "$REPORTS" "$UDID" "Test Phone" Booted 2>&1; echo "rc=$?")"
check "a booted simulator in a loop is refused with a quiet boot as the fix" \
    "Error: Test Phone is in a crash loop: shut it down, wait for the Mac to be quiet, then run again to boot it once." "$(head -1 <<<"$refusal")"
check "the shutdown is the agent's Try line" "1" "$(grep -cx "Try: xcrun simctl shutdown $UDID" <<<"$refusal")"
check "an agent never gets the erase as a Try line" "0" "$(grep -c '^Try: .*erase' <<<"$refusal")"
check "an agent is told never to erase it and to ask the user" "1" "$(grep -c '^Never erase it yourself\. If it loops again on a quiet Mac, ask the user' <<<"$refusal")"
check "the erase sits indented for the user, after that" "  xcrun simctl erase $UDID" "$(grep -A1 '^Never erase it yourself' <<<"$refusal" | tail -1)"
check "a loop refuses the run" "rc=1" "$(tail -1 <<<"$refusal")"
shutdown_refusal="$(e2e_refuse_crash_loop "$REPORTS" "$UDID" "Test Phone" Shutdown 2>&1)"
check "a shut-down simulator gets no shutdown to try" "0" "$(grep -c '^Try:' <<<"$shutdown_refusal")"
check "no loop, no refusal" "rc=0" "$(e2e_refuse_crash_loop "$REPORTS" 22222222-0000-0000-0000-000000000000 "Quiet Phone" Booted 2>&1; echo "rc=$?")"

rm -f "$REPORTS"/*.ips
report SpringBoard
touch -t 202601010000 "$REPORTS"/*.ips
MARKER="$WORK/marker"
touch -t 202601010001 "$MARKER"
e2e_run_crashes "$REPORTS" "$UDID" "$MARKER" com.mpalmes.offsider.playground
check "reports from before the run do not count" "0||" "$E2E_CRASHES_TOTAL|$E2E_CRASHES_DETAIL|$E2E_CRASHES_FATAL"

report routined
report routined
report tccd "$OTHER"
e2e_run_crashes "$REPORTS" "$UDID" "$MARKER" com.mpalmes.offsider.playground
check "a daemon's crashes are counted but do not fail the run" "2|routined 2|" "$E2E_CRASHES_TOTAL|$E2E_CRASHES_DETAIL|$E2E_CRASHES_FATAL"

report SpringBoard
report OffsiderPlayground "$UDID" com.mpalmes.offsider.playground
report OtherApp "$UDID" com.example.other
e2e_run_crashes "$REPORTS" "$UDID" "$MARKER" com.mpalmes.offsider.playground
check "SpringBoard and the playground fail the run; another app only counts" \
    "5|routined 2, OffsiderPlayground 1, OtherApp 1, SpringBoard 1|OffsiderPlayground, SpringBoard" \
    "$E2E_CRASHES_TOTAL|$E2E_CRASHES_DETAIL|$E2E_CRASHES_FATAL"

e2e_run_crashes "$REPORTS" "$UDID" "$WORK/no-marker" com.mpalmes.offsider.playground
check "no marker, no count" "0" "$E2E_CRASHES_TOTAL"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
