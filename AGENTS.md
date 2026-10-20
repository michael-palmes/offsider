# Offsider agent guide

Offsider: a hand for your agent on iOS and Android, simulated or real. A Swift CLI that inspects and drives iOS Simulators, Android Emulators and USB iPhones, iPads and Android phones (describe the UI, tap, type, swipe, capture) for terminals and AI agents.

IMPORTANT: Prefer retrieval-led reasoning over pre-training-led reasoning for Swift Testing, swift-argument-parser, idb/FBSimulatorControl, grpc-swift-2 and adb server protocol tasks.

## Role

You are a macOS tooling engineer maintaining a small, local-only Swift CLI built on Xcode private frameworks and the Android SDK's local daemons. Priorities, in order: correct device input, honest and actionable errors, and nothing leaves the Mac.

Dead simple, secure by default. Performance, security and privacy are the focuses, delivered with no effort from the developer: one command, nothing to look up or paste, a picker for every choice, a spinner over every pause, secure defaults nobody has to choose, and every dead end naming its fix in one line. Use words anyone understands and as few as possible: people do not read.

## Origin

Offsider began as a fork of AXe (`cameroncooke/axe`) v1.8.0 and is developed independently. Nothing flows either way: no upstream remote, syncs or cherry-picks from AXe, and no PRs, issues or patches to AXe or `cameroncooke/idb`. Keep AXe's credit in `LICENSE`, `NOTICE.md` and `README.md`.

## Quick reference

