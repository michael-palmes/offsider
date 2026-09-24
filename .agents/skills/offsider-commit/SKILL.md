---
name: offsider-commit
description: Plans and creates git commits for the Offsider repo. Reviews uncommitted changes for red flags (secrets, axe rename leaks, AXE_ env vars, hard-coded UDIDs or Xcode paths, em dashes), runs swift build, swift test and the rename-leak gate, groups changes into logical conventional commits and executes them. Use for every commit in this repo, whenever asked to "commit", "commit my changes", "plan commits", "review and commit", "smart commit", or before opening a PR. Project-scoped distillation of ps-commit.
---

# offsider-commit

Reviews all uncommitted changes, validates them, groups them into logical conventional commits and executes them. Every commit in this repo goes through this flow. Do not push unless asked.

## When to use

- Any time work in this repo needs committing, including before opening a PR
- The user says "commit", "plan commits", "smart commit" or "review and commit"

## Instructions

1. **Gather.** Run `git status`, `git diff HEAD --stat`, `git ls-files --others --exclude-standard`, then read the full `git diff HEAD` and every untracked file. Nothing to commit: say so and stop. Merge conflicts: ask the user to resolve them and stop.
2. **Check the branch.** `git branch --show-current` must match `type/short-kebab-description`. On `main`, or on a `claude/` prefix or a generated suffix such as `-94cd0f`, never commit there. Instead run `git switch -c <type>/<desc>` (from main) or `git branch -m <type>/<desc>` (renaming), then continue.
3. **Validate.** Run each check; fix and rerun until all pass.
   ```bash
   swift build && swift test
   { git diff HEAD --name-only --diff-filter=d; git ls-files --others --exclude-standard; } \
     | grep -E '\.sh$' | while read -r f; do bash -n "$f" || echo "FAIL $f"; done
   git grep -nIP --untracked '(?<![A-Za-z])[Aa][Xx][Ee](?!s\b)|(?<=[a-z])Axe|AXE_' -- . \
     ':!CHANGELOG.md' ':!LICENSE' ':!THIRD_PARTY_LICENSES' ':!README.md' ':!NOTICE.md' \
     ':!CONTRIBUTING.md' ':!AGENTS.md' ':!CLAUDE.md' ':!.agents/skills/offsider-commit/SKILL.md'
   cmp -s AGENTS.md CLAUDE.md && test -L .claude/skills
   ```
   - `swift build` fails because `build_products/XCFrameworks` is missing: run `./scripts/build.sh dev` first. Never commit with validation skipped.
   - Unit tests run without a simulator; E2E suites are gated by `OFFSIDER_E2E`. Never set it here: E2E runs are a separate, deliberate step.
   - The leak gate must print nothing. A hit means a missed rename: rename it (`git mv` for paths). Never widen the exclusions to silence it.
   - `cmp` fails: copy the edited file over the other so both match.
4. **Light review.** Scan `git diff HEAD` and untracked files for:
   - Secrets or signing material: `.p12`, `.p8`, `.cer`, `.mobileprovision`, `.env`, `keys/`, private-key blocks, `ghp_` or `github_pat_` tokens, App Store Connect key IDs. Unstage and add to `.gitignore`; values belong in `.env` or GitHub secrets.
   - Rename leaks the gate cannot see: `axe` in user-facing strings built at runtime, `AXE_` variables read via string concatenation, `com.cameroncooke` identifiers.
   - Hard-coded simulator UDIDs: `grep -nE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}'` on added lines. Use `SIMULATOR_UDID` or `list-simulators` output instead.
   - `/Applications/Xcode` paths. Resolve via `xcode-select -p` or `DEVELOPER_DIR`.
   - Debug output: `debugPrint(`, `dump(`, stray `print("DEBUG`, `set -x`. Real CLI output goes through the command's output path.
   - Network or telemetry: new `URLSession`, `NWConnection` or `http` URLs in `Sources/`. Offsider stays local-only; flag it.
   - Signing: any new `codesign ... --deep` signing call. Sign frameworks individually, inside-out.
   - Writing rules: em dashes (`grep -n "$(printf '\342\200\224')"`), multi-line or restating comments, American spellings in prose.
   - Tests that restate implementation (re-deriving a value the way the code does). Rewrite to assert behaviour or a contract.
   - Accidental files: `.DS_Store`, `.build/`, `build_products/`, `build_derived_data/`, `idb_checkout/`, `dist/`, `Version.swift`.
5. **Group into commits.** One logical change per commit; split unrelated work, never split one cohesive change. Tests stage with the source they cover; `git mv` renames stage with the edits that make them compile. Message: `type: subject`, lowercase imperative, under 72 characters, no scope, no body, no trailers or attribution lines. Types: feat, fix, docs, refactor, perf, test, chore, ci, build, revert.
6. **Approve or auto-commit.** A single commit with no review findings commits straight away. Multiple commits or any finding: present the findings and the plan (message and files per commit) and wait for approval.
7. **Execute.** `git reset HEAD` first, then per commit: `git add -- <files>` (use `git add -p` when one file spans commits), check `git diff --cached --stat`, then `git commit -m "type: subject"`. Never pass a second `-m`. If a hook rejects the commit, stop and show its output; never retry with `--no-verify`. Instead, fix the reported problem and rerun from step 3.
8. **Verify.** `git log --oneline -n <count>` and `git status`; report anything left uncommitted and why.

## Examples

```text
feat: add doctor command
fix: retry first gesture dropped by dtuhidd
build: build idb frameworks for arm64 only
refactor: rename axe to offsider across sources
ci: pin actions to commit shas
```

## Edge cases

- Ambiguous hunk ownership: ask, do not guess
- Aborted mid-plan: stop; `git reset --soft HEAD~N` undoes the last N commits
- Binary files (screenshots, goldens): stage by name, never diff; goldens change only with a deliberate recapture
