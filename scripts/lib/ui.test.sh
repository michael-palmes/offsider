#!/usr/bin/env bash
# Tests for scripts/lib/ui.sh: run with `bash scripts/lib/ui.test.sh`.
# shellcheck disable=SC2016 # each case is a script for the child bash, so single quotes are meant
set -uo pipefail

UI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/offsider-ui-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASSED=0
FAILED=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n  expected to contain: %q\n  got: %q\n' "$name" "$expected" "$actual"
    fi
}

check_absent() {
    local name="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n  should not contain: %q\n  got: %q\n' "$name" "$unexpected" "$actual"
    fi
}

# Every case runs in a fresh bash with stdin from a pipe and stdout and stderr captured, as a script in CI would.
run() {
    LANG=en_AU.UTF-8 LC_ALL='' bash -c ". '$UI'; $1" 2>&1
}

out="$(run 'source "'"$UI"'"; echo sourced-twice')"
check "a second source is a no-op" "sourced-twice" "$out"

out="$(run 'die "Xcode is missing" "xcode-select -p" 7'; echo "rc=$?")"
check "die prints the message" "Xcode is missing" "$out"
check "die ends with a Try line" "Try: xcode-select -p" "$out"
check "die exits with the given code" "rc=7" "$out"

out="$(run 'die "boom"'; echo "rc=$?")"
check "die defaults to exit 1" "rc=1" "$out"

out="$(LANG=en_AU.UTF-8 bash -c ". '$UI'; die 'to stderr' 'fix it'" 2>/dev/null)"
if [[ -z "$out" ]]; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); echo "FAIL die leaked to stdout: $out"; fi

out="$(run 'print_success "built"')"
check_absent "a pipe gets no colour" $'\033[' "$out"
check "UTF-8 keeps the emoji receipt" "✅  built" "$out"

out="$(NO_COLOR=1 run 'print_success "built"; print_error "broke"; warn "careful" "do this"')"
check "NO_COLOR swaps to an ASCII OK tag" "[OK]  built" "$out"
check "NO_COLOR swaps to an ASCII error tag" "[x]  broke" "$out"
check "NO_COLOR swaps to an ASCII warning tag" "[!] careful" "$out"
check "warn takes a Try line" "Try: do this" "$out"

out="$(LANG=C LC_ALL=C bash -c ". '$UI'; ui_banner '🧪' 'Offsider tests'" 2>&1)"
check "a non-UTF-8 locale uses ASCII rules" "====" "$out"
check_absent "a non-UTF-8 locale drops the emoji" "🧪" "$out"

out="$(FORCE_COLOR=1 run 'print_success "built"')"
check "FORCE_COLOR keeps colour on a pipe" $'\033[0;32m' "$out"

out="$(printf '2\n' | run 'select_menu "Which tests?" "🧪|Unit|no device" "📱|Simulator|an iPhone simulator" && echo "picked=$SELECTED_INDEX"')"
check "a piped picker numbers its rows" "2) Simulator  an iPhone simulator" "$out"
check "a piped picker takes a number" "picked=1" "$out"

out="$(printf '\n' | run 'UI_RECOMMENDED_INDEX=1 select_menu "Which?" "a|One" "b|Two" && echo "picked=$SELECTED_INDEX"')"
check "an empty answer takes the recommended row" "picked=1" "$out"

out="$(printf 'nine\n' | run 'select_menu "Which?" "a|One" "b|Two" || echo "quit=$?"')"
check "a bad answer returns 1" "quit=1" "$out"

out="$(run 'select_menu "Which?" "a|One" < /dev/null || echo "quit=$?"')"
check "a closed stdin returns 1" "quit=1" "$out"

out="$(printf '2\n' | run 'confirm "Create them?" && echo yes || echo no')"
check "confirm returns non-zero for No" "no" "$out"

out="$(printf '\n' | run 'confirm "Create them?" no && echo yes || echo no')"
check_absent "confirm with a no default does not pick Yes on Enter" "yes" "$out"

out="$(run 'set -e; ui_run_logged "Building thing" "'"$WORK"'/ok.log" bash -c "echo hidden-line"; echo "after rc=$?"')"
check "a logged step prints a receipt" "Building thing" "$out"
check_absent "a logged step hides its output" "hidden-line" "$out"
check "a logged step writes its log" "hidden-line" "$(cat "$WORK/ok.log")"

out="$(run 'ui_run_logged "Building other" "'"$WORK"'/bad.log" bash -c "for i in \$(seq 1 40); do echo line-\$i; done; exit 3"; echo "rc=$?"')"
check "a failed step says so" "Building other failed" "$out"
check "a failed step shows its last lines" "line-40" "$out"
check_absent "a failed step shows only 30 lines" "line-10"$'\n' "$out"
check "a failed step names its log" "Log: $WORK/bad.log" "$out"
check "a failed step returns its code" "rc=3" "$out"

out="$(run 'set -e; ui_run_logged "Errexit" "'"$WORK"'/e.log" false || true; false; echo still-running')"
check_absent "a logged step keeps the caller's errexit" "still-running" "$out"

out="$(run 'ui_run_logged "No errexit" "'"$WORK"'/n.log" true; false; echo still-running')"
check "a logged step leaves errexit off when it was off" "still-running" "$out"

out="$(run 'spinner_start "Working"; spinner_stop; echo done')"
check "a spinner off a terminal prints its text once" "Working" "$out"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
