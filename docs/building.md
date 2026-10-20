# Building from source

Building needs Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [jq](https://jqlang.org), git and about 10 GB free; `make setup` checks them first and prints one `brew install` line for anything missing.

```bash
make setup        # first run: build the pinned idb frameworks, then swift build
swift build       # build the offsider executable
swift test        # unit tests; simulator suites are skipped
./test-runner.sh  # on a terminal, pick which end-to-end suites to run
make e2e          # run the simulator end-to-end suites (./test-runner.sh --simulator)
make e2e-devices  # show the E2E simulator and AVDs, and create the missing ones
make e2e-android  # run the Android emulator end-to-end suites on Offsider_E2E, booted if needed
make e2e-rn-ios   # run the React Native playground suites on a simulator (needs pnpm)
make e2e-foldable # run the foldable suite on the iPhone Duo simulator OFFSIDER_FOLDABLE_SIMULATOR_NAME names (default "Offsider Duo")
make e2e-android-fold  # run the foldable suite on the AVD OFFSIDER_ANDROID_FOLD_AVD names (default Offsider_E2E_Fold)
make e2e-android-phone  # run the phone suites on the one allowed USB phone
make e2e-ios-device     # run the device suites on the one allowed iPhone or iPad
```

- `make setup` runs `./scripts/build.sh dev`, then `swift build`. `dev` builds the idb frameworks once per clone behind six progress lines, logging to `.build/idb-build.log` (`--verbose` streams it instead), and ends with `Next: swift build`. It reuses a `build_products/` that matches the pin and this Xcode, here or in another checkout of the repository (`git worktree list`), and `--rebuild` builds anyway. `./scripts/build.sh` alone prints where to start; `help` lists every step.
- `./test-runner.sh --help` lists the modes and `--help-env` the settings, suite names and examples. With no mode on a terminal it asks which suites to run (the phone and iPhone modes need a device you allowed and are never the default); otherwise it runs `--simulator`.
- `scripts/e2e-devices.sh` shows the devices the suites drive and offers to create the missing ones: the AVDs `Offsider_E2E` and `Offsider_E2E_Fold` and the `Offsider Duo` simulator. `create` makes them without asking. It never boots them or touches another device, and `scripts/e2e-devices-core.sh status|create [--dry-run]` does the same in JSON for scripts. A mode whose device is missing names `scripts/e2e-devices.sh create`.
- `make e2e-android` (`./test-runner.sh --android`) drives `OFFSIDER_ANDROID_E2E_AVD` (default `Offsider_E2E`), booting it with `offsider boot` when it is not running; `OFFSIDER_ANDROID_DEVICE` names another serial or AVD. `make e2e-android-fold` boots its AVD the same way.
- `test-runner.sh` loads a git-ignored `.env` from the repository root first, so the simulator and AVD names for your machine (`OFFSIDER_SIMULATOR_NAME`, `OFFSIDER_FOLDABLE_SIMULATOR_NAME`, `OFFSIDER_ANDROID_E2E_AVD`, `OFFSIDER_ANDROID_FOLD_AVD`) can live there; see `.env.example`.
- `make e2e-foldable` sets `OFFSIDER_FOLDABLE_E2E=1` and runs `FoldableTests` on an iPhone Duo simulator, folding and unfolding it with `offsider posture`. `make e2e-android-fold` sets `OFFSIDER_ANDROID_FOLD_E2E=1` and `OFFSIDER_ANDROID_E2E_AVD=Offsider_E2E_Fold`; the Android suites drive only that AVD and `Offsider_E2E`.
- `make e2e-android-phone` (`./test-runner.sh --android-phone`) runs the `AndroidPhone*Tests` suites on one USB phone, and refuses beside `OFFSIDER_ANDROID_E2E`. You must allow the phone first: run `offsider device-access allow` with the build the runner tests (it prints that path), choose it, pin `com.mpalmes.offsider.playground.rn` and allow at least 2 hours. Without `OFFSIDER_ANDROID_PHONE=<serial>`, the runner uses the one active Android phone on the allow-list only when its allowance pins `com.mpalmes.offsider.playground.rn`, so a phone allowed for another app is never driven, checks the allowance with the built binary (it must last at least 30 more minutes) and otherwise says what to choose and stops. It installs the React Native playground APK on that phone and leaves it there; Google Play Protect may ask on the phone to send the app for a security check on the first install, so answer it there.
- `make e2e-ios-device` (`./test-runner.sh --ios-device`) sets `OFFSIDER_IOS_DEVICE_E2E=1` and runs the device suites on the one active iPhone or iPad on the allow-list whose allowance pins `com.mpalmes.offsider.playground` (`OFFSIDER_IOS_DEVICE=<UDID>` names one otherwise), signing the runner with the team its allowance records (`OFFSIDER_IOS_TEAM_ID` serves only when it names none); the device must be on its cable, unlocked, with UI Automation on, and allowed with the playground pinned: run `offsider device-access allow`, choose the device and a team, pin `com.mpalmes.offsider.playground` and allow at least 2 hours.
- `make e2e-rn-debug-ios` and `make e2e-rn-debug-android` build the React Native debug app, run Metro on loopback port 8742 and run the debug smoke suite. `pnpm --dir OffsiderPlaygroundRN ios <udid>` or `android <serial|avd>` installs the debug app and runs it from the same background Metro (`scripts/rn-playground.sh metro stop` ends it).

<details>
<summary>Goldens, timings and benchmarks</summary>

Committed, scrubbed trees of the React Native playground live in `Tests/Goldens/trees/`, with a byte budget per screen in `budgets.json`: `swift test` fails when a `--summary` or `--format text` rendering outgrows its budget, or when a budget sits more than 20 percent above it. After a mapping or renderer change, `OFFSIDER_GOLDENS_UPDATE=1 swift test --filter TreeGoldenRefresh` re-renders them offline; `Tests/Goldens/README.md` covers recapturing from a device.

`OFFSIDER_TIMINGS=1` prints phase timings for a command to stderr, as `offsider timing: <phase> <n> ms` lines; a phase that repeats prints one line each time.

- `tree-cache` is a tree cache read or write, `tree-diff` the `--diff` comparison and `settle` the transition guard's wait and second read.
- Android commands add `prepare`, `adb-devices`, `adb-shell`, `display-probe`, `display-status` (the displays and posture), `warm-screen` (the same from the warm helper), `helper-launch`, `dex-push`, `helper-hello`, `helper-attach` (reaching the warm helper's broker), `broker-start` (starting one), `helper-dump`, `tree-map`, `helper-close`, `helper-inject` (input through the helper), `helper-capture` (a helper screenshot), `capture-encode` (encoding raw pixels as PNG on the Mac), `grpc-connect`, `grpc-call`, `input` and `capture`.
- A phone adds `foreground-recheck`, the app check that follows input in the same command (on an iPhone or iPad, the first check of a command is `foreground`).
- A simulator adds `prepare`, `simulator-set`, `accessibility`, `orientation`, `screen-info`, `hid-attach` (reaching the warm input session), `hid-send` (one input through it), `hid-session` (opening an input session of the command's own) and `capture`.
- An iPhone or iPad adds `runner` (connecting to or starting the runner), `accessibility` (the runner's snapshot), `session` (connecting to or starting the session broker), `stream-capture` (a frame from the broker's stream) and `capture` (a `devicectl` screenshot). The broker writes its own `stream-open` and `stream-frame` lines to `ios-devices/<UDID>/session.log` when the command that started it had `OFFSIDER_TIMINGS=1`.

`scripts/bench-ab.sh --device <id> --scenario android-describe` compares a base build (the merge base with `origin/main` by default, built once in a detached worktree under `$TMPDIR`) with this checkout on one Offsider device, in paired runs whose order comes from `--seed`. Each Android sample first reads the screen, untimed, 2 s before, as an agent's previous command would; the checkout's warm helper is stopped before every base sample, and `android-describe-first` and `android-tap-id-first` stop it before the checkout's samples too, timing a first command, as `ios-tap-id-first` and `ios-tap-xy-first` do with the simulator's input session. The checkout's warm sessions are stopped when the run ends. Pairs whose exit code or output differ are dropped; the summary gives medians per side and per phase, a bootstrap 95% interval of the change and a verdict (`faster`, `slower`, `same` within 5% or 10 ms, or `unresolved`). Records go to `${OFFSIDER_BENCH_DIR:-$TMPDIR/offsider-bench}` as hashes, never output, and only Offsider-named simulators and the Offsider E2E AVDs are driven. `--phone --device <serial> --scenario android-tap-xy` (or another `android-*` scenario) benchmarks a USB phone instead: the serial must match an `adb devices -l` row with `usb:` and state `device`, and the React Native playground must already be installed, as bench never installs it. `--help` lists the scenarios.

</details>

`OffsiderCore` builds with strict memory safety checking (Swift tools 6.2). CI also runs the unit tests under AddressSanitizer, and a weekly job fuzzes the parsers: `OFFSIDER_FUZZ=1 swift build --product OffsiderFuzz --sanitize=address` builds the fuzz driver (it exists only with that variable, so releases never hold it), and `.build/debug/OffsiderFuzz --list` names its targets ([CONTRIBUTING.md](../CONTRIBUTING.md#fuzzing)).

The simulator frameworks come from [michael-palmes/idb](https://github.com/michael-palmes/idb), a mirror of facebook/idb with Cameron Cooke's Xcode 27 changes on the `offsider/xcode27` branch (tag `offsider-idb-v0.2.0`). `scripts/build.sh` pins the exact revision and verifies it before building.

The iPhone runner's source is in `Sources/Offsider/Resources/runner/`: an XcodeGen `project.yml` with the generated `OffsiderRunner.xcodeproj` committed beside it. After changing `project.yml`, run `scripts/build.sh runner` to regenerate the project, and `scripts/build.sh runner --check` regenerates it and compares it with the committed project. Both need XcodeGen.

The Android helper's Java source is in `AndroidHelper/`, and its compiled dex is committed, so `swift build` needs no JDK. Only when you change `AndroidHelper/`, rebuild it with `scripts/build.sh helper` (or `make helper`), which needs JDK 17 (`OFFSIDER_HELPER_JDK`, `JAVA_HOME` or `/usr/libexec/java_home -v 17`) and the Android SDK's build-tools 37.0.0 and android-37.0 platform, and commit the dex and manifest with the source. `scripts/build.sh helper --check` (or `make helper-check`) rebuilds it and compares it with the committed dex, as CI does.
