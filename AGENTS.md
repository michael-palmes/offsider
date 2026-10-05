# Offsider agent guide

Offsider: a hand for your agent on the iOS Simulator and the Android Emulator. A Swift CLI that inspects and drives iOS Simulators and Android Emulators (describe the UI, tap, type, swipe, capture) for terminals and AI agents.

IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for Swift Testing, swift-argument-parser, idb/FBSimulatorControl, grpc-swift-2 and adb server protocol tasks.

## Role

You are a macOS tooling engineer maintaining a small, local-only Swift CLI built on Xcode private frameworks and the Android SDK's local daemons. Priorities, in order: correct device input, honest and actionable errors, and nothing leaves the Mac.

## Origin

Offsider began as a fork of AXe (`cameroncooke/axe`) v1.8.0 and is developed independently. Nothing flows either way: no upstream remote, syncs or cherry-picks from AXe, and no PRs, issues or patches to AXe or `cameroncooke/idb`. Keep AXe's credit in `LICENSE`, `NOTICE.md` and `README.md`.

## Quick reference

| Aspect | Guidance |
| --- | --- |
| Toolchain | Swift 6.4; `Package.swift` declares `swift-tools-version:5.10` |
| Platform | Apple silicon (arm64) only; `Package.swift` targets macOS 26, and releases need macOS 26 or later; Xcode 27 is the target |
| CLI | swift-argument-parser: one `AsyncParsableCommand` per file |
| Tests | Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), never XCTest |
| Simulator stack | idb's FBSimulatorControl, FBControlCore, FBDeviceControl and XCTestBootstrap, built by `scripts/build.sh` from the `michael-palmes/idb` fork at the pinned revision, linked from `build_products/XCFrameworks` |
| Private headers | Compile-only, from `idb_checkout/PrivateHeaders`; never shipped |
| Android stack | `OffsiderAndroid` (never imports idb), for emulators and USB phones: a Swift adb server client over loopback plus the emulator gRPC service (grpc-swift-2, generated code checked in from a trimmed proto) |
| iOS device stack | `OffsiderIOSDevice` (never imports idb), for USB iPhones and iPads: `devicectl` for listing, settings and fallback screenshots; on Xcode 27 a detached per-device session broker (`offsider device-session serve`, Unix socket under the private `sessions/`) holding the CoreDevice screen stream, UniversalHID touch and keyboard reports and the HID button socket; and an XCUITest runner reached over usbmuxd |
| Android toolchain | Android SDK with Platform-Tools and the Emulator, found through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk` or `adb` on `PATH`; `arm64-v8a` images, tested on API 36 |
| Android helper | Java 8 in `AndroidHelper/src/`, compiled by `scripts/build.sh helper` (JDK 17, build-tools 37.0.0 d8, android-37.0) to a committed dex and manifest in `Sources/Offsider/Resources/helper/`; run with `app_process` as the shell user for one command; Swift-only work needs no JDK |
| Fixture app | `OffsiderPlaygroundApp` (XcodeGen `project.yml`) |
| RN fixture app | `OffsiderPlaygroundRN`: Expo SDK 57, pnpm 11, same screens and ids for iOS and Android; `/ios`, `/android` and `/build` are generated and git-ignored; dev Metro on 8742 |

## Commands

| Command | Purpose |
| --- | --- |
| `./scripts/build.sh dev` or `make frameworks` | Clone idb at the pin and build the XCFrameworks; run once per clone before `swift build` |
| `swift build` | Build the `offsider` executable |
| `swift test` | Unit tests; no simulator needed, E2E suites skip |
| `./scripts/build.sh help` | List build steps (`setup`, `clean`, `generate`, `frameworks`, `install`, `strip`, `xcframeworks`, `dev`, `executable`, `verify-xcframeworks`, `verify-arches`, `helper`) |
| `./scripts/build.sh helper` or `make helper` | Rebuild the Android helper dex and manifest after changing `AndroidHelper/`; refuses toolchain drift |
| `./scripts/build.sh helper --check` or `make helper-check` | Rebuild the helper and compare it with the committed dex and manifest, as CI does |
| `scripts/release.sh rehearse --version X --adhoc` | Stage, sign, package, verify and Homebrew-gate a local build without secrets |
| `make e2e` or `./test-runner.sh` | Rebuild idb, build Offsider and the playground, run simulator E2E suites (needs XcodeGen) |
| `./test-runner.sh --unit-tests` | Build dependencies, then run non-E2E tests |
| `./test-runner.sh --tests-only` | Run E2E against an existing binary (`OFFSIDER_BIN_PATH`) |
| `./test-runner.sh --android` or `make e2e-android` | Build Offsider and run the Android E2E suites (needs `OFFSIDER_ANDROID_DEVICE`) |
| `./test-runner.sh --foldable` or `make e2e-foldable` | Build Offsider and the playground, run `FoldableTests` on the `Offsider Duo iPhone` (or `SIMULATOR_UDID`) |
| `./test-runner.sh --android-fold` or `make e2e-android-fold` | Build Offsider and run `AndroidFoldableTests` on `Offsider_E2E_Pixel_9_Pro_Fold` |
| `OFFSIDER_ANDROID_PHONE=<serial> ./test-runner.sh --android-phone` or `make e2e-android-phone` | Build Offsider and run the `AndroidPhone*Tests` suites on that one USB phone (only when the user names it) |
| `OFFSIDER_IOS_DEVICE=<udid> OFFSIDER_IOS_TEAM_ID=<team> ./test-runner.sh --ios-device` or `make e2e-ios-device` | Build Offsider and run the `IOSDevice*E2ETests` suites on that one wired iPhone or iPad (only when the user names it); input, tree and runner suites skip while its screen is off |
| `./test-runner.sh --rn-ios` or `make e2e-rn-ios` | Build Offsider and the RN playground, run the React Native suites on a simulator (needs pnpm) |
| `./test-runner.sh --rn-ios --rn-debug` or `--android --rn-debug` | Build the RN debug app, start Metro on 8742 and run the debug smoke suite (`make e2e-rn-debug-ios`, `make e2e-rn-debug-android`) |
| `scripts/generate-emulator-grpc.sh [--check]` or `make grpc-generate` | Regenerate the emulator gRPC client from the vendored proto; `--check` compares with the checked-in code |
| `scripts/rn-playground.sh build-ios` or `build-android` | Build the RN playground Release app or arm64 APK; `--debug` builds the debug app, `--if-changed` skips an up-to-date build (`help` lists install, launch and paths) |
| `scripts/rn-playground.sh metro start\|stop\|status` | Run Metro for the RN debug app on loopback port 8742 |
| `pnpm --dir OffsiderPlaygroundRN typecheck` | Typecheck the RN playground |
| `pnpm --dir OffsiderPlaygroundRN android <serial>` or `ios <udid>` | Starts Metro on loopback 8742 in the background (`metro stop` ends it), installs the RN debug build if changed and launches it from Metro; Android also takes an AVD name and sets the adb reverse; `--screen <id>` opens a fixture; refuses to run without a named device |
| `scripts/bench-ab.sh --device <id> --scenario <name>` | Compare the merge base with this checkout on one Offsider device in paired, seeded runs (`--help` lists scenarios); `--phone` acknowledges that `--device` names a USB phone (playground installed first, never by bench) |
| `bash -n <script>` | Syntax-check a changed shell script |

| Variable | Effect |
| --- | --- |
| `OFFSIDER_E2E=1` | Enables simulator E2E suites in `swift test` |
| `OFFSIDER_LANDSCAPE_E2E=1` | Adds landscape precision suites (needs `OFFSIDER_E2E=1`) |
| `OFFSIDER_BIN_PATH` | Prebuilt `offsider` for `--tests-only`; its `Frameworks/` must sit beside it |
| `OFFSIDER_REUSE_IDB=1` | `test-runner.sh` skips the idb rebuild when existing XCFrameworks verify |
| `SIMULATOR_UDID` | Pins E2E runs to one simulator |
| `OFFSIDER_SIGNING_IDENTITY` | Developer ID identity for `scripts/release.sh`; set it in git-ignored `.env` (copy `.env.example`) |
| `OFFSIDER_RN_E2E=1` | Enables the React Native suites on iOS (`test-runner.sh --rn-ios` sets it) |
| `OFFSIDER_RN_IOS_APP` | The React Native playground's Release `.app` the iOS suites install |
| `OFFSIDER_RN_DEBUG_E2E=1` | Enables the RN debug smoke suite (`--rn-debug` sets it; needs Metro on 8742) |
| `OFFSIDER_RN_IOS_DEBUG_APP`, `OFFSIDER_ANDROID_DEBUG_APK` | The RN playground's debug builds for the debug smoke suite |
| `OFFSIDER_ANDROID_E2E=1` | Enables the Android E2E suites in `swift test` (`test-runner.sh --android` sets it) |
| `OFFSIDER_ANDROID_DEVICE` | The E2E emulator's serial or AVD name (required for Android E2E) |
| `OFFSIDER_ANDROID_APK` | The React Native playground's release APK the Android suites install |
| `OFFSIDER_ANDROID_E2E_AVD` | The only AVD Android E2E may drive (default `Offsider_E2E_Pixel_9`) |
| `OFFSIDER_ANDROID_LANDSCAPE_E2E=1` | Adds the Android landscape suite (Settings) |
| `OFFSIDER_ANDROID_BOOT_E2E=1` | Adds the cold `boot` test, which stops and restarts the E2E AVD |
| `OFFSIDER_FOLDABLE_E2E=1` | Enables `FoldableTests` on the iPhone Duo simulator named by `SIMULATOR_UDID` |
| `OFFSIDER_ANDROID_FOLD_E2E=1` | Enables `AndroidFoldableTests` (needs `OFFSIDER_ANDROID_E2E_AVD=Offsider_E2E_Pixel_9_Pro_Fold`) |
| `OFFSIDER_ANDROID_PHONE` | The exact USB serial the `AndroidPhone*Tests` suites drive (an `adb devices -l` row with `usb:` and state `device`; refused beside `OFFSIDER_ANDROID_E2E`) |
| `OFFSIDER_IOS_DEVICE_E2E=1` | Enables the `IOSDevice*E2ETests` suites in `swift test` (`test-runner.sh --ios-device` sets it) |
| `OFFSIDER_IOS_DEVICE` | The exact UDID the iOS device suites drive (a physical iOS or iPadOS row in `devicectl list devices`; never a simulator) |
| `OFFSIDER_IOS_TEAM_ID` | The team that signs the runner and the OffsiderPlaygroundApp for a device; required by `--ios-device` |
| `OFFSIDER_ANDROID_TRANSPORT` | `adb` or `grpc` forces one Android transport (troubleshooting) |
| `OFFSIDER_ANDROID_GRPC_AUTH` | `jwt` makes gRPC use a short-lived signing key instead of the discovery token |
| `OFFSIDER_ANDROID_TREE` | `helper` or `uiautomator` forces one Android tree source (troubleshooting); default `auto` |
| `OFFSIDER_ANDROID_INPUT` | `helper` or `input` forces how input reaches a device without gRPC; default `auto` (the helper only when the command already runs it) |
| `OFFSIDER_ANDROID_CAPTURE` | `screencap`, `raw` or `helper` forces how a device without gRPC is captured; `raw` and `helper` fall back to `screencap -p`; default `auto` (`screencap -p`) |
| `OFFSIDER_IOS_RUNNER_IDLE` | Seconds an iPhone runner session stays up after its last request (default 300) |
| `OFFSIDER_IOS_SESSION_IDLE` | Seconds an iPhone or iPad session broker stays up after its last command (default 300) |
| `OFFSIDER_GOLDENS_UPDATE=1` | Re-renders the tree goldens offline (`--filter TreeGoldenRefresh`), or recaptures them with the RN device variables (`--filter TreeGoldenCaptureTests`) |
| `OFFSIDER_TREE_CACHE` | `off` stops reading and writing the per-device tree cache under the private directory's `trees/` (`describe-ui --diff` and the tap guard then see no earlier tree) |
| `OFFSIDER_WAIT_LOCK` | Default seconds to wait for a device another Offsider command holds (`--wait-lock` wins; `test-runner.sh` sets 30) |
| `OFFSIDER_TIMINGS=1` | Prints iOS and Android phase timings to stderr (`offsider timing: <phase> <n> ms`) |
| `OFFSIDER_MASK_SECURE=1` | Makes `screenshot` and `batch` mask password fields as `--mask-secure` does |
| `OFFSIDER_BENCH_DIR` | Where `scripts/bench-ab.sh` writes its records (default `$TMPDIR/offsider-bench`) |
| `OFFSIDER_HELPER_JDK` | JDK 17 home for `scripts/build.sh helper` (else `JAVA_HOME`, then `/usr/libexec/java_home -v 17`) |

## Layout

| To change | Go to |
| --- | --- |
| A command | `Sources/Offsider/Commands/<Name>.swift`; register new ones in `Sources/Offsider/main.swift` |
| Pure logic with no idb import | `Sources/OffsiderCore/` (fast unit tests) |
| Android backend | `Sources/OffsiderAndroid/` (pure parsers stay `internal`, tests use `@testable import`); unit tests in `Tests/Android/`, E2E in `Tests/AndroidE2E/` |
| iOS device backend | `Sources/OffsiderIOSDevice/` (depends on `OffsiderCore` only); CLI glue in `Sources/Offsider/Platform/IOSDevice/`; unit tests and devicectl fixtures in `Tests/IOSDevice/` |
| iPhone runner | `Sources/Offsider/Resources/runner/` (`project.yml` and the generated `OffsiderRunner.xcodeproj`); regenerate with `scripts/build.sh runner` |
| Android helper (Java) | `AndroidHelper/src/`; never edit the dex or manifest in `Sources/Offsider/Resources/helper/` by hand |
| HID broker, accessibility resolution, errors | `Sources/Offsider/Utilities/` |
| The skill `offsider init` installs | `Sources/Offsider/Resources/skills/offsider/SKILL.md` (a router under 10 KB); topics `offsider guide` prints are `references/<topic>.md` beside it, listed in `Types/GuideTopic.swift` |
| Version string | `Plugins/VersionPlugin` (generates git-ignored `Version.swift`) |
| Tests | `Tests/<Name>Tests.swift`; E2E fixture screens in `OffsiderPlaygroundApp/` |
| RN suites (iOS and Android) | `Tests/ReactNativeE2E/`; one test body runs on each enabled platform through `RNApp` |
| Test fakes | `Tests/FakeDeviceBackend.swift` (scripted trees and screenshots, read counts) |
| RN fixture screens | `OffsiderPlaygroundRN/src/screens/` (one per file); `Readout`, `Target` and the header marker in `src/fixtures.tsx` |
| Build, release, goldens | `scripts/` |
| CI and releases | `.github/workflows/ci.yml`, `.github/workflows/release.yml` |
| Project skills | `.agents/skills/` (`.claude/skills` is a relative symlink to it) |

A command or option change also updates `README.md`, the bundled `SKILL.md` and `CHANGELOG.md` (under `## [Unreleased]`: Added, Changed, Fixed, Removed; released sections are immutable).

