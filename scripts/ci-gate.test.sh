#!/usr/bin/env bash
# Tests for scripts/ci-gate.sh with sample needs and workflows: run with `bash scripts/ci-gate.test.sh`.
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-gate.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/offsider-ci-gate-test.XXXXXX")"
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

# needs <changes result> <macos output> <unit-tests> <release-rehearsal> <lint>
needs() {
    local outputs=""
    [[ -n "$2" ]] && outputs="\"macos\":\"$2\""
    printf '{"changes":{"result":"%s","outputs":{%s}},"lint":{"result":"%s","outputs":{}},"unit-tests":{"result":"%s","outputs":{}},"release-rehearsal":{"result":"%s","outputs":{}}}' \
        "$1" "$outputs" "$5" "$3" "$4"
}

# gate <needs json> prints the exit status, then every line the gate printed.
gate() {
    local output status
    output="$(NEEDS="$1" bash "$GATE" --skippable unit-tests --skippable release-rehearsal 2>&1)"
    status=$?
    printf '%s %s' "$status" "$output"
}

check "every job green passes" "0 " "$(gate "$(needs success true success success success)")"
check "a docs-only change may skip the macOS jobs" "0 " "$(gate "$(needs success false skipped skipped success)")"
check "a code change that skipped the macOS jobs fails" \
    "1 ::error::unit-tests was skipped although the change needs it"$'\n'"::error::release-rehearsal was skipped although the change needs it" \
    "$(gate "$(needs success true skipped skipped success)")"
check "a failed changes job fails, even with the macOS jobs skipped" 1 "$(gate "$(needs failure "" skipped skipped success)" | head -c 1)"
check "a failed unit test job fails" "1 ::error::unit-tests: failure" "$(gate "$(needs success true failure success success)")"
check "a cancelled rehearsal fails" "1 ::error::release-rehearsal: cancelled" "$(gate "$(needs success true success cancelled success)")"
check "a skip of a job that is not skippable fails, even for docs" "1 ::error::lint: skipped" "$(gate "$(needs success false skipped skipped skipped)")"
check "a changes output other than false never excuses a skip" 1 "$(gate "$(needs success maybe skipped skipped success)" | head -c 1)"
check "an empty needs list fails" "1 ::error::NEEDS lists no jobs" "$(gate '{}')"
check "unset needs fail" "1 ::error::NEEDS is empty, so there are no job results to check" "$(gate '')"
check "needs that are not JSON fail" "1 ::error::NEEDS is not the gate's needs as JSON" "$(gate 'not json')"
check "an unknown option is a usage error" 2 "$(bash "$GATE" --skip-all > /dev/null 2>&1; echo $?)"

cat > "$WORK/gated.yml" <<'YAML'
on: pull_request
jobs:
  changes: {runs-on: ubuntu-24.04, steps: [{run: "true"}]}
  lint: {runs-on: ubuntu-24.04, steps: [{run: "true"}]}
  asan: {runs-on: ubuntu-24.04, steps: [{run: "true"}]}
  gate: {needs: [changes, lint], runs-on: ubuntu-24.04, steps: [{run: "true"}]}
YAML
cat > "$WORK/ungated.yml" <<'YAML'
on: pull_request
jobs:
  changes: {runs-on: ubuntu-24.04, steps: [{run: "true"}]}
  lint: {runs-on: ubuntu-24.04, steps: [{run: "true"}]}
  docs-links: {runs-on: ubuntu-24.04, steps: [{run: "true"}]}
  gate: {needs: changes, runs-on: ubuntu-24.04, steps: [{run: "true"}]}
YAML

check_needs() {
    local output status
    output="$(bash "$GATE" --check-needs "$@" 2>&1)"
    status=$?
    printf '%s %s' "$status" "$output"
}

check "a workflow whose jobs all gate passes" "0 Every job in $WORK/gated.yml gates merges through gate" \
    "$(check_needs "$WORK/gated.yml" gate asan)"
check "an exempt job left off the needs still fails when it is not named exempt" \
    "1 ::error::asan is not among the needs of gate, so it never blocks a merge" "$(check_needs "$WORK/gated.yml" gate)"
check "a job left off the needs is named, with needs given as one string" \
    "1 ::error::lint is not among the needs of gate, so it never blocks a merge"$'\n'"::error::docs-links is not among the needs of gate, so it never blocks a merge" \
    "$(check_needs "$WORK/ungated.yml" gate)"
check "a gate job the workflow lacks fails" 1 "$(check_needs "$WORK/gated.yml" ci-passed | head -c 1)"
check "a missing workflow fails" "1 ::error::$WORK/none.yml does not exist" "$(check_needs "$WORK/none.yml" gate)"
check "--check-needs without the gate job is a usage error" 2 "$(bash "$GATE" --check-needs "$WORK/gated.yml" > /dev/null 2>&1; echo $?)"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
