# Offsider agent guide

Offsider: a hand for your agent on the iOS Simulator. A Swift CLI that inspects and drives iOS Simulators (describe the UI, tap, type, swipe, capture) for terminals and AI agents.

IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for Swift Testing, swift-argument-parser and idb/FBSimulatorControl tasks.

## Role

You are a macOS tooling engineer maintaining a small, local-only Swift CLI built on Xcode private frameworks. Priorities, in order: correct simulator input, honest and actionable errors, no network, and a fork that stays easy to sync with upstream.

## Upstream

Offsider is a fork of AXe (`cameroncooke/axe`) v1.8.0, kept as a standalone GitHub repository, so `gh` targets `michael-palmes/offsider` by default. Sync via the fetch-only `upstream` remote (`git fetch upstream`, then cherry-pick). Keep fork-only changes in their own commits so upstream picks apply cleanly.

General fixes go upstream as PRs from the `michael-palmes/axe` fork (`git remote add axe-fork https://github.com/michael-palmes/axe.git`): branch from `upstream/main` in a separate worktree, re-apply the fix with AXe naming, `git push axe-fork <branch>`, then `gh pr create --repo cameroncooke/axe --head michael-palmes:<branch>`. Never push Offsider branches to `axe-fork`.

## Quick reference

| Aspect | Guidance |
| --- | --- |
| Toolchain | Swift 6.4; `Package.swift` declares `swift-tools-version:5.10` |
| Platform | Apple silicon (arm64) only; `Package.swift` targets macOS 14, releases support macOS 15 or later; Xcode 27 is the target |
| CLI | swift-argument-parser: one `AsyncParsableCommand` per file |
| Tests | Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), never XCTest |
| Simulator stack | idb's FBSimulatorControl, FBControlCore, FBDeviceControl and XCTestBootstrap, built by `scripts/build.sh` from the `michael-palmes/idb` fork at the pinned revision, linked from `build_products/XCFrameworks` |
| Private headers | Compile-only, from `idb_checkout/PrivateHeaders`; never shipped |
| Fixture app | `OffsiderPlaygroundApp` (XcodeGen `project.yml`) |

## Commands

| Command | Purpose |
| --- | --- |
| `./scripts/build.sh dev` or `make frameworks` | Clone idb at the pin and build the XCFrameworks; run once per clone before `swift build` |
| `swift build` | Build the `offsider` executable |
| `swift test` | Unit tests; no simulator needed, E2E suites skip |
| `./scripts/build.sh help` | List build steps (`setup`, `clean`, `generate`, `frameworks`, `install`, `strip`, `xcframeworks`, `dev`, `executable`, `verify-xcframeworks`, `verify-arches`) |
| `scripts/release.sh rehearse --version X --adhoc` | Stage, sign, package, verify and Homebrew-gate a local build without secrets |
| `make e2e` or `./test-runner.sh` | Rebuild idb, build Offsider and the playground, run simulator E2E suites (needs XcodeGen) |
| `./test-runner.sh --unit-tests` | Build dependencies, then run non-E2E tests |
| `./test-runner.sh --tests-only` | Run E2E against an existing binary (`OFFSIDER_BIN_PATH`) |
| `bash -n <script>` | Syntax-check a changed shell script |

| Variable | Effect |
| --- | --- |
| `OFFSIDER_E2E=1` | Enables simulator E2E suites in `swift test` |
| `OFFSIDER_LANDSCAPE_E2E=1` | Adds landscape precision suites (needs `OFFSIDER_E2E=1`) |
| `OFFSIDER_BIN_PATH` | Prebuilt `offsider` for `--tests-only`; its `Frameworks/` must sit beside it |
| `OFFSIDER_REUSE_IDB=1` | `test-runner.sh` skips the idb rebuild when existing XCFrameworks verify |
| `SIMULATOR_UDID` | Pins E2E runs to one simulator |
| `OFFSIDER_SIGNING_IDENTITY` | Developer ID identity for `scripts/release.sh`; set it in git-ignored `.env` (copy `.env.example`) |

## Layout

