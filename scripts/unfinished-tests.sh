#!/usr/bin/env bash
# Prints one swift test --filter pattern per test a Swift Testing event stream never saw pass or skip, for a rerun of just those.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/unfinished-tests.sh <event stream>

Reads the JSON Lines that swift test writes with --event-stream-output-path
and --event-stream-version 0, even from a run stopped part way, and prints a
--filter pattern for each test that did not pass or skip: still running, never
started or with an issue. Prints nothing when every test finished. Exits 1 when
the stream cannot be trusted to list every test: a missing file, no test plan,
a run that never started, an issue outside any test, or a name that is not a
plain Swift identifier.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
esac
[ $# -eq 1 ] || { usage >&2; exit 2; }
[ -f "$1" ] || exit 1

# A stopped run can leave a half-written last line, so lines that do not parse are dropped.
patterns="$(jq -nrR '
  [inputs | fromjson? | select(type == "object" and .version == 0)] as $records
  | [$records[] | select(.kind == "test" and .payload.kind == "function") | .payload.id] as $plan
  | [$records[] | select(.kind == "event") | .payload] as $events
  | if ($plan | length) == 0 or ([$events[] | select(.kind == "runStarted")] | length) == 0
    then error("no test plan") else . end
  | [$events[] | select(.kind == "issueRecorded" and (.issue.isKnown | not)) | .testID] as $issues
  | if any($issues[]; . == null) then error("an issue outside any test") else . end
  | (reduce $issues[] as $id ({}; .[$id] = true)) as $failed
  | (reduce ($events[] | select(.kind == "testEnded" or .kind == "testSkipped") | .testID) as $id ({}; .[$id] = true)) as $done
  | $plan[]
  | select($failed[.] or ($done[.] | not))
  | sub("/[^/]+:[0-9]+:[0-9]+$"; "")
  | if test("^[A-Za-z0-9_.]+/[A-Za-z0-9_]+(\\([A-Za-z0-9_:]*\\))?$") then . else error("not a plain name") end
  | gsub("(?<c>[.()])"; "\\\(.c)")
' "$1" 2>/dev/null)" || exit 1
[ -z "$patterns" ] || printf '%s\n' "$patterns"
