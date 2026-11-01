#!/usr/bin/env bash
# Tests for scripts/lib/unit-tests.sh: run with `bash scripts/lib/unit-tests.test.sh`.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
PASSED=0
FAILED=0
VERBOSE=false

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$name" "$expected" "$actual"
    fi
}

# shellcheck source=/dev/null
source "$REPO/scripts/lib/unit-tests.sh"

plan_suites() { :; }
ui_heading() { :; }
ui_kv() { :; }
ui_elapsed() { printf '%ss' "$1"; }
warn() { printf 'warn %s\n' "$1" >> "$WORK/events"; }
record_suite() {
    RESULT_NAMES+=("$1")
    RESULT_STATES+=("$2")
    RESULT_TIMES+=("$3")
}

run_swift_suite() {
    local name="$1" capture="$2" status=0
    shift 2
    if [[ -n "$capture" ]]; then
        run_selected_swift test --no-parallel "$@" > "$capture" 2>&1 || status=$?
    else
        run_selected_swift test --no-parallel "$@" > /dev/null 2>&1 || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then record_suite "$name" ok "1s"; else record_suite "$name" fail "1s"; fi
    return "$status"
}

# A fake swift test: the parallel run plays $PARALLEL, a rerun of named tests $RETRY and a full serial run $SERIAL.
run_selected_swift() {
    shift
    local arg previous="" report=""
    for arg in "$@"; do
        if [[ "$previous" == --xunit-output ]]; then report="$arg"; fi
        previous="$arg"
    done
    if [[ -n "$report" ]]; then
        printf 'parallel\n' >> "$WORK/events"
        case "$PARALLEL" in
            pass) echo "Test run with 2 tests in 1 suite passed after 1.0 seconds." ;;
            stall) sleep 30 ;;
            no-report) echo "the test host died"; return 1 ;;
            one-failed)
                failed_report 1 > "$report"
                echo "Test run with 2 tests in 1 suite failed after 1.0 seconds with 1 issue."
                return 1
                ;;
            one-failed-and-unnamed-issue)
                failed_report 1 > "$report"
                echo "Test run with 2 tests in 1 suite failed after 1.0 seconds with 2 issues."
                return 1
                ;;
            too-many)
                failed_report 101 > "$report"
                echo "Test run with 101 tests in 1 suite failed after 1.0 seconds with 101 issues."
                return 1
                ;;
        esac
        return 0
    fi
    if [[ " $* " == *" --filter "* ]]; then
        printf 'retry\n' >> "$WORK/events"
        case "$RETRY" in
            pass) echo "Test run with 1 test in 1 suite passed after 1.0 seconds." ;;
            fail) echo "Test run with 1 test in 1 suite failed after 1.0 seconds with 1 issue."; return 1 ;;
            matched-none) echo "Test run with 0 tests in 0 suites passed after 0.0 seconds." ;;
        esac
        return 0
    fi
    printf 'serial\n' >> "$WORK/events"
    [[ "$SERIAL" == pass ]]
}

failed_report() {
    local total="$1" i=1
    printf '<testsuite name="TestResults" errors="0" tests="2" failures="%s" skipped="0" time="1.0">\n' "$total"
    while (( i <= total )); do
        printf '<testcase classname="OffsiderTests.Lock" name="release%s()" time="1">\n<failure message="m" />\n</testcase>\n' "$i"
        i=$((i + 1))
    done
    printf '</testsuite>\n'
}

# Runs one scenario and prints its status, then what ran, then the results it recorded.
scenario() {
    PARALLEL="$1" RETRY="${2:-pass}" SERIAL="${3:-pass}"
    RESULT_NAMES=() RESULT_STATES=() RESULT_TIMES=()
    : > "$WORK/events"
    local status=0
    run_unit_tests_parallel > /dev/null 2>&1 || status=$?
    cleanup_unit_tests
    printf '%s %s [%s]' "$status" "$(grep -vE '^warn' "$WORK/events" | tr '\n' ' ')" "${RESULT_STATES[*]-}"
}

check "a clean parallel run is the whole job" "0 parallel  [ok]" "$(scenario pass)"
check "a failed test that passes alone passes the run" "0 parallel retry  [ok]" "$(scenario one-failed pass)"
check "a failed test that fails alone fails the run" "1 parallel retry  [fail]" "$(scenario one-failed fail)"
check "a rerun that matches no tests is never a pass: everything runs serially" "0 parallel retry serial  [ok]" \
    "$(scenario one-failed matched-none pass)"
check "that serial run can still fail" "1 parallel retry serial  [fail]" "$(scenario one-failed matched-none fail)"
check "an issue the report does not name runs everything serially" "1 parallel serial  [fail]" \
    "$(scenario one-failed-and-unnamed-issue pass fail)"
check "a host that dies with no report runs everything serially" "1 parallel serial  [fail]" \
    "$(scenario no-report pass fail)"
check "too many failures fail without a retry" "1 parallel  [fail]" "$(scenario too-many)"

UNIT_PARALLEL_LIMIT=1
check "a stalled run is stopped and everything runs serially" "0 parallel serial  [ok]" "$(scenario stall)"
UNIT_PARALLEL_LIMIT=360

scenario one-failed pass > /dev/null
check "a test that passed only alone is named for the person reading" "1" \
    "$(grep -c 'warn Passed only when run alone: OffsiderTests.Lock/release1()' "$WORK/events")"
check "a run leaves no files behind" "" "$(find "$WORK" -name 'offsider-unit-tests.*' -not -path "$WORK/events")"

github_notice="$(
    GITHUB_ACTIONS=true PARALLEL=one-failed RETRY=pass SERIAL=pass
    export GITHUB_ACTIONS
    run_unit_tests_parallel 2>/dev/null | grep '^::warning'
    cleanup_unit_tests
)"
check "GitHub gets an annotation naming the test" "::warning title=Passed only alone::OffsiderTests.Lock/release1()" "$github_notice"

printf 'unit-tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