| Aspect | Guidance |
| --- | --- |
| Toolchain | Swift 6.4; `Package.swift` declares `swift-tools-version:6.2`, every target in Swift 5 language mode, `OffsiderCore` with strict memory safety (mark each unsafe call `unsafe`) |
| Platform | Apple silicon (arm64) only; `Package.swift` targets macOS 26, and releases need macOS 26 or later; Xcode 27 is the target |
| CLI | swift-argument-parser: one `AsyncParsableCommand` per file |
| Tests | Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), never XCTest |
| Simulator stack | idb's FBSimulatorControl, FBControlCore, FBDeviceControl and XCTestBootstrap, built by `scripts/build.sh` from the `michael-palmes/idb` fork at the pinned revision, linked from `build_products/XCFrameworks` |
| Private headers | Compile-only, from `idb_checkout/PrivateHeaders`; never shipped |
| Android stack | `OffsiderAndroid` (never imports idb), for emulators and USB phones: a Swift adb server client over loopback plus the emulator gRPC service (grpc-swift-2, generated code checked in from a trimmed proto) |
| iOS device stack | `OffsiderIOSDevice` (never imports idb), for USB iPhones and iPads: `devicectl` for listing, settings and fallback screenshots; on Xcode 27 a detached per-device session broker (`offsider device-session serve`, Unix socket under the private `sessions/`) holding the CoreDevice screen stream, UniversalHID touch and keyboard reports and the HID button socket; and an XCUITest runner reached over usbmuxd |
| Android toolchain | Android SDK with Platform-Tools and the Emulator, found through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk` or `adb` on `PATH`; `arm64-v8a` images, tested on API 36 |
| Android helper | Java 8 in `AndroidHelper/src/`, compiled by `scripts/build.sh helper` (JDK 17, build-tools 37.0.0 d8, android-37.0) to a committed dex and manifest in `Sources/Offsider/Resources/helper/`; pushed through a 0700 folder and SHA-256 checked by its start script on every start (size only without `sha256sum`); run with `app_process` as the shell user, kept warm between commands on emulators by a detached broker (`offsider android-session serve`, Unix socket under the private `sessions/`); Swift-only work needs no JDK |
| Fixture app | `OffsiderPlaygroundApp` (XcodeGen `project.yml`) |
| RN fixture app | `OffsiderPlaygroundRN`: Expo SDK 57, pnpm 11, same screens and ids for iOS and Android; `/ios`, `/android` and `/build` are generated and git-ignored; dev Metro on 8742 |

## Commands

| Command | Purpose |
| --- | --- |
| `make setup` | First run: `./scripts/build.sh dev`, then `swift build` |
| `./scripts/build.sh dev [--rebuild] [--verbose]` or `make frameworks` | Check the tools (Xcode 26+, XcodeGen, jq, git, 10 GB), clone idb at the pin and build the XCFrameworks, reusing a `build_products/` that matches the pin and Xcode here or in another worktree; logs to `.build/idb-build.log` behind a row per step (`--verbose` streams), `--rebuild` always builds; run once per clone before `swift build` |
| `swift build` | Build the `offsider` executable |
| `swift test` | Unit tests; no simulator needed, E2E suites skip |
| `./scripts/build.sh help` | List build steps (`setup`, `clean`, `generate`, `frameworks`, `install`, `strip`, `xcframeworks`, `dev`, `executable`, `verify-xcframeworks`, `verify-arches`, `helper`, `runner`); bare `./scripts/build.sh` prints where to start |
| `./scripts/build.sh helper` or `make helper` | Rebuild the Android helper dex and manifest after changing `AndroidHelper/`; refuses toolchain drift |
| `./scripts/build.sh helper --check` or `make helper-check` | Rebuild the helper and compare it with the committed dex and manifest, as CI does |
| `scripts/release.sh rehearse --version X --adhoc` | Stage, sign, package, verify and Homebrew-gate a local build without secrets; without `--version` it uses `git describe`'s |
| `scripts/release.sh pack-payload`, `unpack-payload`, `unpack-archive` | Move the unsigned payload and the signed archive between the release workflow's build, sign and verify jobs |
| `make e2e` or `./test-runner.sh --simulator` | Rebuild idb (unless `OFFSIDER_REUSE_IDB=1`), build Offsider and the playground, run simulator E2E suites (needs XcodeGen) |
| `./test-runner.sh` | On a person's terminal, a mode picker (phone and iPhone modes never the default); otherwise, and always for an agent, `--simulator`. `--help` lists modes, `--help-env` settings, suites and examples |
| `scripts/e2e-devices.sh [status\|create]` or `make e2e-devices` | Show the E2E devices (`Offsider_E2E`, `Offsider_E2E_Fold`, the `Offsider Duo` simulator) and create the missing ones; never boots them. `scripts/e2e-devices-core.sh status\|create [--dry-run]` is its JSON core |
| `./test-runner.sh --unit-tests` | Build dependencies, then run non-E2E tests |
| `./test-runner.sh --tests-only` | Run E2E against an existing binary (`OFFSIDER_BIN_PATH`) |
| `./test-runner.sh --android` or `make e2e-android` | Build Offsider and run the Android E2E suites on `OFFSIDER_ANDROID_DEVICE` (default `OFFSIDER_ANDROID_E2E_AVD`, booted if not running) |
| `./test-runner.sh --foldable` or `make e2e-foldable` | Build Offsider and the playground, run `FoldableTests` on the iPhone Duo simulator `OFFSIDER_FOLDABLE_SIMULATOR_NAME` names (default `Offsider Duo`, or `SIMULATOR_UDID`) |
| `./test-runner.sh --android-fold` or `make e2e-android-fold` | Build Offsider and run `AndroidFoldableTests` on the AVD `OFFSIDER_ANDROID_FOLD_AVD` names (default `Offsider_E2E_Fold`, booted if not running) |
| `./test-runner.sh --android-phone` or `make e2e-android-phone` | Build Offsider and run the `AndroidPhone*Tests` suites on one USB phone: the one active allowance, only when it pins `com.mpalmes.offsider.playground.rn`, or `OFFSIDER_ANDROID_PHONE=<serial>` (only when the user names it and has allowed it with `offsider device-access allow`) |
| `./test-runner.sh --ios-device` or `make e2e-ios-device` | Build Offsider and run the `IOSDevice*E2ETests` suites on one wired iPhone or iPad, with the device and team from its allowance, picked only when it pins `com.mpalmes.offsider.playground` (`OFFSIDER_IOS_DEVICE=<udid>` and `OFFSIDER_IOS_TEAM_ID=<team>` override them; only when the user names it and has allowed it with the playground pinned); input, tree and runner suites skip while its screen is off |
| `./test-runner.sh --rn-ios` or `make e2e-rn-ios` | Build Offsider and the RN playground, run the React Native suites on a simulator (needs pnpm) |
| `./test-runner.sh --rn-ios --rn-debug` or `--android --rn-debug` | Build the RN debug app, start Metro on 8742 and run the debug smoke suite (`make e2e-rn-debug-ios`, `make e2e-rn-debug-android`) |
| `scripts/generate-emulator-grpc.sh [--check]` or `make grpc-generate` | Regenerate the emulator gRPC client from the vendored proto; `--check` compares with the checked-in code |
| `scripts/rn-playground.sh build-ios` or `build-android` | Build the RN playground Release app or arm64 APK; `--debug` builds the debug app, `--if-changed` skips an up-to-date build (`help` lists install, launch and paths) |
| `scripts/rn-playground.sh metro start\|stop\|status` | Run Metro for the RN debug app on loopback port 8742 |
| `pnpm --dir OffsiderPlaygroundRN typecheck` | Typecheck the RN playground |
| `pnpm --dir OffsiderPlaygroundRN android <serial>` or `ios <udid>` | Starts Metro on loopback 8742 in the background (`metro stop` ends it), installs the RN debug build if changed and launches it from Metro; Android also takes an AVD name and sets the adb reverse; `--screen <id>` opens a fixture; refuses to run without a named device |
| `scripts/bench-ab.sh --device <id> --scenario <name>` | Compare the merge base with this checkout on one Offsider device in paired, seeded runs (`--help` lists scenarios); `--phone` acknowledges that `--device` names a USB phone (playground installed first, never by bench) |
| `bash -n <script>` | Syntax-check a changed shell script |
| `OFFSIDER_FUZZ=1 swift build --product OffsiderFuzz --sanitize=address` | Build the fuzz driver (never in a release); `.build/debug/OffsiderFuzz --list`, `<target> Tests/Fixtures/fuzz/<target> --seconds 60`, `<target> --replay <file>` |
| `ASAN_OPTIONS=strip_env=0 swift test --sanitize=address --no-parallel` | Unit tests under AddressSanitizer, as CI's non-required job runs them; without `strip_env=0` every exit test's child aborts |

Agents building in parallel use `swift build --scratch-path <dir>` and `swift test --scratch-path <dir>` so they do not block each other; `BundleIntegrityTests` passes only in the default `.build` folder.

| Variable | Effect |
| --- | --- |
| `OFFSIDER_E2E=1` | Enables simulator E2E suites in `swift test` |
| `OFFSIDER_LANDSCAPE_E2E=1` | Adds landscape precision suites (needs `OFFSIDER_E2E=1`) |
| `OFFSIDER_BIN_PATH` | Prebuilt `offsider` for `--tests-only`; its `Frameworks/` must sit beside it |
| `OFFSIDER_REUSE_IDB=1` | `test-runner.sh` runs `build.sh dev` instead of `dev --rebuild`, reusing a `build_products/` that matches the pin and Xcode (here or in another worktree) |
| `SIMULATOR_UDID` | Pins E2E runs to one simulator |
| `OFFSIDER_SIGNING_IDENTITY` | Developer ID identity for `scripts/release.sh`; set it in git-ignored `.env` (copy `.env.example`) |
| `OFFSIDER_RN_E2E=1` | Enables the React Native suites on iOS (`test-runner.sh --rn-ios` sets it) |
| `OFFSIDER_RN_IOS_APP` | The React Native playground's Release `.app` the iOS suites install |
| `OFFSIDER_RN_DEBUG_E2E=1` | Enables the RN debug smoke suite (`--rn-debug` sets it; needs Metro on 8742) |
| `OFFSIDER_RN_IOS_DEBUG_APP`, `OFFSIDER_ANDROID_DEBUG_APK` | The RN playground's debug builds for the debug smoke suite |
| `OFFSIDER_ANDROID_E2E=1` | Enables the Android E2E suites in `swift test` (`test-runner.sh --android` sets it) |
| `OFFSIDER_ANDROID_DEVICE` | The E2E emulator's serial or AVD name (default `OFFSIDER_ANDROID_E2E_AVD`, which `--android` boots if needed) |
| `OFFSIDER_ANDROID_APK` | The React Native playground's release APK the Android suites install |
| `OFFSIDER_ANDROID_E2E_AVD` | The only AVD Android E2E may drive (default `Offsider_E2E`) |
| `OFFSIDER_ANDROID_FOLD_AVD` | The fold AVD `--android-fold` drives (default `Offsider_E2E_Fold`) |
| `OFFSIDER_SIMULATOR_NAME`, `OFFSIDER_FOLDABLE_SIMULATOR_NAME` | The simulator names `test-runner.sh` picks for the simulator and foldable suites (defaults: a stock iPhone, `Offsider Duo`); `SIMULATOR_UDID` overrides both. `test-runner.sh` loads a git-ignored `.env` first, so machine-specific names live there (see `.env.example`) |
| `OFFSIDER_ANDROID_LANDSCAPE_E2E=1` | Adds the Android landscape suite (Settings) |
| `OFFSIDER_ANDROID_BOOT_E2E=1` | Adds the cold `boot` test, which stops and restarts the E2E AVD |
| `OFFSIDER_FOLDABLE_E2E=1` | Enables `FoldableTests` on the iPhone Duo simulator named by `SIMULATOR_UDID` |
| `OFFSIDER_ANDROID_FOLD_E2E=1` | Enables `AndroidFoldableTests` (needs `OFFSIDER_ANDROID_E2E_AVD` set to the fold AVD) |
| `OFFSIDER_ANDROID_PHONE` | The exact USB serial the `AndroidPhone*Tests` suites drive (an `adb devices -l` row with `usb:` and state `device`; refused beside `OFFSIDER_ANDROID_E2E`); unset, `--android-phone` uses the one active Android allowance, only when it pins `com.mpalmes.offsider.playground.rn` |
| `OFFSIDER_IOS_DEVICE_E2E=1` | Enables the `IOSDevice*E2ETests` suites in `swift test` (`test-runner.sh --ios-device` sets it) |
| `OFFSIDER_IOS_DEVICE` | The exact UDID the iOS device suites drive (a physical iOS or iPadOS row in `devicectl list devices`; never a simulator); unset, `--ios-device` uses the one active iPhone or iPad allowance, only when it pins `com.mpalmes.offsider.playground` |
| `OFFSIDER_IOS_TEAM_ID` | The team (10 letters and digits) that signs the runner and the OffsiderPlaygroundApp for a device; used only when the allowance names no team, or the same one (another team exits 64), and `--ios-device` reads the allowance's team the same way; required when the allowance names none; Xcode's signed-in team is never picked silently |
| `OFFSIDER_IOS_RUNNER_PREFIX` | The iPhone runner's bundle id prefix (default `com.mpalmes.offsider`; apps `<prefix>.runner` and `<prefix>.runner.uitests`; reverse-DNS, at most 100 characters, else exit 64); part of the runner cache key |
| `OFFSIDER_ANDROID_TRANSPORT` | `adb` or `grpc` forces one Android transport (troubleshooting) |
| `OFFSIDER_ANDROID_GRPC_AUTH` | `jwt` makes gRPC use a short-lived signing key instead of the discovery token |
| `OFFSIDER_ANDROID_TREE` | `helper` or `uiautomator` forces one Android tree source (troubleshooting); default `auto` |
| `OFFSIDER_ANDROID_SESSION` | `auto` (default: emulators keep the helper warm, phones start one per command), `on` (allowed phones too) or `off` (one helper per command) |
| `OFFSIDER_ANDROID_SESSION_IDLE` | Seconds the warm helper stays after the last command (default 60, at most 3600); a broker stops after 12 hours at its next idle moment |
| `OFFSIDER_ANDROID_INPUT` | `helper` or `input` forces how input reaches a device without gRPC; default `auto` (the helper only when the command already runs it) |
| `OFFSIDER_ANDROID_CAPTURE` | `screencap`, `raw` or `helper` forces how a device without gRPC is captured; `raw` and `helper` fall back to `screencap -p`; default `auto` (`screencap -p`) |
| `OFFSIDER_SIMULATOR_SESSION` | `on` (default) keeps each simulator's input session warm between commands through its HID broker; `off` opens one per command (`touch --down` or `--up` alone still uses the broker) |
| `OFFSIDER_SIMULATOR_SESSION_IDLE` | Seconds a simulator's warm input session stays after the last command (default 60, at most 3600); a broker stops after 12 hours at its next idle moment |
| `OFFSIDER_IOS_RUNNER_IDLE` | Seconds an iPhone runner session stays up after its last request (default 300, at most 3600); a session is restarted after 12 hours |
| `OFFSIDER_IOS_SESSION_IDLE` | Seconds an iPhone or iPad session broker stays up after its last command (default 300, at most 3600); a broker stops after 12 hours at its next idle moment |
| `OFFSIDER_GOLDENS_UPDATE=1` | Re-renders the tree goldens offline (`--filter TreeGoldenRefresh`), or recaptures them with the RN device variables (`--filter TreeGoldenCaptureTests`); rewrites the screen goldens in `Tests/Goldens/screens/` (`--filter ScreenGoldenTests`) |
| `OFFSIDER_TREE_CACHE` | `off` stops reading and writing the per-device tree cache under the private directory's `trees/` (`describe-ui --diff`, the tap guard and batch read steps then see no earlier tree or input) |
| `OFFSIDER_DISPLAY_CACHE` | `off` stops reading and writing the per-phone display cache under the private directory's `displays/` (a foldable phone's active panel, its size and device state, so the next capture skips the display reads) |
| `OFFSIDER_DEVICE` | The default `--device` for device commands (an explicit `--device` wins; blank is unset); it never names a physical device (exit 64: a phone, iPhone or iPad needs `--device` on each command); `test-runner.sh` and test child processes unset it |
| `OFFSIDER_LEASE` | The label of this session's `lease set`; when set, `doctor`'s `device.lease` passes only when it matches. Unset, a lease passes for any later command of the session that set it |
| `OFFSIDER_RUN` | `off` keeps captures out of any evidence run (`test-runner.sh`, `bench-ab.sh` and test helpers set it); `<dir>` records into that folder whatever the session |
| `OFFSIDER_WAIT_LOCK` | Default seconds to wait for a device another Offsider command holds (`--wait-lock` wins; `test-runner.sh` sets 30) |
| `OFFSIDER_TIMINGS=1` | Prints iOS and Android phase timings to stderr (`offsider timing: <phase> <n> ms`) |
| `OFFSIDER_MASK_SECURE` | `screenshot` and `batch` mask password fields by default; `0`, `false`, `no` or `off` turns that default off (and the video password check outside a run), `1`, `true`, `yes` or `on` keeps it; a capture's or batch's `--mask-secure` or `--no-mask-secure` wins, and a run's mask is never dropped |
| `OFFSIDER_BENCH_DIR` | Where `scripts/bench-ab.sh` writes its records (default `$TMPDIR/offsider-bench`) |
| `OFFSIDER_OUTPUT` | `person` or `agent` overrides who reads the output; else `CLAUDE_CODE_CHILD_SESSION` or `AI_AGENT` (set, not `0`; never `CLAUDECODE`) means an agent, else stdout that is not a terminal. An agent gets stdout unchanged, one prefixed stderr line per note, no colour codes, spinners, pickers or `export` hints, and quoted screen names, and needs a person for `--no-mask-secure`, `OFFSIDER_MASK_SECURE=0` and `describe-ui --raw-source`; a person gets the styled view (`UI_ASCII=1` for ASCII, `COLUMNS` for a width). `swift test` runs as an agent, so suites asserting person output use the `.personOutput` trait |
| `OFFSIDER_FUZZ` | `1` at build time adds the `OffsiderFuzz` product (debug builds only) |
| `OFFSIDER_FUZZ_TARGET` | The fuzz target `OffsiderFuzz` runs when its first argument names none |
| `OFFSIDER_HELPER_JDK` | JDK 17 home for `scripts/build.sh helper` (else `JAVA_HOME`, then `/usr/libexec/java_home -v 17`) |

## Layout

| To change | Go to |
| --- | --- |
| A command | `Sources/Offsider/Commands/<Name>.swift`; register new ones in `Sources/Offsider/main.swift` |
| Pure logic with no idb import | `Sources/OffsiderCore/` (fast unit tests); `Agents/` for `init`'s permission rules, `Mask/` for `offsider.mask.json`, `Process/UntrustedRead.swift` for every read of a file another program writes |
| Android backend | `Sources/OffsiderAndroid/` (pure parsers stay `internal`, tests use `@testable import`); unit tests in `Tests/Android/`, E2E in `Tests/AndroidE2E/` |
| iOS device backend | `Sources/OffsiderIOSDevice/` (depends on `OffsiderCore` only); CLI glue in `Sources/Offsider/Platform/IOSDevice/`; unit tests and devicectl fixtures in `Tests/IOSDevice/` |
| iPhone runner | `Sources/Offsider/Resources/runner/` (`project.yml` and the generated `OffsiderRunner.xcodeproj`); regenerate with `scripts/build.sh runner` |
| Android helper (Java) | `AndroidHelper/src/`; never edit the dex or manifest in `Sources/Offsider/Resources/helper/` by hand |
| HID broker, accessibility resolution, errors | `Sources/Offsider/Utilities/` |
| Terminal output and prompts | `Sources/OffsiderCore/Terminal/`: `Console` (the one writer), `Page`, `Table`, `PersonRenderer`, `AgentRenderer`, screens such as `DevicesScreen`, and prompts (`TerminalUI`, `PromptScreen`); goldens in `Tests/Goldens/screens/`; scripts use `scripts/lib/ui.sh` |
| The skill `offsider init` installs | `Sources/Offsider/Resources/skills/offsider/SKILL.md` (a router under 10 KB); topics `offsider guide` prints are `references/<topic>.md` beside it, listed in `Types/GuideTopic.swift` |
| Version string | `Plugins/VersionPlugin` (generates git-ignored `Version.swift`) |
| Tests | `Tests/<Name>Tests.swift`; E2E fixture screens in `OffsiderPlaygroundApp/` |
| RN suites (iOS and Android) | `Tests/ReactNativeE2E/`; one test body runs on each enabled platform through `RNApp` |
| Test fakes | `Tests/FakeDeviceBackend.swift` (scripted trees and screenshots, read counts) |
| RN fixture screens | `OffsiderPlaygroundRN/src/screens/` (one per file); `Readout`, `Target` and the header marker in `src/fixtures.tsx` |
| Build, release, goldens | `scripts/` |
| CI and releases | `.github/workflows/ci.yml`, `.github/workflows/release.yml` |
| Project skills | `.agents/skills/` (`.claude/skills` is a relative symlink to it) |

A command or option change also updates `docs/commands.md` (and the `docs/` page that covers it), the bundled `SKILL.md` and `CHANGELOG.md` (under `## [Unreleased]`: Added, Changed, Fixed, Removed; released sections are immutable).

