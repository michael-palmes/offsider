# Contributing to Offsider

Thanks for your interest. Offsider is a small, independently maintained project that began as a fork of [AXe](https://github.com/cameroncooke/axe), so a few things work differently from a typical project.

## Before you start

- **Offsider is independent of AXe.** Report Offsider problems and ideas here, not to the AXe project.
- **Issues are welcome.** Use the issue templates and include your macOS, Xcode and `offsider --version` details.
- **Pull requests may be declined** if they do not fit Offsider's scope: a local-only CLI for driving iOS Simulators from terminals and agents. Opening an issue first avoids wasted work.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Set up

You need an Apple silicon Mac and Xcode 26 or later. Then:

```bash
make setup   # checks the tools, builds the pinned idb frameworks, then swift build
```

A missing tool gets one `brew install` line to run. For the E2E suites, `scripts/e2e-devices.sh` shows and creates the simulator and AVDs they drive, and `./test-runner.sh` on its own asks which suites to run.

## Checks before you open a pull request

```bash
swift build
swift test                   # unit tests, no simulator needed; includes the tree goldens and their byte budgets
bash -n <changed script>     # for any shell script you touched
make e2e                     # for changes to input, accessibility or capture, on a booted simulator
```

A change to the iOS or Android tree mapping or to the `describe-ui` renderer shows up in the tree goldens under `Tests/Goldens/trees/`. Re-render them with `OFFSIDER_GOLDENS_UPDATE=1 swift test --filter TreeGoldenRefresh` and review the diff. A rendering that outgrows its budget fails; raising the budget is a reviewed edit of `Tests/Goldens/trees/budgets.json`.

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

### Protected paths signed

A pull request that changes `.github/allowed_signers`, `.github/CODEOWNERS`, `.github/workflows/release.yml`, `.github/workflows/signers.yml`, `scripts/release.sh`, `entitlements.plist` or `entitlements-adhoc.plist` must have its head commit signed by a key listed in the base branch's `.github/allowed_signers`. The `Protected paths signed` check enforces it, using the base branch's copy of the workflow, so a pull request cannot change the rule it is checked by. A Dependabot pull request that touches one of these files, such as a bumped action in `release.yml`, fails that check until the maintainer re-signs its head commit (for example `git commit --amend --no-edit -S` on the branch, then a force push).

Physical-device suites (`--android-phone`, `--ios-device`) need the device to be allowed first, by you in your own terminal: `offsider device-access allow --device <ID>`. `test-runner.sh` checks and prints the exact command.

By contributing you agree that your contributions are licensed under the [MIT licence](LICENSE).