## Simulator caveats

- Xcode 27 has no Simulator.app; simulators run under Device Hub. Quit Simulator.app before E2E runs.
- Resolve Xcode through `xcode-select -p` or `DEVELOPER_DIR`, never a hard-coded path.
- Input commands, setters and `batch` lock the device for their run (exit 8, `device_busy`, when another holds it); locks live under `offsider-<uid>/locks/` in the `confstr` user temp directory.
- Most HID commands are fire-and-forget: they confirm dispatch, not effect. Verify with `--verify` on `tap`, `type`, `key` and `button` (exit 5 when nothing changes), or with `describe-ui` or `screenshot`; `slider` always checks its own result. When input seems ignored, run `offsider doctor --device <DEVICE_ID>` to check Device Hub, Resize Mode and dtuhidd.
- The HID broker serves a per-user Unix socket under `$TMPDIR/offsider-hid-<uid>` and rejects peers running as another user.
- A private API break is fixed by moving the idb pin, never by patching `idb_checkout/`.
- The `Offsider Duo iPhone` simulator (iPhone Duo) is the foldable fixture; `offsider posture` folds and unfolds it through the hinge service, so `FoldableTests` runs unattended. The Duo refuses orientation changes.

## Physical iPhone caveats

- Drive an iPhone or iPad only when the user names its UDID; never pick one from `list-devices`. Reading its `devicectl` row is fine.
- Offsider never pairs a device or accepts a prompt on it, and refuses Wi-Fi connections (`device_not_wired`); keep it that way, USB only through usbmuxd.
- The runner source lives under `Sources/Offsider/Resources/runner`; after changing `project.yml`, regenerate the committed project with `scripts/build.sh runner` and check it with `scripts/build.sh runner --check`.
- Never type, store or ask for an iPhone passcode; a locked device fails with `device_locked`.
- One session broker per device, started by the first command that needs it; it needs a GUI login session on the Mac (over plain ssh, screenshots use `devicectl` and input the runner). Never start one on the user's own phone unless they name its UDID.
- After device E2E or a manual check, run `offsider session stop --device <udid>`: it stops the broker and the runner and clears the device's screen-sharing indicator.

