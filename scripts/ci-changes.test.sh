#!/usr/bin/env bash
# Tests for scripts/ci-changes.sh: run with `bash scripts/ci-changes.test.sh`.
set -uo pipefail

CHANGES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci-changes.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

classify() {
    printf '%s' "$1" | bash "$CHANGES" 2>&1
}

check "root Markdown, docs pages and their images skip the macOS jobs" macos=false \
    "$(classify $'README.md\nCHANGELOG.md\nSECURITY.md\ndocs/install.md\ndocs/assets/hero.png\n')"
check "project skills and the templates skip the macOS jobs" macos=false \
    "$(classify $'.agents/skills/offsider-commit/SKILL.md\n.github/PULL_REQUEST_TEMPLATE.md\n.github/ISSUE_TEMPLATE/bug.yml\n')"
check "the last path counts without a trailing newline" macos=true "$(classify $'README.md\nPackage.swift')"
check "one source file among docs needs the macOS jobs" macos=true "$(classify $'README.md\nSources/Offsider/main.swift\n')"
check "docs/errors.md is read by the error contract tests" macos=true "$(classify 'docs/errors.md')"
check "docs/commands.md is read by the guide tests" macos=true "$(classify 'docs/commands.md')"
check "the bundled skill is a release resource" macos=true "$(classify 'Sources/Offsider/Resources/skills/offsider/SKILL.md')"
check "Markdown under Tests is a fixture" macos=true "$(classify 'Tests/Fixtures/notes.md')"
check "a workflow change runs everything" macos=true "$(classify '.github/workflows/ci.yml')"
check "the signer list is not a template" macos=true "$(classify '.github/allowed_signers')"
check "LICENSE ships in the release archive" macos=true "$(classify 'LICENSE')"
check "a path git quoted is never trusted as docs" macos=true "$(classify '"docs/caf\303\251.md"')"
check "an empty change list proves nothing" macos=true "$(classify '')"

long_list_status="$(set -o pipefail; { echo Sources/Offsider/main.swift; for i in $(seq 1 5000); do echo "docs/page-$i.md"; done; } | bash "$CHANGES" > /dev/null; echo $?)"
check "a long list after a code path is read to the end, so its writer never gets SIGPIPE" 0 "$long_list_status"

# A docs page a test, the build or a script the macOS jobs run reads must never be skipped as docs.
macos_inputs() {
    find "$REPO/Tests" "$REPO/Plugins" -name '*.swift'
    find "$REPO/scripts/lib" -name '*.sh'
    printf '%s\n' "$REPO/Package.swift" "$REPO/test-runner.sh" "$REPO/scripts/build.sh" "$REPO/scripts/release.sh"
}
read_pages="$(macos_inputs | tr '\n' '\0' | xargs -0 grep -hoE 'docs/[A-Za-z0-9._-]+\.md' | sort -u)"
check "the tests read at least one docs page" true "$([[ -n "$read_pages" ]] && echo true || echo false)"
while IFS= read -r page; do
    [[ -n "$page" ]] || continue
    check "$page, which a test or build step reads, needs the macOS jobs" macos=true "$(classify "$page")"
done <<< "$read_pages"
built_paths="$(macos_inputs | tr '\n' '\0' | xargs -0 grep -nE '"docs/?"|"docs/\\\(' | sed "s|^$REPO/||")"
check "no test or build step names a docs page in parts, which this guard cannot see" "" "$built_paths"

usage_output="$(bash "$CHANGES" --all < /dev/null 2>&1)"
usage_status=$?
check "an argument is a usage error" "ci-changes: unexpected argument --all" "$usage_output"
check "an argument exits 2" 2 "$usage_status"

printf '%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