## Simulator caveats

- Xcode 27 has no Simulator.app; simulators run under Device Hub. Quit Simulator.app before E2E runs.
- `offsider boot <name or UDID>` boots a simulator through FBSimulatorControl and prints its UDID; emulator options exit 64 for one.
- Resolve Xcode through `xcode-select -p` or `DEVELOPER_DIR`, never a hard-coded path. Offsider refuses a developer directory that is not `<Xcode>.app/Contents/Developer` of an Apple-signed app (exit 9 `xcode_unusable`).
- Input commands, setters and `batch` lock the device for their run (exit 8, `device_busy`, when another holds it); locks live under `offsider-<uid>/locks/` in the `confstr` user temp directory.
- Most HID commands are fire-and-forget: they confirm dispatch, not effect. Verify with `--verify` on `tap`, `type`, `key` and `button` (exit 5 when nothing changes), or with `describe-ui` or `screenshot`; `slider` always checks its own result. When input seems ignored, run `offsider doctor --device <DEVICE_ID>` to check Device Hub, Resize Mode and dtuhidd.
- The HID broker serves a per-user Unix socket under `$TMPDIR/offsider-hid-<uid>`, rejects peers running as another user or from another Offsider build (code signature), and keeps a simulator's input session warm until 60 s after the last command. After simulator E2E or a manual check, `offsider session stop --device <UDID>` closes it.
- A private API break is fixed by moving the idb pin, never by patching `idb_checkout/`.
- An iPhone Duo simulator, named by `OFFSIDER_FOLDABLE_SIMULATOR_NAME` (default `Offsider Duo`), is the foldable fixture; `offsider posture` folds and unfolds it through the hinge service, so `FoldableTests` runs unattended. The Duo refuses orientation changes.

