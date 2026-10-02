# Changelog

All notable changes to Offsider are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Android commands that read the screen finish sooner: once the UiAutomation helper confirms `quit`, Offsider closes it without waiting up to 1 s for its exit or sending `kill`.
- Android `type --replace` no longer runs a `wm size`, `wm density` and `dumpsys input` shell before the helper sets the text. Input reads the display only when it first needs it, so `--verify` and `batch` reuse what the helper already measured.

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
