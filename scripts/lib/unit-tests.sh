#!/usr/bin/env bash
# The unit test run test-runner.sh sources: parallel for speed, with a test that fails there held to the bar of a serial run.

# Seconds a parallel run gets, the most failed tests it may run again alone, and the most unfinished ones a stall may.
UNIT_PARALLEL_LIMIT=360
UNIT_RETRY_MOST=100
UNIT_STALL_RETRY_MOST=1000
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
            for _ in 1 2 3 4 5; do kill -0 -- "-$SWIFT_GROUP" 2>/dev/null && sleep 1; done
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

# The first three tests a capture shows starting and never finishing, earliest first, quoted and joined.
unfinished_tests() {
    awk '
        /^◇ Test ".*" started\.$/ {
            name = substr($0, index($0, "\""))
            sub(/ started\.$/, "", name)
            if (!(name in begun)) { begun[name] = 1; order[++count] = name }
            next
        }
        /^(✔|✘|➜) Test ".*" (with [0-9]+ test cases? )?(passed|failed|skipped)/ {
            name = substr($0, index($0, "\""))
            sub(/" (with [0-9]+ test cases? )?(passed|failed|skipped).*$/, "\"", name)
            ended[name] = 1
        }
        END {
            for (i = 1; i <= count && shown < 3; i++) {
                if (!(order[i] in ended)) { printf "%s%s", (shown ? ", " : ""), order[i]; shown++ }
            }
        }
    ' "$1"
}

# Every test, one at a time, replacing any row the attempt before it left.
run_unit_tests_serially() {
    # shellcheck disable=SC2034 # test-runner.sh reads these for its results.
    RESULT_NAMES=() RESULT_STATES=() RESULT_TIMES=()
    run_swift_suite "Unit tests" "" --disable-xctest
}

# The named tests, one at a time; a rerun that counts others runs every test instead, leaving UNIT_RERUN_MATCHED false.
run_named_tests_alone() {
    local names="$1" filter filters=() status=0
    UNIT_RERUN_MATCHED=false
    while IFS= read -r filter; do
        filters+=(--filter "$filter")
    done <<<"$names"
    run_swift_suite "Unit tests" "$UNIT_TEMP/retry.log" --disable-xctest "${filters[@]}" || status=$?
    if [[ "$status" -ne 0 ]]; then
        return "$status"
    fi
    if ! grep -Eq "Test run with $(( $(wc -l <<<"$names") )) tests? in" "$UNIT_TEMP/retry.log"; then
        warn "The rerun did not match those tests. Running every test, one at a time."
        run_unit_tests_serially
        return
    fi
    UNIT_RERUN_MATCHED=true
}

# Says the parallel run stopped at its limit, with the tests still running and what runs again.
report_stall() {
    local stuck="$1" again="$2"
    warn "The parallel run passed its ${UNIT_PARALLEL_LIMIT} s limit${stuck:+, still running $stuck}. Running $again, one at a time."
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
        stuck="${stuck//%/%25}"
        printf '::warning title=Parallel run timed out::Stopped at its %s s limit%s, so %s ran again, one at a time.\n' \
            "$UNIT_PARALLEL_LIMIT" "${stuck:+ with $stuck still running}" "$again"
    fi
}

# A failed test must pass alone and a stall reruns alone what it did not finish; anything unnamed runs everything serially.
run_unit_tests_parallel() {
    local report capture events names count filter issues stuck status=0 started=$SECONDS
    local args=(--skip-build --disable-xctest)
    [[ "$VERBOSE" == true ]] && args+=(--verbose)
    UNIT_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/offsider-unit-tests.XXXXXX")"
    report="$UNIT_TEMP/report.xml" capture="$UNIT_TEMP/parallel.log" events="$UNIT_TEMP/events.jsonl"
    plan_suites "Unit tests"
    ui_heading "" "Unit tests"
    ui_kv "Run" "swift test ${args[*]}"
    run_swift_with_limit "$UNIT_PARALLEL_LIMIT" "$capture" "${args[@]}" --xunit-output "$report" \
        --event-stream-output-path "$events" --event-stream-version 0 || status=$?
    if [[ "$status" -eq 0 ]]; then
        record_suite "Unit tests" ok "$(ui_elapsed $(( SECONDS - started )))"
        return 0
    fi

    if [[ "$status" -eq 124 ]]; then
        stuck="$(unfinished_tests "$capture")"
        names="$(scripts/unfinished-tests.sh "$events")" || names=""
        count=0
        [[ -z "$names" ]] || count=$(( $(wc -l <<<"$names") ))
        if (( count == 0 || count > UNIT_STALL_RETRY_MOST )); then
            report_stall "$stuck" "every test"
            run_unit_tests_serially
            return
        fi
        if (( count == 1 )); then
            report_stall "$stuck" "the 1 test that did not pass"
        else
            report_stall "$stuck" "the $count tests that did not pass"
        fi
        run_named_tests_alone "$names"
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
    warn "$count failed in parallel. Running them again, one at a time."
    run_named_tests_alone "$names" || return
    [[ "$UNIT_RERUN_MATCHED" == true ]] || return 0
    while IFS= read -r filter; do
        warn "Passed only when run alone: ${filter//\\/}"
        if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
            printf '::warning title=Passed only alone::%s\n' "${filter//\\/}"
        fi
    done <<<"$names"
}
