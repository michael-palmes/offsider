#!/usr/bin/env bash
# Prints one swift test --filter pattern per failed test in an xUnit report, for a rerun of exactly those tests.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/failed-tests.sh <xunit report> <issues the run counted>

Prints a --filter pattern for each failed test, one per line, and nothing when
none failed. Exits 1 when the report cannot be trusted to name every failure: a
missing report, a failure outside a test, a count that disagrees with the
report's own or the run's, or a name that is not a plain Swift identifier. The
run's count matters because the report leaves out an issue outside any test.
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
[ $# -eq 2 ] || { usage >&2; exit 2; }

report="$1"
issues="$2"
[ -f "$report" ] || exit 1
[[ "$issues" =~ ^[0-9]+$ ]] || exit 1

ids="$(awk -v issues="$issues" '
  function attr(line, key) {
    if (!match(line, key "=\"[^\"]*\"")) return ""
    return substr(line, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
  }
  /<testsuite / { declared += attr($0, "failures"); next }
  /<testcase / { id = attr($0, " classname") "/" attr($0, " name"); if ($0 ~ /\/>[[:space:]]*$/) id = ""; next }
  /<\/testcase>/ { id = ""; next }
  /<failure/ {
    found++
    if (id == "") { orphan = 1; next }
    if (!(id in seen)) { seen[id] = 1; print id }
  }
  END { if (orphan || found != declared + 0 || found != issues + 0) exit 1 }
' "$report")"

while IFS= read -r id; do
  [ -n "$id" ] || continue
  [[ "$id" =~ ^[A-Za-z0-9_.]+/[A-Za-z0-9_]+(\([A-Za-z0-9_:]*\))?$ ]] || exit 1
  printf '%s\n' "$id" | sed 's/[.()]/\\&/g'
done <<< "$ids"
