---
name: offsider-skill-creator
description: Creates or updates project skills for the Offsider repo and the bundled Offsider skill that `offsider init` installs. Use when asked to "add an Offsider skill", "create a project skill", "update a skill", "sync skills for Codex and Claude Code", "fix the .claude/skills symlink", "edit the bundled SKILL.md", or extend Offsider's agent infrastructure. Project-scoped distillation of ps-skill-md.
---

# offsider-skill-creator

Builds in-repo skills for Offsider that actually work. `.agents/skills` is the only source of truth for project skills; `.claude/skills` exposes it to Claude Code through one relative symlink. For personal, cross-project skills use the global `ps-skill-md` instead.

## When to use

- Adding or improving a project skill under `.agents/skills/<name>/`
- Repairing the shared Codex and Claude Code skill layout
- Editing the product skill at `Sources/Offsider/Resources/skills/offsider/SKILL.md`

## Instructions

1. **Interview first.** Ask focused multiple-choice questions (`AskUserQuestion` in Claude Code, `request_user_input` in Codex) covering purpose, trigger phrases, the exact workflow, edge cases, failures already seen and validation commands. Never write skill content from assumptions; generic skills get skipped by agents.
2. **Name it for the repo.** Project skills are `offsider-<capability>` in kebab-case (`offsider-commit`, `offsider-release`), and the directory name equals the `name:` field. Never use `ps-`, which is reserved for global personal skills. The product skill keeps the bare name `offsider`.
3. **Ensure the shared layout.**
   - Missing: `mkdir -p .agents/skills .claude && ln -s ../.agents/skills .claude/skills`.
   - `.claude/skills` is a real directory: move each non-conflicting skill into `.agents/skills` with `git mv`. If a name exists in both, compare them and ask which to keep; never overwrite either. Then `rmdir .claude/skills` and create the symlink.
   - Wrong symlink: inspect its target, migrate safe in-repo content, ask before touching anything external, then `unlink .claude/skills` and recreate it.
   - Never keep duplicate skill files under `.claude`. Link the canonical directory instead.
4. **Place it.** Project skill: `.agents/skills/<name>/SKILL.md`, plus `REFERENCE.md` if it would pass 250 lines (one level deep only). Product skill: edit only the bundled file; never recreate a second copy elsewhere in the repo.
5. **Write to the quality bar** below.
6. **Product skill extras.** It ships to users, so it describes `offsider` commands and flags only. Check every flag against `Sources/Offsider/Commands/*.swift` or `offsider <command> --help`; never document a flag from memory. Keep repo-internal rules out of it. When commands change, update it in the same change as the command.
7. **Verify immediately.** Run the checks below; fix and rerun until clean before responding.
   ```bash
   test -L .claude/skills
   test "$(readlink .claude/skills)" = "../.agents/skills"
   test .agents/skills -ef .claude/skills
   for d in .agents/skills/*/; do n=$(basename "$d"); grep -qx "name: $n" "$d/SKILL.md" || echo "name mismatch: $n"; done
   wc -l .agents/skills/*/SKILL.md Sources/Offsider/Resources/skills/offsider/SKILL.md   # each under 250
   grep -n "$(printf '\342\200\224')" .agents/skills/*/SKILL.md Sources/Offsider/Resources/skills/offsider/SKILL.md   # must be empty
   ```
   For the product skill also run `swift build && swift test`, then `swift run offsider init --print | diff - Sources/Offsider/Resources/skills/offsider/SKILL.md` (must be empty).

## Quality bar

- **Description is king.** The YAML `description` is all an agent sees before loading. Third person, packed with concrete trigger phrases.
- **Only add what the agent does not know.** Cut general Swift or git knowledge.
- **One skill, one capability.** Never merge unrelated workflows; it breaks trigger matching.
- **Every rule traces to a real failure.** "Resolve Xcode via `xcode-select -p`, because hard-coded `/Applications/Xcode.app` paths break when a beta is installed beside it" beats "find Xcode correctly".
- **Every prohibition has an alternative.** "Never widen the leak-gate exclusions. Rename the leak instead."
- **One concrete example beats paragraphs.**
- **Validation loop.** Exact commands, fix and rerun until passing.
- **Australian English, no em dashes, no references to private notes or roadmap stages.**

## Pre-finalisation checklist

- [ ] Description has concrete triggers, third person
- [ ] Instructions are numbered, actionable steps
- [ ] Every prohibition has an alternative
- [ ] No vague rules
- [ ] Validation loop included
- [ ] Under 250 lines, or split into `REFERENCE.md`
- [ ] One capability only
- [ ] Authored under `.agents/skills` (or the bundled product path), symlink checks pass
- [ ] `offsider-commit` used to commit the change

## Example: SKILL.md skeleton

```markdown
---
name: offsider-<capability>
description: <What it does and when, third person, with trigger phrases.>
---

# offsider-<capability>

<One-sentence purpose.>

## When to use
- <trigger>

## Instructions
1. **Step:** actionable, with the exact command
2. **Verify:** run `swift build && swift test`; fix and rerun until clean
```