## Android emulator caveats

- Launch emulators only through `offsider boot`, or with neither `-port` nor a bare `-grpc`: `-port` leaves no gRPC endpoint, and a bare `-grpc` binds `[::]` with no auth. Always pass `-no-metrics`.
- Start the adb server with `ADB_MDNS=0`, so it sends no multicast on the LAN.
- A physical phone is often attached to this Mac and must never be targeted: agents, scripts and E2E drive only the Offsider AVDs and simulators, and a phone only when the user names its serial. Reading its `adb devices -l` row is fine; never send it a command. Offsider never sets `adb reverse`.
- E2E and manual checks drive only `Offsider_E2E_Pixel_9` and the foldable `Offsider_E2E_Pixel_9_Pro_Fold`, and check the AVD name first (`adb -s <serial> emu avd name`); never send anything to another emulator, which may be someone's work device.
- Never bundle adb (Android SDK licence 3.4) or use Google's Android CLI (telemetry on by default). Use the SDK the user installed.
- The gRPC JWT issuer is `gradle-utp-emulator-control`, with the method path as `aud` and no `typ` header; never `android-studio`.
- `permission`, `status-bar` and `biometric` change state that outlives the command on both platforms, as `stay-awake` does on Android; E2E suites reset what they set, and Android permission resets are per app (never `pm reset-permissions`).
- Never type, pipe or ask for a device's unlock code: the user saves it with `offsider unlock-code set` in their own terminal. `wake --unlock` types a saved code once; never loop on it.
- The helper holds Android's single UiAutomation slot only while one command runs, and `accessibility_enabled` reads 1 until it exits. Keep its reflection to the four UiAutomation members and the display probe with its public fallback; never implement a hidden Binder interface.

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

