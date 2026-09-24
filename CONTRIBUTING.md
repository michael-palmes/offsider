# Contributing to Offsider

Thanks for your interest. Offsider is a small, independently maintained project that began as a fork of [AXe](https://github.com/cameroncooke/axe), so a few things work differently from a typical project.

## Before you start

- **Offsider is independent of AXe.** Report Offsider problems and ideas here, not to the AXe project.
- **Issues are welcome.** Use the issue templates and include your macOS, Xcode and `offsider --version` details.
- **Pull requests may be declined** if they do not fit Offsider's scope: a local-only CLI for driving iOS Simulators from terminals and agents. Opening an issue first avoids wasted work.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Set up

You need an Apple silicon Mac, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [jq](https://jqlang.org).

```bash
brew install xcodegen jq
./scripts/build.sh dev   # build the pinned idb frameworks once per clone
swift build
```

## Checks before you open a pull request

```bash
swift build
swift test                   # unit tests, no simulator needed
bash -n <changed script>     # for any shell script you touched
make e2e                     # for changes to input, accessibility or capture, on a booted simulator
```

## Docs to update

A new or changed command or option also updates:

- `README.md` (the Commands table)
- `Sources/Offsider/Resources/skills/offsider/SKILL.md` (the skill `offsider init` installs)
- `CHANGELOG.md`, under `## [Unreleased]`

## Style

- Swift Testing for tests. Assert behaviour and contracts, not implementation details.
- Australian English in docs and messages, with no em dashes.
- Keep comments rare and short.

## Commits

Commit messages are `type: subject`: lowercase, imperative, under 72 characters, no scope and no body. Types are `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`, `build` and `revert`. Branches are named `type/short-kebab-description`.

Commits on `main` must be signed.

By contributing you agree that your contributions are licensed under the [MIT licence](LICENSE).
