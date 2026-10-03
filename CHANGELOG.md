# Changelog

All notable changes to Offsider are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `describe-ui --summary` prints one line per on-screen node that has a label, id or value. `--flat`, `--on-screen`, `--labelled`, `--actionable`, `--fields`, `--format json|ndjson|text` and `--compact` shape the output; without them it is unchanged.
- `screenshot --scale points|<factor>`, `--region x,y,w,h` (in points), `--format png|jpeg`, `--quality` and `--json`.
- `screenshot --compare <baseline>` with `--threshold` reports how much of the capture changed and exits 0 when it changed, 5 when it did not.
- `wait` waits until an element is on screen or `--gone`, the screen is `--settled`, a `--region` is `--changed` or `--stable`, or `--seconds` pass, and exits 5 on timeout; `--settled` on a screen whose accessibility tree is never readable fails and suggests `--settle-by screen`. `assert` checks once and exits 5 when the element is not on screen, is not gone, or lacks `--has-value`.
- `batch` runs `wait`, `assert`, `screenshot` and `describe-ui` as steps, and `batch --json` prints one NDJSON line per step and a summary line. A batch whose only failures are unmet conditions exits 5.
- `tap` warns when another element may cover its target, and `--fail-if-covered` fails instead of tapping.
- `tap` treats a React Native LogBox banner as covering the strip beneath it on Android, where the accessibility tree cannot see its touch area.
- `logs` prints recent device log entries or collects live ones, with `--rn` for React Native output, `--app`, `--process`, `--predicate` (iOS), `--grep`, `--max-lines`, `--raw` and `--json`. Live output stops with an error when the device's log stream exits, for example on a bad `--predicate`.
- `appearance`, `content-size` and `orientation` read or set the device's appearance, text size and orientation on iOS and Android; `shake` sends the shake gesture on iOS. On Android, `appearance` reads `auto` or `custom` when night mode follows a schedule, and setting light or dark replaces it.
- `rn prepare --bundle-id <id>` marks an Expo dev client's first-launch dev menu intro as seen and stops the menu opening at launch, so a fresh debug install opens straight into the app (iOS simulators; Android debuggable builds through `run-as`). It stops the app first if it is running, on both platforms.
- `--allow-offscreen` on `tap`, `slider` and batch tap steps resolves an element whose frame is outside the screen.
- When no `--label` or `--value` matches exactly, typographic quotes and unusual spaces are folded, so `--label "Don't Allow"` finds `Don’t Allow`. A selector that matches nothing suggests the closest labels.
- `doctor` names the Xcode a running Simulator.app belongs to and, when it is not the selected one, suggests `DEVELOPER_DIR` before quitting it.
- `OFFSIDER_TIMINGS=1` prints phase timings to stderr.
- `orientation --rotation 0|90|180|270` sets the orientation in degrees anticlockwise from the display's natural orientation, and `orientation --json` prints `orientation`, `rotation`, `previous` and `screen`.
- `describe-ui` `screen` adds `rotation` (degrees anticlockwise from the active display's natural orientation), `display` (`{id, platformId}`: `main`, or `cover` or `inner` on a foldable) and `posture` (null unless the device folds); the `--summary` header adds the rotation, and the display and posture on a foldable. `screenshot --json` adds the same `rotation`, `display` and `posture`.
- `displays` lists a device's built-in displays with platform ID, size, scale, rotation and which one is active, then the posture; `--json`.
- `posture` reads a foldable's posture and active display, and sets `closed`, `half-opened` or `open`: on an Android emulator through the emulator, on the iPhone Duo simulator by driving its hinge (`--angle 0-180`), waiting until the display has swapped. Where an iOS runtime has no hinge service the command says so.
- On the iPhone Duo's inner display, `tap`, `swipe`, `drag` and `touch --down --up` reach the display through its own touchscreen; a detached `touch --down` or `--up` on it is refused with a message.
- `--display <id>` on `screenshot` captures one display of a foldable; on `describe-ui` it checks that the named display is the active one.
- Screenshots on the iPhone Duo simulator capture the active display: the cover display while folded, the inner display while open.
- A foldable E2E suite for the iPhone Duo simulator (`make e2e-foldable`, `OFFSIDER_FOLDABLE_E2E=1`) and one for a Pixel 9 Pro Fold emulator (`make e2e-android-fold`, `OFFSIDER_ANDROID_FOLD_E2E=1`).
- React Native playground screens for kept-mounted sheets, mounted stacks, overlays, unlabelled rows and environment readouts, with iOS suites (`make e2e-rn-ios`) and a typecheck in CI.

### Changed

- **Breaking, relative to the earlier entries in this section:** `orientation` names the device turn, as Maestro and devicectl do. `landscape-left` now means the device turned 90 degrees anticlockwise, with the home edge on the right (UIKit's interface orientation `landscape-right`), and `landscape-right` the reverse; they used to take UIKit's interface names.
- **Breaking, relative to the earlier entries in this section:** `describe-ui` `screen.orientation` and `screenshot --json` `orientation` are the shape, `portrait` or `landscape`; the turn is in the new `rotation`.
- Selectors prefer on-screen matches. A match whose frame lies outside the screen now fails with an error naming its frame, where `tap` used to report success, and `--wait-timeout` waits for it to come on screen. A duplicate label on a hidden view no longer counts as a second match. A partly visible element whose centre is off screen is tapped at the centre of its visible part.
- Every iOS landscape screenshot is now upright, with or without the new `screenshot` options.
- `batch` reads the screen again after any step that sends input or sleeps, so a selector step sees the screen its previous step opened. `--ax-cache none` is an alias of `perStep`.
- A multiple-match error lists each candidate's role, id and frame, and for a duplicated `--id` suggests `--element-type` or coordinates.
- A selector `tap` or `slider` that had to wait for its element also waits until the element stops moving, so a tap no longer lands on a sheet that is still sliding in.
- `tap --allow-offscreen` warns when its point is outside the screen.
- A `--wait-timeout` or `--poll-interval` on a batch tap step overrides the batch-level value for that step; it used to be ignored.
- `gesture` help says which way each scroll preset moves the content.
- `tap -x -y` outside the screen prints a warning, in batch steps too.
- `screenshot` prints the image size on its "saved" line.
- The React Native playground's Metro commands listen on loopback only: `pnpm start` passes `--localhost`, and `dev-ios`/`dev-android` run the background `metro start`, install a debug build and set the adb port reverse.

### Fixed

- Screenshots on the iPhone Duo simulator captured the inactive inner display while it was folded.
- `wait`, `assert` and `orientation` stop with an error when the device does not answer, where a hung simulator used to hang the command.
- A HID broker that exits just after accepting a connection is replaced, where the client used to fail with a socket error.
- A selector `tap` or `slider` on iOS reads the accessibility tree once, not twice.
- A failed selector `tap` prints its error once.

## [0.3.0] - 2026-10-02

### Added

- `list-devices` command: one row per device with PLATFORM, STATE, ID, NAME and OS columns.
- `list-devices --json` prints `{"version": 1, "devices": [...]}`, each device with `id`, `platform`, `state`, `name`, `osVersion` and `deviceType` (null when unknown).
- `list-devices --platform ios|android` lists one platform.
- Android Emulator support: `list-devices`, `describe-ui` (in dp), `tap`, `swipe`, `drag`, `gesture`, `touch`, `type`, `key`, `key-sequence`, `key-combo`, `button`, `screenshot`, `record-video`, `stream-video`, `batch` and `--verify` work with an emulator serial or a running AVD name. Offsider talks to the adb server and the emulator's gRPC endpoint on loopback, starts the adb server with mDNS off when none is running, and falls back to adb for emulators without gRPC.
- `type` on Android pastes text with non-ASCII characters through the emulator's clipboard, then restores the clipboard.
- `boot <avd>` starts an Android emulator (windowed, or `--headless`) with `-no-metrics`, waits until Android and its gRPC endpoint are ready and prints the serial; an AVD that is already running is not started again.
- `button back`, `app-switch`, `volume-up` and `volume-down` for Android; `lock` is the power key there.
- `OFFSIDER_ANDROID_TRANSPORT` (`adb` or `grpc`) and `OFFSIDER_ANDROID_GRPC_AUTH` (`jwt`) for troubleshooting Android transports.
- Android screen reads (`describe-ui`, selectors, `--wait-timeout`, `--verify`, `gesture` presets, `slider` and `type --replace`) go through a small UiAutomation helper that Offsider pushes to the emulator and runs for one command, about 0.3 s per `describe-ui` on a quiet Mac. When another UiAutomation client, such as Appium, holds the connection, the command fails and says so; when the helper cannot run, Offsider reads the screen with `uiautomator` instead, with a warning.
- `OFFSIDER_ANDROID_TREE` (`helper` or `uiautomator`) for troubleshooting Android screen reads.
- `slider` works on Android emulators through the accessibility progress action, falling back to a drag; a control whose steps cannot show the requested value reports the nearest step it reached.
- `type --replace` replaces the focused field's text on both platforms, also in batch steps, and an empty text clears it. iOS selects all with Command-A and deletes, then types; Android sets the text in one accessibility action (any Unicode, no gRPC needed) and presses Return for a trailing newline, falling back to Ctrl+A, Delete and typing.
- `scripts/build.sh helper` (`make helper`) rebuilds the Android helper's committed dex from `AndroidHelper/` with a pinned JDK 17, build-tools 37.0.0 and android-37.0; `--check` (`make helper-check`) compares it with the committed dex in CI, and release builds check the bundled dex against its manifest.
- React Native playground (`OffsiderPlaygroundRN`) for shared iOS and Android fixtures.

### Changed

- `--device <id>` replaces `--udid` on every command, including `doctor`. Pass an ID from `offsider list-devices`. The `doctor --json` report keeps its `udid` key.
- Device IDs are case-insensitive: a lowercase simulator UDID now reaches the same simulator.
- An ID that is neither a simulator UDID nor an Android serial or AVD name fails with a hint to run `offsider list-devices`.
- Offsider requires macOS 26 or later.
- Batch steps reject `--device` (and `--udid`); set the device once on `batch`.
- `list-devices` lists iOS simulators (iPhone and iPad), not the watchOS, tvOS and visionOS ones `list-simulators` listed, plus Android emulators and AVDs.
- `describe-ui` prints a versioned, platform-neutral schema: `{"version": 1, "platform", "device", "screen", "roots"}`, each node with `role`, `id`, `label`, `value`, `frame`, `enabled`, `state`, `native` and `children`, and every key present with `null` when unknown. `AXUniqueId`, `AXLabel` and `AXValue` become `id`, `label` and `value`; the iOS `type`, `role`, `role_description` and other attributes move under `native` in camelCase. `--point` returns the same envelope with one root.
- `--element-type` on `tap`, `slider` and batch taps matches the describe-ui `role` in any case (`button`, `slider`) or the native type exactly (`RadioButton`, `TextEditor`). `--element-type Button` now also matches `PopUpButton` elements.
- Text areas (`TextView` and `TextEditor`, role `textArea`) are actionable: `tap --label` prefers them over plain text with the same label, as it does for text fields.
- `--verify` compares the neutral tree. iOS change summaries are unchanged; a checked state change without a value change reads "checked state of X changed".
- Selector help and errors say id, label and value instead of AXUniqueId, AXLabel and AXValue, and `slider` reports `value:`.
- `--id` also matches the part of an Android resource id after `:id/` when no id matches exactly.
- Android trees add the keyboard window as a `keyboard` root, label the application root with the window title, report slider and progress values as percentages and tri-state checkboxes as `2`, and fill `stateDescription`, `roleDescription` and `testTag` (a Compose `testTag` is the `id` when there is no resource id).
- `--verify` leaves each platform's system bars out of screenshot comparisons: the status bar on iOS as before, and on Android the status and navigation bars as the helper measures them. A command that changed nothing suggests `doctor` only for simulators.
- `--verify` on Android reads the screen again as soon as an accessibility event follows the action, instead of waiting out each 200 ms poll; events only prompt the read, never decide the result.
- A `button` that the device's platform does not have exits 64 before touching the device.
- Tap summaries round points to 0.01 and name the selector, for example `Tap on id=BackButton at (22.1, 76.2)`.
- `type` normalises text to Unicode NFC, so an `e` followed by a combining acute accent types as one `é`.
- `record-video` and `stream-video` call their source a device, and their frame errors no longer mention a simulator.
- Help for `describe-ui`, `key`, `key-combo`, `key-sequence`, `gesture` and `batch` names emulators as well as simulators, or the device, instead of only a simulator. `batch --tap-style` help describes the styles as `tap --tap-style` does, and `gesture` and `swipe` help and errors give `--screen-width`, `--screen-height` and `--delta` in points (dp on Android) instead of points or pixels.

### Fixed

- `gesture` presets, on their own and as batch steps, fit the device and orientation: they are sized to the foreground app's frame from the accessibility tree instead of a fixed 390 x 844 point screen, and translated like `swipe` coordinates, so they land correctly in landscape and on every screen size. `--screen-width` and `--screen-height` still override the size, now in points (dp on Android) as the screen is currently oriented.
- `stream-video` now emits JPEG frames in the `mjpeg`, `raw` and `ffmpeg` formats at the default `--scale` and `--quality`. Previously those frames were PNG, labelled `image/jpeg` in the `mjpeg` stream.
- `batch` step failures now include the underlying error, such as an unsupported step, an invalid argument or an input failure, with or without `--continue-on-error`. Previously many read "The operation couldn't be completed".
- `doctor` details and other messages that wrap an Offsider error, such as a missing developer directory, now show that error's text instead of "The operation couldn't be completed".

### Removed

- `list-simulators`. Use `list-devices`; the old name exits 64 with a rename hint.
- `--udid`. Use `--device`; the old flag exits 64 with a rename hint.

## [0.2.0] - 2026-09-24

### Added

- `doctor` command: checks Xcode, Device Hub, CoreSimulator, HID stabilisation, the HID broker directory and booted simulators, and with `--udid` a simulator's state, Resize Mode, dtuhidd state and readiness, HID transport and accessibility. `--json` prints one object; `--fix` opens Device Hub or the device window and removes a stale broker directory. Exits 3 on warnings and 4 on failures.
- `--verify`, `--verify-timeout`, `--retries` and `--json` on `tap`, `type`, `key` and `button`: wait for an accessibility or screen change, retry (tap switches style), and exit 5 when nothing changes. Batch steps reject these flags.

### Fixed

- Input events are no longer discarded on Xcode 27. The bundled idb frameworks now wait for the simulator's HID daemon to be ready before the first event, so taps and keys land without `--post-delay`.

## [0.1.0] - 2026-09-24

First release of Offsider, forked from [AXe](https://github.com/cameroncooke/axe) v1.8.0 by Cameron Cooke. Changes up to the fork are recorded in [AXe's changelog](https://github.com/cameroncooke/axe/blob/v1.8.0/CHANGELOG.md).

### Added

- XcodeGen project for the playground fixture app, so the simulator end-to-end suites run from a clean clone.
- Signed and notarised release tarball, `offsider-<version>-arm64.tar.gz`, with a `SHA256SUMS` file and a GitHub build provenance attestation.
- Homebrew formula in the `michael-palmes/tap` tap.

### Changed

- Renamed the tool, Swift package, targets and executable to `offsider`.
- Renamed bundle identifiers, the HID broker's runtime paths, environment variables (now `OFFSIDER_*`) and the bundled agent skill (now `offsider`).
- Builds for Apple silicon (arm64) only.
- Builds the idb frameworks from the [michael-palmes/idb](https://github.com/michael-palmes/idb) mirror at a pinned revision.

### Fixed

- Shortened HID broker socket names so they stay within the Unix socket path limit.
- Builds now honour an explicit `OFFSIDER_VERSION` when generating the version string.

[Unreleased]: https://github.com/michael-palmes/offsider/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/michael-palmes/offsider/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/michael-palmes/offsider/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/michael-palmes/offsider/releases/tag/v0.1.0
