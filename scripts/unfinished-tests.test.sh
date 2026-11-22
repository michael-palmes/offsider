#!/usr/bin/env bash
# Tests for scripts/unfinished-tests.sh: run with `bash scripts/unfinished-tests.test.sh`.
set -uo pipefail

UNFINISHED_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unfinished-tests.sh"
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

# Writes the stream's lines to a file and prints the script's output, then its status.
read_stream() {
    printf '%s\n' "$@" > "$WORK/events.jsonl"
    local output status=0
    output="$(bash "$UNFINISHED_TESTS" "$WORK/events.jsonl" 2>&1)" || status=$?
    printf '%s[%s]' "$output" "$status"
}

planned() { printf '{"kind":"test","payload":{"id":"%s","kind":"%s"},"version":0}' "$1" "${2:-function}"; }
event() { printf '{"kind":"event","payload":{"kind":"%s","testID":"%s"},"version":0}' "$1" "$2"; }
issue() { printf '{"kind":"event","payload":{"kind":"issueRecorded","testID":"%s","issue":{"isKnown":%s}},"version":0}' "$1" "$2"; }
started='{"kind":"event","payload":{"kind":"runStarted"},"version":0}'
lock='OffsiderTests.Lock/release()/LockTests.swift:12:6'
paths='OffsiderTests.Paths/sensitive(path:)/PathTests.swift:40:6'
quick='OffsiderTests.Lock/quick()/LockTests.swift:20:6'

check "a run where every test passed or skipped prints nothing" "[0]" \
    "$(read_stream "$(planned "$lock")" "$(planned "$quick")" "$started" \
        "$(event testEnded "$lock")" "$(event testSkipped "$quick")")"

check "tests still running or never started print as patterns with dots and brackets escaped" \
    'OffsiderTests\.Lock/release\(\)
OffsiderTests\.Paths/sensitive\(path:\)[0]' \
    "$(read_stream "$(planned OffsiderTests.Lock suite)" "$(planned "$lock")" "$(planned "$quick")" "$(planned "$paths")" \
        "$started" "$(event testStarted "$lock")" "$(event testEnded "$quick")")"

check "a test that ended with an issue runs again" 'OffsiderTests\.Lock/release\(\)[0]' \
    "$(read_stream "$(planned "$lock")" "$started" "$(issue "$lock" false)" "$(event testEnded "$lock")")"

check "a known issue is not a failure" "[0]" \
    "$(read_stream "$(planned "$lock")" "$started" "$(issue "$lock" true)" "$(event testEnded "$lock")")"

check "a last line cut short by the stop is dropped" 'OffsiderTests\.Lock/release\(\)[0]' \
    "$(read_stream "$(planned "$lock")" "$(planned "$quick")" "$started" "$(event testEnded "$quick")" \
        '{"kind":"event","payload":{"kind":"testEn')"

check "a stream with no test plan is not trusted" "[1]" \
    "$(read_stream "$started" "$(event testStarted "$lock")")"

check "a run that never started is not trusted" "[1]" "$(read_stream "$(planned "$lock")")"

check "an issue outside any test is not trusted" "[1]" \
    "$(read_stream "$(planned "$lock")" "$started" \
        '{"kind":"event","payload":{"kind":"issueRecorded","issue":{"isKnown":false}},"version":0}')"

check "a name that is not a plain Swift identifier is not trusted" "[1]" \
    "$(read_stream "$(planned 'OffsiderTests.Lock/`a raw name`()/LockTests.swift:3:6')" "$started")"

check "a stream it cannot trust prints no patterns at all, not the ones before the bad name" "[1]" \
    "$(read_stream "$(planned "$lock")" "$(planned 'OffsiderTests.Lock/`a raw name`()/LockTests.swift:3:6')" "$started")"

check "a missing stream is not trusted" "[1]" \
    "$(output="$(bash "$UNFINISHED_TESTS" "$WORK/missing.jsonl" 2>&1)"; printf '%s[%s]' "$output" "$?")"

check "no argument prints usage and exits 2" "2" "$(bash "$UNFINISHED_TESTS" > /dev/null 2>&1; echo $?)"

printf 'unfinished-tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