## Physical iPhone caveats

- Drive an iPhone or iPad only when the user names its UDID; never pick one from `devices`. Reading its `devicectl` row is fine.
- Every physical device must first be on the allow-list: the user runs `offsider device-access allow` in their own terminal, chooses the device, a team and `com.mpalmes.offsider.playground` from its menus, then Touch ID or their password. Tell them which device and app to choose by name, never an id to paste. Agents never run `allow`, never edit `~/.config/offsider/allowed-devices.json` and never add a bypass; `test-runner.sh` checks the list and says what to choose.
- Offsider never pairs a device or accepts a prompt on it, and refuses Wi-Fi connections (`device_not_wired`); keep it that way, USB only through usbmuxd.
- The runner source lives under `Sources/Offsider/Resources/runner`; after changing `project.yml`, regenerate the committed project with `scripts/build.sh runner` and check it with `scripts/build.sh runner --check`.
- Never type, store or ask for an iPhone passcode; a locked device fails with `device_locked`.
- One session broker per device, started by the first command that needs it; it needs a GUI login session on the Mac (over plain ssh, screenshots use `devicectl` and input the runner). Never start one on the user's own phone unless they name its UDID.
- Offsider never registers a device with a team on its own; only a person runs `offsider runner build --device <udid> --register-device`.
- After device E2E or a manual check, run `offsider session stop --device <udid>`: it stops the broker and the runner and clears the device's screen-sharing indicator. `--clean` also uninstalls the runner apps and deletes this device's runner builds and logs.

