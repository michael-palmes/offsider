#!/usr/bin/env bash
# Tests for scripts/failed-tests.sh: run with `bash scripts/failed-tests.test.sh`.
set -uo pipefail

FAILED_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/failed-tests.sh"
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

# Writes the report's lines to a file and prints the script's output, then its status; ISSUES is the run's own count.
read_report() {
    printf '%s\n' "$@" > "$WORK/report.xml"
    local output status=0
    output="$(bash "$FAILED_TESTS" "$WORK/report.xml" "${ISSUES:-0}" 2>&1)" || status=$?
    printf '%s[%s]' "$output" "$status"
}

header() { printf '<testsuite name="TestResults" errors="0" tests="9" failures="%s" skipped="0" time="1.0">' "$1"; }
passing='<testcase classname="OffsiderTests.Passing" name="fine()" time="0.1" />'

check "a report with no failures prints nothing" "[0]" \
    "$(read_report "$(header 0)" "$passing" '</testsuite>')"

check "each failed test prints as a pattern with its dots and brackets escaped" \
    'OffsiderTests\.Lock/release\(\)
OffsiderTests\.Paths/sensitive\(path:\)[0]' \
    "$(ISSUES=2 read_report "$(header 2)" "$passing" \
        '<testcase classname="OffsiderTests.Lock" name="release()" time="1">' \
        '<failure message="Expectation failed: held &lt; 1 (error)" />' \
        '</testcase>' \
        '<testcase classname="OffsiderTests.Paths" name="sensitive(path:)" time="1">' \
        '<failure message="Expectation failed" />' \
        '</testcase>' '</testsuite>')"

check "a test with several failures prints once" 'OffsiderTests\.Lock/release\(\)[0]' \
    "$(ISSUES=2 read_report "$(header 2)" \
        '<testcase classname="OffsiderTests.Lock" name="release()" time="1">' \
        '<failure message="one" />' '<failure message="two" />' \
        '</testcase>' '</testsuite>')"

check "a count above what the report names is not trusted" "[1]" \
    "$(ISSUES=3 read_report "$(header 3)" \
        '<testcase classname="OffsiderTests.Lock" name="release()" time="1">' \
        '<failure message="one" />' \
        '</testcase>' '</testsuite>')"

check "an issue the report leaves out, outside any test, is not trusted" "[1]" \
    "$(ISSUES=2 read_report "$(header 1)" \
        '<testcase classname="OffsiderTests.Lock" name="release()" time="1">' \
        '<failure message="one" />' \
        '</testcase>' '</testsuite>')"

check "a run count that is not a number is not trusted" "[1]" \
    "$(ISSUES=many read_report "$(header 0)" '</testsuite>')"

check "a failure outside a test is not trusted" "[1]" \
    "$(ISSUES=1 read_report "$(header 1)" '<failure message="stray" />' '</testsuite>')"

check "a failure after a self-closed test is not pinned on that test" "[1]" \
    "$(ISSUES=1 read_report "$(header 1)" "$passing" '<failure message="stray" />' '</testsuite>')"

check "a failure after its test closed is not trusted" "[1]" \
    "$(ISSUES=1 read_report "$(header 1)" \
        '<testcase classname="OffsiderTests.Lock" name="release()" time="1">' \
        '</testcase>' '<failure message="stray" />' '</testsuite>')"

check "a name that could carry regex or shell text is not trusted" "[1]" \
    "$(ISSUES=1 read_report "$(header 1)" \
        '<testcase classname="OffsiderTests.Lock" name="release().*|$(id)" time="1">' \
        '<failure message="one" />' \
        '</testcase>' '</testsuite>')"

missing_status=0
bash "$FAILED_TESTS" "$WORK/no-such-report.xml" 0 > /dev/null 2>&1 || missing_status=$?
check "a missing report is not trusted" "1" "$missing_status"

no_argument_status=0
bash "$FAILED_TESTS" > /dev/null 2>&1 || no_argument_status=$?
check "no report named is a usage error" "2" "$no_argument_status"

printf 'failed-tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