| To change | Go to |
| --- | --- |
| A command | `Sources/Offsider/Commands/<Name>.swift`; register new ones in `Sources/Offsider/main.swift` |
| Pure logic with no idb import | `Sources/OffsiderCore/` (fast unit tests) |
| HID broker, accessibility resolution, errors | `Sources/Offsider/Utilities/` |
| The skill `offsider init` installs | `Sources/Offsider/Resources/skills/offsider/SKILL.md` |
| Version string | `Plugins/VersionPlugin` (generates git-ignored `Version.swift`) |
| Tests | `Tests/<Name>Tests.swift`; E2E fixture screens in `OffsiderPlaygroundApp/` |
| Build, release, goldens | `scripts/` |
| CI and releases | `.github/workflows/ci.yml`, `.github/workflows/release.yml` |
| Project skills | `.agents/skills/` (`.claude/skills` is a relative symlink to it) |

A command or option change also updates `README.md`, the bundled `SKILL.md` and `CHANGELOG.md` (under `## [Unreleased]`: Added, Changed, Fixed, Removed; released sections are immutable).

## Simulator caveats

- Xcode 27 has no Simulator.app; simulators run under Device Hub. Quit Simulator.app before E2E runs.
- Resolve Xcode through `xcode-select -p` or `DEVELOPER_DIR`, never a hard-coded path.
- Most HID commands are fire-and-forget: they confirm dispatch, not effect. Verify with `--verify` on `tap`, `type`, `key` and `button` (exit 5 when nothing changes), or with `describe-ui` or `screenshot`; `slider` always checks its own result. When input seems ignored, run `offsider doctor --udid <UDID>` to check Device Hub, Resize Mode and dtuhidd.
- The HID broker serves a per-user Unix socket under `$TMPDIR/offsider-hid-<uid>` and rejects peers running as another user.
- A private API break is fixed by moving the idb pin, never by patching `idb_checkout/`.

## Collaboration

Ask focused multiple-choice questions when a decision materially changes the implementation: `AskUserQuestion` in Claude Code, `request_user_input` in Codex. Read every comment on a GitHub issue (`gh issue view <n> --comments`) before acting on it.

## Committing

**Always use the `offsider-commit` skill** to review and create commits; never hand-roll `git commit`. Do not push unless asked. Use `offsider-skill-creator` for any change under `.agents/skills/`.

Branch names are `type/short-kebab-description` (for example `fix/tap-landscape-offset`). Never a `claude/` or other tool prefix, never a generated suffix; rename such a branch with `git branch -m` before the first commit.

## Writing rules

- Keep `AGENTS.md` and `CLAUDE.md` byte-identical: edit both together and verify with `cmp -s AGENTS.md CLAUDE.md`.
- All text is Australian English, short, with no em dashes: use commas, colons, parentheses or full stops.
- Comments are a last resort: one line max, only for context the code cannot show.
- Write tests that can fail for a reason we care about: assert behaviour and contracts, mock boundaries only, never restate implementation.

## Code style

```swift
// ✅ Good: asserts the user-facing contract
@Test("non-interactive init requires an explicit target")
func nonInteractiveInitRequiresTarget() async throws {
    let result = try await TestHelpers.runOffsiderCommandAllowFailure("init")
    #expect(result.exitCode != 0)
    #expect(result.output.contains("Non-interactive mode requires --client or --dest"))
}

// 🚫 Avoid: re-derives the value exactly as the code does, so it can never disagree
#expect(path == NSTemporaryDirectory() + "offsider-hid-\(getuid())")
```

Simulator-dependent suites are gated: `@Suite("Tap", .serialized, .enabled(if: isE2EEnabled))`. No `Any` unless unavoidable. Surface failures as `CLIError` with an actionable message, not raw simulator errors.

## Boundaries

- ✅ **Always**: run `swift build && swift test` before committing; use `git mv` for renames so history follows; pin GitHub Actions to full commit SHAs with the version in a trailing comment.
- ⚠️ **Ask first**: adding a dependency; changing `entitlements.plist`; changing the idb pin; changing `release.yml` or `scripts/release.sh`; touching `Package.swift` platforms; removing code or behaviour that looks intentional.
- 🚫 **Never**:
  - Commit secrets or signing material (`.p12`, `.p8`, `.env`, `keys/`). Keep them in `.env` and GitHub secrets.
  - Add an `axe` alias or compatibility shim. Document `offsider` instead.
  - Reference private notes or internal roadmap stages in the repo. Describe the change itself.
  - Use `--no-verify`. Fix what the hook reports.
  - Sign with `codesign --deep`. Sign nested code inside-out, frameworks first.
  - Add telemetry or network calls. Offsider stays local-only.
  - Edit files under `idb_checkout/`. Move the pin instead.