## Android emulator caveats

- Launch emulators only through `offsider boot`, or with neither `-port` nor a bare `-grpc`: `-port` leaves no gRPC endpoint, and a bare `-grpc` binds `[::]` with no auth. Always pass `-no-metrics`.
- `boot --emulator-arg` takes only the flags in `EmulatorArguments.allowed`, each value checked, and refuses Offsider's own flags (`ownedFlags`) and everything else. Never add a listener, port, gRPC, metrics, network or host-path flag to the allow-list, nor `webcam` to the camera values.
- Start the adb server with `ADB_MDNS=0`, so it sends no multicast on the LAN.
- A physical phone is often attached to this Mac and must never be targeted: agents, scripts and E2E drive only the Offsider AVDs and simulators, and a phone only when the user names it and has run `offsider device-access allow` and chosen it themselves. Reading its `adb devices -l` row is fine; never send it a command. Offsider never sets `adb reverse`.
- E2E and manual checks drive only the AVDs `OFFSIDER_ANDROID_E2E_AVD` and `OFFSIDER_ANDROID_FOLD_AVD` name (defaults `Offsider_E2E` and `Offsider_E2E_Fold`), and check the AVD name first (`adb -s <serial> emu avd name`); never send anything to another emulator, which may be someone's work device.
- Never bundle adb (Android SDK licence 3.4) or use Google's Android CLI (telemetry on by default). Use the SDK the user installed.
- The gRPC JWT issuer is `gradle-utp-emulator-control`, with the method path as `aud` and no `typ` header; never `android-studio`.
- `permission`, `status-bar` and `biometric` change state that outlives the command on both platforms, as `stay-awake` does on Android; E2E suites reset what they set, and Android permission resets are per app (never `pm reset-permissions`).
- React Native E2E saves test users only for the RN playground's app id, refuses to start when that id already has saved users, and removes them and their sign-in records afterwards.
- Never type, pipe or ask for a device's unlock code: the user saves it with `offsider unlock-code set` in their own terminal. `wake --unlock` types a saved code once; never loop on it.
- On an emulator the helper stays warm, holding Android's single UiAutomation slot with `accessibility_enabled` reading 1, until 60 s after the last command; on a phone only while one command runs, unless `OFFSIDER_ANDROID_SESSION=on`. Its broker, like the other two, admits only this Offsider build, by code signature. After Android E2E or a manual check, run `offsider session stop --device <serial>` so other UiAutomation clients can connect. Keep its reflection to the four UiAutomation members and the display probe with its public fallback; never implement a hidden Binder interface.

