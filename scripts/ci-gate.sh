#!/usr/bin/env bash
# Decides the CI passed check, and checks that no CI job can stop gating merges by being left off its needs.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: NEEDS='<toJSON(needs)>' scripts/ci-gate.sh [--skippable <job>]...
       scripts/ci-gate.sh --check-needs <workflow> <gate job> [<exempt job>]...

The first form reads the gate's needs from $NEEDS and exits 0 only when every
job succeeded, or is a --skippable job skipped while the changes job's output
of the same name is false (a docs-only change, or a run where AddressSanitizer
stands in). A failure, a cancel, any other skip, an empty or unreadable list
exits 1.

The second form exits 1 when a job in the workflow is neither the gate, an
exempt job nor among the gate's needs. It needs ruby.

Exit status: 0 passed, 1 failed, 2 usage error.
EOF
}

die_usage() {
  printf 'ci-gate: %s\n' "$1" >&2
  printf 'Run scripts/ci-gate.sh --help for usage.\n' >&2
  exit 2
}

fail() {
  printf '::error::%s\n' "$1"
  exit 1
}

check_results() {
  local skippable=" $* " results job result wanted failed=0
  [ -n "${NEEDS:-}" ] || fail "NEEDS is empty, so there are no job results to check"
  results="$(jq -r '. as $needs | to_entries[] | "\(.key)\t\(.value.result)\t\($needs.changes.outputs[.key] // "")"' <<< "$NEEDS" 2>/dev/null)" \
    || fail "NEEDS is not the gate's needs as JSON"
  [ -n "$results" ] || fail "NEEDS lists no jobs"
  while IFS=$'\t' read -r job result wanted; do
    [ "$result" != success ] || continue
    if [ "$result" = skipped ] && [[ "$skippable" == *" $job "* ]]; then
      [ "$wanted" != false ] || continue
      printf '::error::%s was skipped although the change needs it\n' "$job"
    else
      printf '::error::%s: %s\n' "$job" "$result"
    fi
    failed=1
  done <<< "$results"
  return "$failed"
}

check_needs() {
  local workflow="$1" gate="$2" missing
  shift 2
  [ -f "$workflow" ] || fail "$workflow does not exist"
  missing="$(ruby -ryaml -e '
    jobs = YAML.load_file(ARGV.shift).fetch("jobs")
    gate = ARGV.shift
    abort "no job #{gate} in the workflow" unless jobs.key?(gate)
    puts jobs.keys - Array(jobs[gate]["needs"]) - [gate] - ARGV
  ' "$workflow" "$gate" "$@")" || fail "could not read the jobs of $workflow"
  if [ -n "$missing" ]; then
    while IFS= read -r job; do
      printf '::error::%s is not among the needs of %s, so it never blocks a merge\n' "$job" "$gate"
    done <<< "$missing"
    return 1
  fi
  printf 'Every job in %s gates merges through %s\n' "$workflow" "$gate"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --check-needs)
    [ $# -ge 3 ] || die_usage "--check-needs takes a workflow and the gate job"
    shift
    check_needs "$@"
    ;;
  *)
    skippable=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --skippable)
          [ -n "${2:-}" ] || die_usage "--skippable takes a job"
          skippable+=("$2")
          shift 2
          ;;
        *) die_usage "unexpected argument $1" ;;
      esac
    done
    check_results "${skippable[@]+"${skippable[@]}"}"
    ;;
esac