- ✅ **Always**: run `swift build && swift test` before committing; use `git mv` for renames so history follows; pin GitHub Actions to full commit SHAs with the version in a trailing comment; after editing `AndroidHelper/`, run `scripts/build.sh helper` and commit the dex and manifest with the source.
- ⚠️ **Ask first**: adding a dependency; changing `entitlements.plist`; changing the idb pin; changing `release.yml` or `scripts/release.sh`; touching `Package.swift` platforms; changing the vendored emulator proto, its generated gRPC code or the gRPC package pins; changing the helper's toolchain pins (JDK major, build-tools, `android.jar`) or its wire protocol; adding emulator launch flags to `boot`; removing code or behaviour that looks intentional.
- 🚫 **Never**:
  - Commit secrets or signing material (`.p12`, `.p8`, `.env`, `keys/`). Keep them in `.env` and GitHub secrets.
  - Add an `axe` alias or compatibility shim. Document `offsider` instead.
  - Reference private notes or internal roadmap stages in the repo. Describe the change itself.
  - Use `--no-verify`. Fix what the hook reports.
  - Sign with `codesign --deep`. Sign nested code inside-out, frameworks first.
  - Connect to non-loopback addresses, resolve hostnames or send telemetry. Offsider may use Unix sockets and loopback TCP to local developer daemons (the adb server and the Android Emulator); nothing leaves the Mac.
  - Edit files under `idb_checkout/`. Move the pin instead.