## Collaboration

Ask focused multiple-choice questions when a decision materially changes the implementation: `AskUserQuestion` in Claude Code, `request_user_input` in Codex. Read every comment on a GitHub issue (`gh issue view <n> --comments`) before acting on it.

When the user must run something themselves, put the complete command in the ask itself, on its own line in a code block: the absolute path when it is not on `PATH`, every value filled in, nothing to look up. Never a fragment such as `device-access allow`, never "the command above" (a summarised message loses it), never a placeholder promised later. One command per ask, one line saying what it will prompt for, then read the result back before the next step. The same rule binds the hints Offsider prints and the bundled skill: a busy developer will not read a paragraph.

## Committing

**Always use the `offsider-commit` skill** to review and create commits; never hand-roll `git commit`. Do not push unless asked. Use `offsider-skill-creator` for any change under `.agents/skills/`.

Branch names are `type/short-kebab-description` (for example `fix/tap-landscape-offset`). Never a `claude/` or other tool prefix, never a generated suffix; rename such a branch with `git branch -m` before the first commit.

## Writing rules

- Keep `AGENTS.md` and `CLAUDE.md` byte-identical: edit both together and verify with `cmp -s AGENTS.md CLAUDE.md`.
- All text is modern Australian English (spelling and usage, never slang: no "G'day", no "mate"), short, sharp and warm, with no em dashes: use commas, colons, parentheses or full stops. On screen: a title of at most eight words, no intro sentences, questions of at most five words, rows of at most five words plus a dim detail, and nothing the person does not act on.
- Comments are a last resort: one line max, only for context the code cannot show.
- Write tests that can fail for a reason we care about: assert behaviour and contracts, mock boundaries only, never restate implementation.

