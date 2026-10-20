#!/usr/bin/env bash
# Tests for scripts/lib/ui.sh: run with `/bin/bash scripts/lib/ui.test.sh` (macOS /bin/bash is 3.2, the oldest the scripts support).
# shellcheck disable=SC2016 # each case is a script for the child bash, so single quotes are meant
set -uo pipefail

UI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/offsider-ui-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASSED=0
FAILED=0
ESC=$'\033'

pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; shift; printf '  %s\n' "$@"; }

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then pass; else fail "$name" "expected to contain: $(printf '%q' "$expected")" "got: $(printf '%q' "$actual")"; fi
}

check_absent() {
    local name="$1" unexpected="$2" actual="$3"
    if [[ "$actual" != *"$unexpected"* ]]; then pass; else fail "$name" "should not contain: $(printf '%q' "$unexpected")" "got: $(printf '%q' "$actual")"; fi
}

# One line of the output is exactly <expected>.
check_line() {
    local name="$1" expected="$2" actual="$3"
    if printf '%s\n' "$actual" | grep -Fxq -- "$expected"; then pass; else fail "$name" "no line equal to: $(printf '%q' "$expected")" "got: $(printf '%q' "$actual")"; fi
}

# Every line of ASCII output fits in <max> columns.
check_fits() {
    local name="$1" max="$2" actual="$3" line widest=0
    while IFS= read -r line; do
        if (( ${#line} > widest )); then widest=${#line}; fi
    done <<<"$actual"
    if (( widest <= max )); then pass; else fail "$name" "widest line is $widest columns, more than $max" "got: $(printf '%q' "$actual")"; fi
}

# Every case runs in a fresh bash (this one, so 3.2 under /bin/bash) with stdin from a pipe and stdout and stderr captured.
# The markers and settings this shell may carry are cleared; leading VAR=value arguments set the ones a case tests.
run() {
    local vars=()
    while [[ $# -gt 1 ]]; do vars+=("$1"); shift; done
    env -u CLAUDE_CODE_CHILD_SESSION -u AI_AGENT -u OFFSIDER_OUTPUT -u NO_COLOR -u UI_ASCII -u FORCE_COLOR -u COLUMNS -u TERM \
        -u UI_RECOMMENDED_INDEX -u UI_ROW_LABEL_WIDTH LANG=en_AU.UTF-8 LC_ALL= LC_CTYPE= ${vars[@]+"${vars[@]}"} \
        "$BASH" -c ". '$UI'; $1" 2>&1
}

# --- sourcing, receipts and errors (a person on a pipe: no colour)

out="$(run 'source "'"$UI"'"; echo sourced-twice')"
check "a second source is a no-op" "sourced-twice" "$out"

out="$(run 'die "Xcode is missing" "xcode-select -p" 7'; echo "rc=$?")"
check_line "die leads with the cross and the message" "❌  Xcode is missing" "$out"
check_line "die ends with a Try line under the message" "    Try  xcode-select -p" "$out"
check "die exits with the given code" "rc=7" "$out"

out="$(run 'die "boom"'; echo "rc=$?")"
check "die defaults to exit 1" "rc=1" "$out"

out="$(run 'die "Run xcode-select -p first." "xcode-select -p"')"
check_absent "die drops a Try line its message already names" "Try" "$out"

out="$(env -u CLAUDE_CODE_CHILD_SESSION -u AI_AGENT LANG=en_AU.UTF-8 "$BASH" -c ". '$UI'; die 'to stderr' 'fix it'" 2>/dev/null)"
if [[ -z "$out" ]]; then pass; else fail "die leaked to stdout" "$out"; fi

out="$(run 'print_error "Simulator A is in a crash loop. Erase it, then run again."')"
check_line "an error's first sentence leads" "❌  Simulator A is in a crash loop." "$out"
check_line "the rest of an error sits under it" "    Erase it, then run again." "$out"

out="$(run 'print_success "built"')"
check_absent "a pipe gets no colour" "${ESC}[" "$out"
check_line "UTF-8 keeps the emoji receipt" "✅  built" "$out"

out="$(run 'ui_receipt "Frameworks ready" "in ./build_products"')"
check_line "a receipt's detail sits under its headline" "    in ./build_products" "$out"

out="$(run NO_COLOR=1 'print_success "built"; print_error "broke"; warn "careful" "do this"')"
check_line "NO_COLOR swaps to an ASCII OK tag" "[OK] built" "$out"
check_line "NO_COLOR swaps to an ASCII error tag" "[x] broke" "$out"
check_line "NO_COLOR swaps to an ASCII warning tag" "[!] careful" "$out"
check_line "warn takes a Try line" "    Try  do this" "$out"

out="$(run UI_ASCII=1 'print_success "built"')"
check_line "UI_ASCII=1 swaps to ASCII tags" "[OK] built" "$out"
out="$(run UI_ASCII=0 'print_success "built"')"
check_line "UI_ASCII=0 keeps the glyphs" "✅  built" "$out"

out="$(run LANG=C LC_ALL=C COLUMNS=80 'ui_header "🧪" "Offsider tests"')"
check "a non-UTF-8 locale uses ASCII rules" "-----" "$out"
check_absent "a non-UTF-8 locale drops the emoji" "🧪" "$out"

out="$(run FORCE_COLOR=1 'print_success "built"')"
check "FORCE_COLOR keeps colour on a pipe" "${ESC}[0;32m" "$out"

# Text with a code span reaches the child through the environment, so its backticks can never run as a command.
out="$(run TEXT='Run `true span-one` first.' 'ui_notice note "$TEXT" "offsider doctor"; ui_next "swift build"; log "Using /tmp/x"')"
check_line "a note leads with a tip" "💡  Run true span-one first." "$out"
check_line "a note's command is a See line" "    See  offsider doctor" "$out"
check_line "a next step is the last line" "Next  swift build" "$out"
check_line "a progress line is plain" "Using /tmp/x" "$out"

out="$(run FORCE_COLOR=1 TEXT='Run `true span-two` first.' 'warn "$TEXT"')"
check "a code span is cyan" "${ESC}[0;36mtrue span-two${ESC}[0m" "$out"
check_absent "a code span drops its backticks for a person" '`' "$out"

out="$(run HOME=/Users/me 'ui_path /Users/me/offsider/.build/idb-build.log')"
# shellcheck disable=SC2088 # the literal tilde is what a person sees
check "a person's path starts at ~" "~/offsider/.build/idb-build.log" "$out"

# --- width: COLUMNS, then the terminal, then tput, then 80

out="$(run COLUMNS=200 'ui_width'; echo)"
check "prose stays at 72 columns on a wide terminal" "72" "$out"
out="$(run COLUMNS=40 'ui_width'; echo)"
check "prose is one short of a narrow terminal" "39" "$out"
out="$(run COLUMNS=10 'ui_width'; echo)"
check "prose is never under 20 columns" "20" "$out"
out="$(run COLUMNS=0123 'ui_cols'; echo)"
check "COLUMNS with a leading zero is decimal" "123" "$out"
for bad in 0 1001 abc -5; do
    out="$(run COLUMNS="$bad" 'ui_cols'; echo)"
    if [[ "$out" =~ ^[0-9]+$ && "$out" != "$bad" ]] && (( out >= 1 && out <= 1000 )); then pass; else fail "COLUMNS=$bad is ignored" "got: $out"; fi
done

for pair in 40:narrow 59:narrow 60:regular 99:regular 100:wide 220:wide; do
    out="$(run COLUMNS="${pair%%:*}" 'ui_breakpoint'; echo)"
    check "$pair is the breakpoint Canvas.swift uses" "${pair#*:}" "$out"
done
out="$(run CLAUDE_CODE_CHILD_SESSION=1 COLUMNS=40 'ui_breakpoint'; echo)"
check_line "an agent is always regular, so nothing it reads depends on width" "regular" "$out"

out="$(run 'ui_widest "Offsider_E2E" "Offsider Duo" "Offsider_E2E_Fold"'; echo)"
check "ui_widest measures the widest label" "17" "$out"
out="$(run 'ui_elapsed 9; echo; ui_elapsed 125'; echo)"
check "ui_elapsed shows seconds" "9s" "$out"
check "ui_elapsed shows minutes and padded seconds" "2m 05s" "$out"

# Columns, as TerminalText.width counts them: emoji and wide characters two, marks, selectors and joiners none.
out="$(run 'for s in "a·é" "⚠️" "🛠️" "中文" "🇦🇺" "👨‍👩‍👧" "👍🏽" "e'$'\xcc\x81''" "'$'\033''[1mbold'$'\033''[0m" "✓●"; do _ui_measure "$s"; printf "%s;" "$_UI_W"; done')"
check "glyph widths match the Swift kit" "3;2;2;4;2;2;2;1;4;2;" "$out"

out="$(run '_ui_truncate "🧪🧪🧪" 5; printf "%s|" "$_UI_T"; _ui_truncate "abcdef" 3; printf "%s|" "$_UI_T"; _ui_truncate "abc" 3; printf "%s|" "$_UI_T"; _ui_truncate "abcdef" 1; printf "%s|" "$_UI_T"')"
check "truncation keeps whole glyphs and marks the cut" "🧪🧪…|ab…|abc|…|" "$out"
out="$(run NO_COLOR=1 '_ui_truncate "abcdef" 4; printf "%s|" "$_UI_T"')"
check "ASCII truncation uses three dots" "a...|" "$out"

# --- the header: title, summary right-aligned or under it, rule

out="$(run COLUMNS=80 'ui_header "🧪" "Offsider tests" "Simulator · iPhone 17 Pro"')"
check_line "at 80 columns the summary is right-aligned at 72" "🧪  Offsider tests                             Simulator · iPhone 17 Pro" "$out"
check_line "at 80 columns the rule is 72 wide" "$(printf '─%.0s' $(seq 1 72))" "$out"

out="$(run COLUMNS=40 'ui_header "🧪" "Offsider tests" "Android emulator · Offsider_E2E"')"
check_line "at 40 columns the title stands alone" "🧪  Offsider tests" "$out"
check_line "at 40 columns the summary drops under the title" "    Android emulator · Offsider_E2E" "$out"
check_line "at 40 columns the rule is 39 wide" "$(printf '─%.0s' $(seq 1 39))" "$out"

out="$(run COLUMNS=120 'ui_header "🧪" "Offsider tests" "Simulator · iPhone 17 Pro"')"
check_line "at 120 columns the header still keeps to 72" "$(printf '─%.0s' $(seq 1 72))" "$out"
out="$(run COLUMNS=120 'ui_header "🧪" "Results" "27 passed · 1 failed · 3 with no tests · 2 not run · tests only · Android emulator"')"
check_line "at 120 columns a long summary widens the rule to fit" "$(printf '─%.0s' $(seq 1 95))" "$out"

out="$(run COLUMNS=40 'ui_header "🛠️" "Dev build" "idb c50bca2"')"
check_line "an emoji with a selector counts two columns" "🛠️  Dev build               idb c50bca2" "$out"

out="$(run NO_COLOR=1 COLUMNS=80 'ui_header "🧪" "Offsider tests" "Simulator"')"
check_line "an ASCII header drops its mark" "Offsider tests                                                 Simulator" "$out"

# --- rows: a glyph, a padded label, a dim detail; never wider than the terminal

out="$(run NO_COLOR=1 COLUMNS=80 'for s in ok warn fail skip run on off; do UI_ROW_LABEL_WIDTH=5 ui_row "$s" "$s" "detail"; done')"
check_line "an ASCII ok row" "  [OK] ok     detail" "$out"
check_line "an ASCII warn row" "  [!]  warn   detail" "$out"
check_line "an ASCII fail row" "  [x]  fail   detail" "$out"
check_line "an ASCII skip row" "  [-]  skip   detail" "$out"
check_line "an ASCII run row" "  [..] run    detail" "$out"
check_line "an ASCII on row" "  [*]  on     detail" "$out"
check_line "an ASCII off row" "  [o]  off    detail" "$out"

out="$(run COLUMNS=80 'ui_row ok "TapTests" "1m 02s"; ui_row fail "SwipeTests"; ui_row on "Pixel_9" "emulator-5554"')"
check_line "a row leads with its glyph" "  ✓ TapTests  1m 02s" "$out"
check_line "a row without a detail" "  ✗ SwipeTests" "$out"
check_line "an on row" "  ● Pixel_9  emulator-5554" "$out"

out="$(run NO_COLOR=1 COLUMNS=30 'ui_row ok "Tools ready" "Xcode 27.0 (27A5194f) · xcodegen, jq, git · 120 GB free"; ui_row warn "A label far too long to fit in thirty columns" "gone"; ui_row skip "Short" "123456789012345"; ui_row skip "ABCDEFGHIJKLMNOPQRS" "detail"')"
check_fits "rows never pass the usable width" 29 "$out"
check_line "a long detail is cut with dots" "  [OK] Tools ready  Xcode ..." "$out"
check_line "a label too long is cut and loses its detail" "  [!]  A label far too lon..." "$out"
check_line "a detail that just fits is never cut" "  [-]  Short  123456789012345" "$out"
check_line "a detail with no room is dropped, not left as dots" "  [-]  ABCDEFGHIJKLMNOPQRS" "$out"

out="$(run COLUMNS=30 'ui_row ok "Tools ready" "Xcode 27.0 (27A5194f)"')"
check_line "a Unicode row is cut with an ellipsis" "  ✓ Tools ready  Xcode 27.0 …" "$out"

out="$(run NO_COLOR=1 COLUMNS=80 'ui_kv "Offsider" "/Users/me/offsider" "debug"; UI_KV_LABEL_WIDTH=10 ui_kv "Log" "/tmp/x"')"
check_line "a key and its value" "  Offsider  /Users/me/offsider  debug" "$out"
check_line "keys pad to a shared width" "  Log         /tmp/x" "$out"

# --- prose: wrapped at 72 however wide the terminal, never inside a code span

long='Offsider wraps prose at seventy-two columns so a line stays easy to read, even when the terminal is two hundred columns wide, and keeps `true this span stays whole` on one line however the words fall.'
out="$(run NO_COLOR=1 COLUMNS=200 LONG="$long" 'ui_wrap "$LONG"')"
check_fits "prose wraps at 72 even with COLUMNS=200" 72 "$out"
check "a code span is never broken" "true this span stays whole" "$out"
if (( $(printf '%s\n' "$out" | wc -l) >= 3 )); then pass; else fail "long prose takes several lines" "$out"; fi

out="$(run NO_COLOR=1 COLUMNS=200 LONG="$long" 'warn "$LONG" "true this span stays whole"')"
check_fits "a warning wraps at 72 too" 72 "$(printf '%s\n' "$out" | grep -v 'Try  ')"

# --- agents: plain prefixed lines, no escapes, no width

agent_script='ui_header "🧪" "Offsider tests" "Simulator"; ui_row ok "TapTests" "1m 02s"; ui_kv "Log" "/tmp/x" "kept"; ui_receipt "Built" "in 3s";
warn "Landscape tests skipped." "OFFSIDER_LANDSCAPE_E2E=1 ./test-runner.sh"; ui_notice note "A note."; ui_next "swift build";
ui_wrap "$LONG"; spinner_start "Working"; spinner_stop; ui_run_logged "Logged step" "'"$WORK"'/agent.log" true; ui_cleanup;
print_error "Broke. Mend it."; ui_try "fix it"'
out="$(run CLAUDE_CODE_CHILD_SESSION=1 FORCE_COLOR=1 COLUMNS=20 LONG="$long" "$agent_script")"
check_absent "an agent gets no escapes, even with FORCE_COLOR" "$ESC" "$out"
check_absent "an agent gets no carriage returns" $'\r' "$out"
check_line "an agent header is one line" "Offsider tests: Simulator" "$out"
check_line "an agent row has no indent" "✓ TapTests  1m 02s" "$out"
check_line "an agent key is labelled" "Log: /tmp/x (kept)" "$out"
check_line "an agent receipt is plain" "Built" "$out"
check_line "an agent warning is prefixed" "Warning: Landscape tests skipped." "$out"
check_line "an agent Try is prefixed" "Try: OFFSIDER_LANDSCAPE_E2E=1 ./test-runner.sh" "$out"
check_line "an agent note is prefixed" "Note: A note." "$out"
check_line "an agent next step is prefixed" "Next: swift build" "$out"
check_line "an agent error is one prefixed line" "Error: Broke. Mend it." "$out"
check_line "an agent's prose never wraps, whatever COLUMNS says" "$long" "$out"
check_line "an agent spinner is one label line" "Working" "$out"
check_line "an agent logged step ends with its row" "✓ Logged step  0s" "$out"

out="$(run AI_AGENT=claude-code 'warn "careful"')"
check_line "a non-empty AI_AGENT marks an agent" "Warning: careful" "$out"
for quiet in "AI_AGENT=0" "AI_AGENT=" "CLAUDE_CODE_CHILD_SESSION=0" "CLAUDE_CODE_CHILD_SESSION= "; do
    out="$(run "$quiet" 'warn "careful"')"
    check_line "$quiet is no marker" "⚠️  careful" "$out"
done
out="$(run CLAUDE_CODE_CHILD_SESSION=1 OFFSIDER_OUTPUT=person 'warn "careful"')"
check_line "OFFSIDER_OUTPUT=person wins over the markers" "⚠️  careful" "$out"
out="$(run OFFSIDER_OUTPUT=" Agent " 'warn "careful"')"
check_line "OFFSIDER_OUTPUT=agent marks an agent, whatever its case and spaces" "Warning: careful" "$out"
out="$(run CLAUDE_CODE_CHILD_SESSION=1 OFFSIDER_OUTPUT=robot 'warn "careful"')"
check_line "an unknown OFFSIDER_OUTPUT leaves the markers to decide" "Warning: careful" "$out"
out="$(run CLAUDE_CODE_CHILD_SESSION=1 'warn "Run swift build first." "swift build"')"
check_absent "an agent gets no Try its warning already names" "Try:" "$out"
out="$(run CLAUDE_CODE_CHILD_SESSION=1 HOME=/Users/me 'ui_path /Users/me/x')"
check "an agent's path stays whole" "/Users/me/x" "$out"
out="$(run CLAUDE_CODE_CHILD_SESSION=1 NO_COLOR=1 'ui_row fail "TapTests"')"
check_line "an agent's glyphs never switch to ASCII" "✗ TapTests" "$out"

# --- pickers

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

out="$(printf '2\n' | run CLAUDE_CODE_CHILD_SESSION=1 'UI_RECOMMENDED_INDEX=0 select_menu "What should run?" "a|Unit tests" "b|Simulator" && echo "picked=$SELECTED_INDEX"; IFS= read -r left; echo "left=$left"')"
check "an agent's picker takes the recommended row" "picked=0" "$out"
check "an agent's picker never reads stdin" "left=2" "$out"
check "an agent's picker says what it chose" "Note: What should run? Picked Unit tests, the recommended answer, without asking." "$out"

out="$(printf '1\n' | run CLAUDE_CODE_CHILD_SESSION=1 'confirm "Create the missing ones?" && echo yes || echo no; IFS= read -r left; echo "left=$left"')"
check "an agent's confirm is No" "no" "$out"
check "an agent's confirm never reads stdin" "left=1" "$out"
check "an agent's confirm says it did not ask" "Note: Create the missing ones? Not asked: there is no person to answer." "$out"

# The arrow-key picker's pieces: rows cut to the terminal, and the rows a resize folds them into.
out="$(run '_ui_rows_used 40 39 0 80 81; echo "$_UI_ROWS"; _ui_rows_used 20 39 39; echo "$_UI_ROWS"; _ui_rows_used 80 39 0; echo "$_UI_ROWS"')"
check_line "rows fold into ceil(width / columns) when narrowed" "7" "$out"
check_line "every line folds at a narrower terminal" "4" "$out"
check_line "an empty line still takes a row" "2" "$out"

out="$(run NO_COLOR=1 'UI_RECOMMENDED_INDEX=1; _ui_label_width "a|Simulator|an iPhone simulator and XcodeGen" "b|Unit tests|no device"; _ui_draw_row 1 1 "b|Unit tests|no device" 80; _ui_draw_row 0 0 "a|Simulator|an iPhone simulator and XcodeGen" 30; echo "width=$_UI_ROW_WIDTH"' | tr -d '\r')"
check_line "a selected ASCII row with its badge" "  > Unit tests  no device (Recommended)" "$out"
check_line "a narrow row cuts its note" "    Simulator   an iPhone ..." "$out"
check "a drawn row records its width" "width=29" "$out"
check_fits "menu rows never pass the usable width" 40 "$(printf '%s\n' "$out" | grep -v '^width=')"

# --- logged steps and the spinner

out="$(run 'set -e; ui_run_logged "Building thing" "'"$WORK"'/ok.log" bash -c "echo hidden-line"; echo "after rc=$?"')"
check "a logged step leaves a status row" "✓ Building thing  0s" "$out"
check_absent "a logged step hides its output" "hidden-line" "$out"
check "a logged step writes its log" "hidden-line" "$(cat "$WORK/ok.log")"

out="$(run 'ui_run_logged "Building other" "'"$WORK"'/bad.log" bash -c "for i in \$(seq 1 40); do echo line-\$i; done; exit 3"; echo "rc=$?"')"
check_line "a failed step leaves a failed row" "  ✗ Building other  0s" "$out"
check "a failed step shows its last lines" "line-40" "$out"
check_absent "a failed step shows only 30 lines" "line-10"$'\n' "$out"
check_line "a failed step names its log" "    Log  $WORK/bad.log" "$out"
check "a failed step returns its code" "rc=3" "$out"

out="$(run CLAUDE_CODE_CHILD_SESSION=1 'ui_run_logged "Agent step" "'"$WORK"'/agent-bad.log" false')"
check_line "an agent's failed step names its log" "Log: $WORK/agent-bad.log" "$out"

out="$(run 'UI_TAIL_LINES=5 ui_run_logged "Short tail" "'"$WORK"'/tail.log" bash -c "seq 1 20; exit 1"')"
check_absent "UI_TAIL_LINES shortens the tail" $'\n15\n' "$out"
check "UI_TAIL_LINES keeps the last lines" "20" "$out"

out="$(printf 'typed-answer\n' | run 'ui_run_logged "Reads stdin" "'"$WORK"'/stdin.log" bash -c "IFS= read -r x || true; echo \"got=[\$x]\""')"
check "a logged step's stdin is empty, so a hidden prompt cannot wait" "got=[]" "$(cat "$WORK/stdin.log")"

out="$(run 'set -e; ui_run_logged "Errexit" "'"$WORK"'/e.log" false || true; false; echo still-running')"
check_absent "a logged step keeps the caller's errexit" "still-running" "$out"

out="$(run 'ui_run_logged "No errexit" "'"$WORK"'/n.log" true; false; echo still-running')"
check "a logged step leaves errexit off when it was off" "still-running" "$out"

out="$(run 'set -e; step() { false; echo ran-on; }; set +e; ui_run_logged "Two commands" "'"$WORK"'/two.log" step; echo "rc=$?"')"
check "a step called plainly stops at its first failure" "rc=1" "$out"
check_absent "a step called plainly never runs on" "ran-on" "$(cat "$WORK/two.log")"

out="$(run 'spinner_start "Working"; spinner_stop; echo done')"
check "a spinner off a terminal prints its text once" "Working" "$out"

# Every helper succeeds under the strictest caller, so `set -euo pipefail` scripts never stop on a draw.
out="$(run COLUMNS=60 'set -euo pipefail; ui_header "🧪" "T" "s"; ui_row ok "a"; ui_row warn "b" "c"; ui_kv "k" "v"; ui_receipt "r"; ui_wrap "w"; ui_heading "" "h"; ui_step 1 2 "s"; log "l"; print_info "i"; print_warning "w"; ui_notice note "n"; ui_try "t"; ui_next "n"; ui_cleanup; echo survived')"
check "the helpers never fail under set -euo pipefail" "survived" "$out"
out="$(run CLAUDE_CODE_CHILD_SESSION=1 'set -euo pipefail; ui_header "🧪" "T"; ui_row ok "a"; ui_kv "k" "v"; ui_receipt "r"; ui_wrap "w"; ui_heading "" "h"; ui_step 1 2 "s"; log "l"; print_info "i"; ui_try "t"; ui_next "n"; ui_cleanup; echo survived')"
check "an agent's helpers never fail under set -euo pipefail" "survived" "$out"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
