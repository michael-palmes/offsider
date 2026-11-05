#!/usr/bin/env bash
# The unit test run test-runner.sh sources: parallel for speed, with a test that fails there held to the bar of a serial run.

# Seconds a parallel run gets, and the most failed tests it may run again alone.
UNIT_PARALLEL_LIMIT=360
UNIT_RETRY_MOST=100
# The process group of the limited swift test running now, and the folder of this run's report and captures.
SWIFT_GROUP=""
UNIT_TEMP=""

# Stops what a run left behind; test-runner.sh calls this as it exits.
cleanup_unit_tests() {
    if [[ -n "$SWIFT_GROUP" ]]; then
        kill -TERM -- "-$SWIFT_GROUP" 2>/dev/null || true
    fi
    if [[ -n "$UNIT_TEMP" ]]; then
        rm -rf "$UNIT_TEMP"
    fi
}

# Runs swift test in a process group of its own, its output also in the capture file; returns its status, or 124 at the limit.
run_swift_with_limit() {
    local limit="$1" capture="$2" started=$SECONDS status=0
    shift 2
    set -m
    ( run_selected_swift test "$@" < /dev/null 2>&1 | tee "$capture"; exit "${PIPESTATUS[0]}" ) &
    SWIFT_GROUP=$!
    set +m
    while kill -0 "$SWIFT_GROUP" 2>/dev/null; do
        if (( SECONDS - started >= limit )); then
            kill -TERM -- "-$SWIFT_GROUP" 2>/dev/null || true
            sleep 5
            kill -KILL -- "-$SWIFT_GROUP" 2>/dev/null || true
            wait "$SWIFT_GROUP" 2>/dev/null || true
            SWIFT_GROUP=""
            return 124
        fi
        sleep 1
    done
    wait "$SWIFT_GROUP" || status=$?
    SWIFT_GROUP=""
    return "$status"
}

# Every test, one at a time, replacing any row the attempt before it left.
run_unit_tests_serially() {
    # shellcheck disable=SC2034 # test-runner.sh reads these for its results.
    RESULT_NAMES=() RESULT_STATES=() RESULT_TIMES=()
    run_swift_suite "Unit tests" "" --disable-xctest
}

# A test that fails in parallel must pass alone; a stall or a failure the report cannot name runs everything serially.
run_unit_tests_parallel() {
    local report capture retry names count filter issues status=0 started=$SECONDS
    local args=(--skip-build --disable-xctest) filters=()
    [[ "$VERBOSE" == true ]] && args+=(--verbose)
    UNIT_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/offsider-unit-tests.XXXXXX")"
    report="$UNIT_TEMP/report.xml" capture="$UNIT_TEMP/parallel.log" retry="$UNIT_TEMP/retry.log"
    plan_suites "Unit tests"
    ui_heading "" "Unit tests"
    ui_kv "Run" "swift test ${args[*]}"
    run_swift_with_limit "$UNIT_PARALLEL_LIMIT" "$capture" "${args[@]}" --xunit-output "$report" || status=$?
    if [[ "$status" -eq 0 ]]; then
        record_suite "Unit tests" ok "$(ui_elapsed $(( SECONDS - started )))"
        return 0
    fi

    if [[ "$status" -eq 124 ]]; then
        warn "The parallel run passed its ${UNIT_PARALLEL_LIMIT} s limit. Running every test, one at a time."
        if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
            printf '::warning title=Parallel run timed out::Stopped at its %s s limit, so every test ran again, one at a time.\n' "$UNIT_PARALLEL_LIMIT"
        fi
        run_unit_tests_serially
        return
    fi

    issues="$(sed -nE 's/.*Test run with .* with ([0-9]+) issues?.*/\1/p' "$capture" | tail -1)"
    names="$(scripts/failed-tests.sh "$report" "$issues")" || names=""
    if [[ -z "$names" ]]; then
        warn "The parallel run gave no clear result. Running every test, one at a time."
        run_unit_tests_serially
        return
    fi

    count=$(( $(wc -l <<<"$names") ))
    if (( count > UNIT_RETRY_MOST )); then
        record_suite "Unit tests" fail "$count tests failed"
        return "$status"
    fi
    while IFS= read -r filter; do
        filters+=(--filter "$filter")
    done <<<"$names"
    warn "$count failed in parallel. Running them again, one at a time."
    status=0
    run_swift_suite "Unit tests" "$retry" --disable-xctest "${filters[@]}" || status=$?
    if [[ "$status" -ne 0 ]]; then
        return "$status"
    fi
    if ! grep -Eq "Test run with $count tests? in" "$retry"; then
        warn "The rerun did not match those tests. Running every test, one at a time."
        run_unit_tests_serially
        return
    fi
    while IFS= read -r filter; do
        warn "Passed only when run alone: ${filter//\\/}"
        if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
            printf '::warning title=Passed only alone::%s\n' "${filter//\\/}"
        fi
    done <<<"$names"
}