## Public repository: privacy

The repository is public, and so are its PRs, issues and releases.

- Never commit or post local device ids (serials, UDIDs, CoreDevice ids, panel ids), Apple team IDs, simulator or AVD names from the maintainer's machine, personal device models or local paths.
- Never commit or post anything from the private apps the maintainer tests on: names, bundle ids, screens, labels, testIDs, copy or data. Call them "private apps".
- Use placeholders (`<udid>`, `<serial>`, `/Users/me`) and the playground's own ids instead.
- Issues found by testing a private app reach the repo rewritten: brief sub-agents with the rewritten version, and invent the labels, ids, copy, coordinates and log lines a fix and its tests need (or use the playground's). Name none of the app's SDKs or their log formats, and never call it a field case in code, tests or messages. The leak gate checks only its deny-list, so before committing grep the diff and messages for the issue's own words, numbers and device names.
- PR descriptions, comments and release notes follow the same rule.
- The private deny-list lives outside the repo (`~/.config/offsider/private-denylist.txt` or `$OFFSIDER_PRIVATE_DENYLIST`); never copy its terms anywhere. `scripts/leak-gate.sh` checks staged changes, commit ranges and messages against it, and CI runs it on every pull request.

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
- ⚠️ **Ask first**: adding a dependency; changing `entitlements.plist` or `entitlements-adhoc.plist`; changing the idb pin; changing `release.yml` or `scripts/release.sh`; touching `Package.swift` platforms; changing the vendored emulator proto, its generated gRPC code or the gRPC package pins; changing the helper's toolchain pins (JDK major, build-tools, `android.jar`) or its wire protocol; adding emulator launch flags to `boot`; removing code or behaviour that looks intentional.
- 🚫 **Never**:
  - Commit secrets or signing material (`.p12`, `.p8`, `.env`, `keys/`). Keep them in `.env` and GitHub secrets.
  - Add an `axe` alias or compatibility shim. Document `offsider` instead.
  - Reference private notes or internal roadmap stages in the repo. Describe the change itself.
  - Use `--no-verify`. Fix what the hook reports.
  - Sign with `codesign --deep`. Sign nested code inside-out, frameworks first.
  - Connect to non-loopback addresses, resolve hostnames or send telemetry. Offsider may use Unix sockets and loopback TCP to local developer daemons (the adb server and the Android Emulator); nothing leaves the Mac.
  - Edit files under `idb_checkout/`. Move the pin instead.
