# Offsider

A hand for your agent on the iOS Simulator and the Android Emulator.

[![CI](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml/badge.svg)](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/michael-palmes/offsider?sort=semver)](https://github.com/michael-palmes/offsider/releases/latest)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Offsider is a command-line tool that inspects and drives iOS Simulators and Android Emulators: describe the UI through accessibility, tap, type, swipe, press buttons and capture screenshots or video. It is built for terminals, scripts and AI coding agents, and it runs entirely on your Mac.

Offsider is a fork of [AXe](https://github.com/cameroncooke/axe) v1.8.0 by Cameron Cooke, used under the MIT licence. It is not endorsed by AXe's author. See [Licensing and attribution](#licensing-and-attribution).

## Install

### Homebrew

```bash
brew install michael-palmes/tap/offsider
```

### Verified tarball

Each release publishes `offsider-<version>-arm64.tar.gz`, a `SHA256SUMS` file and a GitHub build provenance attestation from `.github/workflows/release.yml`. The binary is signed with a Developer ID certificate and notarised.

```bash
VERSION=0.2.0
gh release download "v${VERSION}" --repo michael-palmes/offsider \
  --pattern "offsider-${VERSION}-arm64.tar.gz" --pattern SHA256SUMS
shasum -a 256 -c SHA256SUMS
gh attestation verify "offsider-${VERSION}-arm64.tar.gz" --repo michael-palmes/offsider
mkdir -p ~/.local/offsider && tar -xzf "offsider-${VERSION}-arm64.tar.gz" -C ~/.local/offsider
codesign -dv --verbose=4 ~/.local/offsider/offsider
```

Keep the `offsider` binary beside its `Frameworks/` directory and resource bundle, then put a symlink on your `PATH` rather than moving the binary:

```bash
mkdir -p ~/.local/bin
ln -s ~/.local/offsider/offsider ~/.local/bin/offsider   # ~/.local/bin must be on your PATH
offsider --version
```

## Requirements

- Apple silicon (arm64). Intel Macs are not supported.
- macOS 26 or later.
- Xcode 26 or later, selected with `xcode-select` or `DEVELOPER_DIR`. Tested on Xcode 27, where simulators run under Device Hub and Simulator.app is not required. Xcode is needed even if you only drive Android emulators, because the binary links the simulator frameworks.
- For Android: the Android SDK with Platform-Tools and the Android Emulator, and `arm64-v8a` system images (tested on API 36; the adb fallback needs API 33 or later). Offsider finds the SDK through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk` (where Android Studio installs it) or `adb` on your `PATH`.

## Quick start

```bash
# Find a booted simulator and keep its device ID
offsider list-devices
export DEVICE=<ID>

# Check Xcode, Device Hub and the simulator before driving it
offsider doctor --device "$DEVICE"

# Inspect the current screen, or the element at one point
offsider describe-ui --device "$DEVICE"
offsider describe-ui --point 200,400 --device "$DEVICE"

# Interact
offsider tap -x 200 -y 400 --device "$DEVICE"
offsider tap --id LoginButton --device "$DEVICE"
offsider tap --id LoginButton --verify --device "$DEVICE"   # exits 5 if nothing changes
offsider type 'Hello world' --device "$DEVICE"
offsider screenshot --output ./screen.png --device "$DEVICE"

# Install the Offsider skill for Claude Code
offsider init --client claude
```

On Android, start an emulator with `boot` (it prints the serial once Android has booted), then use the same commands:

```bash
offsider list-devices --platform android       # running emulators by serial, AVDs by name
DEVICE=$(offsider boot Pixel_9)                 # add --headless to hide the window
offsider describe-ui --device "$DEVICE"
offsider tap --id LoginButton --verify --device "$DEVICE"
offsider type 'héllo' --device "$DEVICE"
offsider button back --device "$DEVICE"
```

Most input commands confirm dispatch, not effect. Add `--verify` to `tap`, `type`, `key` or `button` to wait for an observable change (accessibility tree, then screenshot); the command exits 5 if nothing changes. `slider` always checks its value. If input seems to be ignored on a simulator, run `offsider doctor --device "$DEVICE"`.

## Commands

Every device command takes `--device <id>`, using an ID from `offsider list-devices`: a simulator UDID (case-insensitive), an Android emulator serial such as `emulator-5554`, or the name of a running AVD. Run `offsider <command> --help` for the full list of options.

`list-devices --json` prints one object with a schema version, for scripts and agents:

```json
{
  "version": 1,
  "devices": [
    {
      "id": "<ID>",
      "platform": "ios",
      "state": "Booted",
      "name": "iPhone 17 Pro",
      "osVersion": "iOS 27.0",
      "deviceType": "iPhone 17 Pro"
    }
  ]
}
```

In 0.3.0, `--udid` was renamed to `--device` and `list-simulators` to `list-devices`. The old names exit 64 with a hint.

| Command | What it does |
| --- | --- |
| `list-devices` | List iOS simulators (iPhone and iPad), running Android emulators and shut-down AVDs with their IDs as a table, or as JSON with `--json`; `--platform ios\|android` filters |
| `boot` | Start an Android emulator by AVD name and wait until it has booted, then print its serial (`--headless`, `--timeout`); an AVD that is already running is not started again |
| `doctor` | Check Xcode, Device Hub, CoreSimulator, HID settings and booted simulators, and with `--device` a simulator's state, Resize Mode, dtuhidd, HID transport and accessibility; `--json` prints one object, `--fix` applies safe fixes. Android checks are not in this release |
| `describe-ui` | Print the screen's UI as versioned, platform-neutral JSON, or only the element at `--point x,y` |
| `init` | Install the bundled agent skill (`--client auto\|claude\|agents`, `--dest`, `--force`, `--uninstall`, `--print`) |
| `tap` | Tap a point (`-x`, `-y`) or an element by `--id`, `--label` or `--value`; supports `--element-type`, `--wait-timeout`, `--tap-style`, delays and `--verify, --retries, --json` |
| `slider` | Set a slider to `--value` 0 to 100 by `--id` or `--label`, then verify the result |
| `type` | Type US keyboard text from an argument, `--stdin` or `--file`; supports `--verify, --retries, --json` |
| `swipe` | Swipe from `--start-x`/`--start-y` to `--end-x`/`--end-y`, with optional `--duration` and `--delta` |
| `drag` | Low-level point-to-point drag using explicit touch moves (`--duration`, `--steps`) |
| `gesture` | Run a preset: `scroll-up`, `scroll-down`, `scroll-left`, `scroll-right`, `swipe-from-left-edge`, `swipe-from-right-edge`, `swipe-from-top-edge`, `swipe-from-bottom-edge`. Presets fit the foreground app's frame in the current orientation; `--screen-width` and `--screen-height` override the size |
| `touch` | Send touch down and/or up at `-x`/`-y` (`--down`, `--up`, `--delay`) |
| `button` | Press a hardware button (optional `--duration`): on iOS `home`, `lock`, `side-button`, `siri`, `apple-pay`; on Android `back`, `app-switch`, `home`, `lock` (the power key), `volume-up`, `volume-down`. A button the device's platform lacks exits 64. Supports `--verify, --retries, --json` |
| `key` | Press one HID keycode (0 to 255), optionally held for `--duration`; supports `--verify, --retries, --json` |
| `key-sequence` | Press comma-separated `--keycodes` in order, with an optional `--delay` |
| `key-combo` | Press `--key` while holding comma-separated `--modifiers` |
| `batch` | Run ordered steps in one device session from `--step`, `--file` or `--stdin`; supports `--wait-timeout`, `--ax-cache`, `--continue-on-error` and `sleep` steps |
| `screenshot` | Save a PNG of the device display (`--output`) |
| `record-video` | Record the display to an H.264 MP4 until Ctrl+C (`--output`, `--fps`, `--quality`, `--scale`) |
| `stream-video` | Stream frames to stdout as `mjpeg`, `raw`, `ffmpeg` or `bgra` (`--format`, `--fps`, `--quality`, `--scale`) |

### describe-ui output

`describe-ui` prints one object. Every key is present, with `null` when a value is unknown, and `--point x,y` returns the same envelope with the element at that point as the only root. `screen` and frames are in points on iOS and dp on Android.

```json
{
  "version": 1,
  "platform": "ios",
  "device": "<ID>",
  "screen": { "width": 402, "height": 874, "scale": 3, "orientation": "portrait" },
  "roots": [
    {
      "role": "button",
      "id": "BackButton",
      "label": "Back",
      "value": null,
      "frame": { "x": 16, "y": 62, "width": 44, "height": 44 },
      "enabled": true,
      "state": { "checked": null, "selected": null, "focused": null },
      "native": { "type": "Button", "role": "AXButton", "subrole": null, "roleDescription": "back button", "title": null, "help": null, "customActions": [], "contentRequired": false, "pid": 4242, "axFrame": "{{16, 62}, {44, 44}}" },
      "children": []
    }
  ]
}
```

`role` is one of `application`, `window`, `group`, `other`, `button`, `link`, `menuItem`, `tab`, `tabBar`, `segmentedControl`, `text`, `header`, `image`, `progress`, `textField`, `secureTextField`, `searchField`, `textArea`, `switch`, `checkbox`, `radioButton`, `slider`, `picker`, `cell`, `list`, `scrollView` or `keyboard`.

| Field | iOS source | Android source (`uiautomator`) |
| --- | --- | --- |
| `id` | `AXUniqueId` (`accessibilityIdentifier`, or `testID` in React Native), else `AXIdentifier` | `resource-id` (`testID` in React Native) |
| `label` | `AXLabel` | `content-desc`, else the text of a non-editable node; a clickable node with neither takes its children's text |
| `value` | `AXValue`, as a string | A text field's text; `1` or `0` for switches, checkboxes and radio buttons |
| `frame`, `enabled` | The same keys | `bounds` over density / 160, `enabled` |
| `state.checked` | `switch` and `checkbox` only: `AXValue` `1` or `0` | `checked` for checkable nodes |
| `state.selected`, `state.focused` | Always `null` on iOS | `selected`, `focused` |
| `native` | `type`, `role`, `subrole`, `roleDescription`, `title`, `help`, `customActions`, `contentRequired`, `pid`, `axFrame` | `className`, `resourceId`, `package`, `pixelFrame`, `text`, `contentDescription`, `hint`, `stateDescription`, `roleDescription`, `testTag` |

`--id`, `--label` and `--value` match `id`, `label` and `value`; on Android, `--id alert_title` also matches `com.example:id/alert_title` when no id matches exactly. `--element-type` matches `role` in any case or the native `type` exactly, so `button`, `Button` and `RadioButton` all work.

### Android notes

- IDs are emulator serials (`emulator-5554`) or the names of running AVDs; `list-devices` shows both. `boot` starts an AVD with its window (`--headless` hides it), passes only `-no-metrics` to the emulator, writes the emulator's output to `$TMPDIR/offsider-boot-<avd>.log` and never starts a second instance of an AVD that is already running.
- Coordinates, frames and `--delta` are in dp, the Android equivalent of points.
- `describe-ui` reads the screen through `uiautomator` in this release: about 3 seconds per read, so `--wait-timeout` and `--verify` are slower than on iOS (a verified tap takes about 6 to 10 seconds). Another UiAutomation client, such as Appium or Maestro, makes it fail with a message saying so.
- `--verify` ignores the status bar and the navigation bar in screenshots. `--tap-style` and the `style` field keep their names: `simulator` is a single tap and `physical` a timed touch down and up.
- `type` sends ASCII text as key events. Text with any other character is pasted through the emulator's clipboard, which Offsider saves first and restores afterwards.
- Offsider talks to the adb server and to the emulator's gRPC endpoint on loopback. An emulator started with `-port` has no gRPC endpoint, so Offsider falls back to adb: screenshots are slower, `type` accepts ASCII only and `stream-video --format bgra` is unavailable.
- `stream-video --format bgra` sends a frame when the screen changes, not at a fixed rate, so a still screen sends one frame.
- `slider` and `doctor --device` do not support Android emulators yet.
- For troubleshooting, `OFFSIDER_ANDROID_TRANSPORT=adb` (or `grpc`) forces one transport, and `OFFSIDER_ANDROID_GRPC_AUTH=jwt` makes Offsider sign in to gRPC with a short-lived key instead of the emulator's token.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success; for `doctor`, every check passed or was skipped |
| 1 | The command failed; the error is printed to stderr |
| 3 | `doctor` found warnings |
| 4 | `doctor` found failures |
| 5 | `--verify`: the input was dispatched but nothing observable changed |
| 64 | Invalid arguments or options, including the renamed `--udid` and `list-simulators`, a `button` the device's platform lacks and `boot` with a simulator UDID |

## Privacy

Offsider has no telemetry and no accounts. It never connects to non-loopback addresses and never resolves hostnames; it may use Unix sockets and loopback TCP to local developer daemons (the adb server and the Android Emulator), so nothing leaves your Mac. It talks to simulators through Xcode's frameworks and writes only the files you ask for. See [SECURITY.md](SECURITY.md) for what it touches.

## Building from source

Building needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [jq](https://jqlang.org) (`brew install xcodegen jq`).

```bash
make frameworks   # clone the pinned idb revision and build its XCFrameworks
swift build       # build the offsider executable
swift test        # unit tests; simulator suites are skipped
make e2e          # rebuild everything and run the simulator end-to-end suites
make e2e-android  # run the Android emulator end-to-end suites (see ./test-runner.sh --help)
```

The simulator frameworks come from [michael-palmes/idb](https://github.com/michael-palmes/idb), a mirror of facebook/idb with Cameron Cooke's Xcode 27 changes on the `offsider/xcode27` branch (tag `offsider-idb-v0.2.0`). `scripts/build.sh` pins the exact revision and verifies it before building.

## Contributing and security

Issues and pull requests are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). This project follows a [code of conduct](CODE_OF_CONDUCT.md).

## Licensing and attribution

Offsider is released under the [MIT licence](LICENSE).

- Copyright (c) 2025 Cameron Cooke (AXe, from which Offsider is forked)
- Copyright (c) 2026 Michael Palmes (Offsider changes)

[NOTICE.md](NOTICE.md) describes the fork and its dependencies. Third-party licence texts, including Meta's idb MIT licence and the Apache 2.0 licence for swift-argument-parser, the gRPC Swift packages and the vendored Android Emulator proto, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Changes before the fork are recorded in [AXe's changelog](https://github.com/cameroncooke/axe/blob/v1.8.0/CHANGELOG.md).

## Trademarks and affiliation

Offsider is an independent project. It is not affiliated with, endorsed by or sponsored by Apple Inc. or Google LLC. iOS, Xcode, macOS and Simulator are trademarks of Apple Inc. Android is a trademark of Google LLC.

Offsider is not endorsed by Cameron Cooke or the AXe project.

Carried over from AXe because of the shared lineage: AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products. The same applies to Offsider.
