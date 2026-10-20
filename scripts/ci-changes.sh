#!/usr/bin/env bash
# Reads changed paths, one per line, and prints macos=false only when every one is docs the macOS jobs never read.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: git diff --name-only --no-renames <base> <head> | scripts/ci-changes.sh

Prints macos=true when any changed path needs the macOS build and tests, and
macos=false when the change is docs alone: Markdown at the repository root,
docs/ (except docs/errors.md and docs/commands.md, which tests read), project
skills under .agents/skills/ and the issue and pull request templates.

Anything else, an empty list or a path git quoted needs the macOS jobs.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    printf 'ci-changes: unexpected argument %s\n' "$1" >&2
    exit 2
    ;;
esac

needs_macos() {
  case "$1" in
    docs/errors.md | docs/commands.md) return 0 ;;
    docs/* | .agents/skills/*.md | .github/ISSUE_TEMPLATE/* | .github/PULL_REQUEST_TEMPLATE.md) return 1 ;;
    */* | \"*) return 0 ;;
    *.md) return 1 ;;
    *) return 0 ;;
  esac
}

seen=false
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  seen=true
  if needs_macos "$path"; then
    # Read the rest, or a writer still sending paths dies of SIGPIPE under pipefail.
    cat > /dev/null
    echo macos=true
    exit 0
  fi
done

if [ "$seen" = true ]; then
  echo macos=false
else
  echo macos=true
fi
