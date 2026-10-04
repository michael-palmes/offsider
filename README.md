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
VERSION=0.4.0
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
| `describe-ui` | Print the screen's UI as versioned, platform-neutral JSON, or only the element at `--point x,y`; `--summary` prints a short on-screen text view, and `--flat`, `--on-screen`, `--labelled`, `--actionable`, `--fields`, `--format json\|ndjson\|text` and `--compact` shape the output. `--display <id>` checks that the active display is the one you expect |
| `init` | Install the bundled agent skill (`--client auto\|claude\|agents`, `--dest`, `--force`, `--uninstall`, `--print`) |
| `tap` | Tap a point (`-x`, `-y`) or an element by `--id`, `--label` or `--value`; supports `--element-type`, `--wait-timeout`, `--allow-offscreen`, `--fail-if-covered`, `--tap-style`, delays and `--verify, --retries, --json` |
| `slider` | Set a slider to `--value` 0 to 100 by `--id` or `--label` (`--allow-offscreen`), then verify the result |
| `type` | Type text from an argument, `--stdin` or `--file` (US keyboard characters on iOS); `--replace` replaces the focused field's text instead, and an empty text clears it; supports `--verify, --retries, --json` |
| `swipe` | Swipe from `--start-x`/`--start-y` to `--end-x`/`--end-y`, with optional `--duration` and `--delta` |
| `drag` | Low-level point-to-point drag using explicit touch moves (`--duration`, `--steps`) |
| `gesture` | Run a preset: `scroll-up`, `scroll-down`, `scroll-left`, `scroll-right`, `swipe-from-left-edge`, `swipe-from-right-edge`, `swipe-from-top-edge`, `swipe-from-bottom-edge`. Presets fit the foreground app's frame in the current orientation; `--screen-width` and `--screen-height` override the size |
| `touch` | Send touch down and/or up at `-x`/`-y` (`--down`, `--up`, `--delay`) |
| `button` | Press a hardware button (optional `--duration`): on iOS `home`, `lock`, `side-button`, `siri`, `apple-pay`; on Android `back`, `app-switch`, `home`, `lock` (the power key), `volume-up`, `volume-down`. A button the device's platform lacks exits 64. Supports `--verify, --retries, --json` |
| `key` | Press one HID keycode (0 to 255), optionally held for `--duration`; supports `--verify, --retries, --json` |
| `key-sequence` | Press comma-separated `--keycodes` in order, with an optional `--delay` |
| `key-combo` | Press `--key` while holding comma-separated `--modifiers` |
| `wait` | Wait until an element is on screen (`--id`, `--label`, `--value`, `--has-value`) or `--gone`, the screen is `--settled`, a `--region x,y,w,h` is `--changed` or `--stable`, or `--seconds` pass; `--timeout`, `--json`. Exits 5 on timeout |
| `assert` | Check once that an element is on screen, optionally with `--has-value`, or `--gone`; exits 5 when it is not |
| `batch` | Run a whole case in one device session from `--step`, `--file` or `--stdin`: input steps, `sleep`, and the read steps `wait`, `assert`, `screenshot` and `describe-ui`; supports `--wait-timeout`, `--ax-cache`, `--continue-on-error`, `--mask-secure` (every screenshot step masks password fields) and `--json` (one NDJSON line per step; a `type` step's line shows `<N characters>`, never its text). Selector steps read the screen again after any step that sends input |
| `screenshot` | Save a PNG or JPEG of the active display (`--output`, `--format`, `--quality`); `--display <id>` captures another display of a foldable, `--scale points` makes one pixel one point, `--region x,y,w,h` crops in points, `--json` prints the image's size, scale, `orientation`, `rotation`, `display` and `posture`, `--compare <baseline>` (`--threshold`) exits 0 when the capture changed and 5 when it did not, and `--mask-secure` paints password fields black first |
| `logs` | Print recent device log entries (`--last 30s` by default, up to `8760h`, or `--since` a time up to the year 9999), or collect live ones with `--duration` or `--follow`; `--rn` for React Native, `--app`, `--process`, `--predicate` (iOS), `--grep`, `--max-lines`, `--raw`, `--json` |
| `appearance` | Read or set light or dark appearance; on Android a reading can be `auto` or `custom` when night mode follows a schedule |
| `content-size` | Read or set the text size: a Dynamic Type category on iOS, the matching font scale on Android; `reset` restores `large` |
| `orientation` | Read or set the device orientation, waiting until the device has turned: `portrait`, `landscape-left`, `landscape-right`, `portrait-upside-down`, named after how the device is turned, as Maestro and devicectl name them (`landscape-left` is turned 90 degrees anticlockwise, home edge on the right; UIKit calls that interface orientation `landscape-right`), or `--rotation 0\|90\|180\|270` in degrees anticlockwise; `--json` |
| `displays` | List the device's built-in displays (`main`, or `cover` and `inner` on a foldable) with platform ID, size, scale, rotation and which one is active, then the posture; `--json` |
| `posture` | Read a foldable's posture (`closed`, `half-opened`, `open`) and its active display, or set it: Android emulators through the emulator, the iPhone Duo simulator through its hinge (`--angle 0-180`, `--timeout`, `--json`), waiting until the display has swapped |
| `shake` | Send the shake gesture (iOS only) |
| `rn prepare` | Before a fresh Expo dev client (debug build) first launches: mark its dev menu intro as seen and stop the menu opening at launch (`--bundle-id`); stops the app first if it is running |
| `record-video` | Record the display to an H.264 MP4 until Ctrl+C (`--output`, `--fps`, `--quality`, `--scale`) |
| `stream-video` | Stream frames to stdout as `mjpeg`, `raw`, `ffmpeg` or `bgra` (`--format`, `--fps`, `--quality`, `--scale`) |

### describe-ui output

`describe-ui` prints one object. Every key is present, with `null` when a value is unknown, and `--point x,y` returns the same envelope with the element at that point as the only root. `screen` and frames are in points on iOS and dp on Android.

```json
{
  "version": 2,
  "platform": "ios",
  "device": "<ID>",
  "screen": {
    "width": 402, "height": 874, "scale": 3,
    "orientation": "portrait", "rotation": 0,
    "display": { "id": "main", "platformId": "1" },
    "posture": null
  },
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

| `screen` field | Meaning |
| --- | --- |
| `width`, `height`, `scale` | The active display in its current orientation, in points (dp on Android), and pixels per point |
| `orientation` | The shape: `portrait` or `landscape` |
| `rotation` | The device's anticlockwise turn from portrait in degrees (`0`, `90`, `180` or `270`), the number `orientation --json` prints, or `null` when the device does not say. `orientation landscape-left` gives `90` |
| `display` | The active display: `id` is `main`, `cover`, `inner` or `external`, and `platformId` is the simulator's or emulator's own ID for it |
| `posture` | `closed`, `half-opened`, `open` or `unknown` on a foldable, else `null` |

`version` 2 added `rotation`, `display` and `posture` and made `orientation` the shape; version 1 (0.3.0) had none of the three, and its `orientation` was `portrait`, `portraitUpsideDown`, `landscape` or `landscapeFlipped`.

`role` is one of `application`, `window`, `group`, `other`, `button`, `link`, `menuItem`, `tab`, `tabBar`, `segmentedControl`, `text`, `header`, `image`, `progress`, `textField`, `secureTextField`, `searchField`, `textArea`, `switch`, `checkbox`, `radioButton`, `slider`, `picker`, `cell`, `list`, `scrollView` or `keyboard`.

| Field | iOS source | Android source (UiAutomation helper) |
| --- | --- | --- |
| `roots` | The frontmost app's `application` element | The active window as `application`, labelled with its title (such as `Settings`), then the keyboard as `keyboard`, labelled with its title, while it is shown. The status and navigation bars are left out |
| `id` | `AXUniqueId` (`accessibilityIdentifier`, or `testID` in React Native), else `AXIdentifier` | `resource-id` (`testID` in React Native), else a Jetpack Compose `testTag` |
| `label` | `AXLabel` | `content-desc`, else the text of a non-editable node; a clickable node with neither takes its children's text |
| `value` | `AXValue`, as a string | A text field's text; `1` or `0` for switches, checkboxes and radio buttons, and `2` for a partly checked checkbox; a slider's or progress bar's position in its range as a percentage with up to two decimals, such as `25%` or `39.95%` |
| `frame`, `enabled` | The same keys | `bounds` over density / 160, `enabled` |
| `state.checked` | `switch` and `checkbox` only: `AXValue` `1` or `0` | `checked` for checkable nodes; `null` when partly checked |
| `state.selected`, `state.focused` | `selected` is `true` with the Selected trait, else `null`; `focused` is always `null` | `selected`, `focused` |
| `native` | `type`, `role`, `subrole`, `roleDescription`, `title`, `help`, `customActions`, `contentRequired`, `pid`, `axFrame` | `className`, `resourceId`, `package`, `pixelFrame`, `text`, `contentDescription`, `hint`, `stateDescription` (the spoken state, such as `25%`), `roleDescription`, `testTag` |

When Offsider falls back to `uiautomator` on Android (see [Android notes](#android-notes)), the tree has one unlabelled `application` root and no keyboard root, and sliders and progress bars have no `value`.

For a screen scan, `describe-ui --summary` prints one line per on-screen node that has a label, id or value, which is usually a small fraction of the full tree:

```text
# ios <ID> 402x874 @3x portrait 0°
application "Playground" (0,0 402x874)
  button "Save" id=save-button (170.7,313.3 61x34.3)
```

On a foldable the header line ends with the display and posture, such as `inner open`.

`--summary` is short for `--flat --on-screen --labelled --format text`. `--flat` lists nodes without nesting under `nodes`, each with `index`, `parent` and `depth`; `--on-screen` keeps nodes with at least 1 point on screen, judged as selectors judge it; `--labelled` keeps nodes with a label, id or value; `--actionable` keeps controls; `--fields` picks keys; `--format ndjson` prints a screen line and then one node per line; `--compact` prints JSON on one line. Without these flags the output is unchanged.

### Selectors

`--id`, `--label` and `--value` match `id`, `label` and `value`. Selectors prefer matches that are on screen: apps often keep views mounted off screen (a closed bottom sheet parked below the screen, rows below the fold), and a match whose frame lies outside the screen fails with an error naming its frame instead of tapping nothing. `--wait-timeout` waits for it to come on screen, and `--allow-offscreen` resolves it anyway. An element that is only partly on screen is tapped at the centre of its visible part. When no label or value matches exactly, typographic quotes and unusual spaces are folded (`--label "Don't Allow"` finds `Don’t Allow`), and a miss suggests the closest labels. On Android, `--id alert_title` also matches `com.example:id/alert_title` when no id matches exactly. `--element-type` matches `role` in any case or the native `type` exactly, so `button`, `Button` and `RadioButton` all work.

### Conditions and whole cases

`wait` and `assert` exit 0 when their condition holds and 5 when it does not, so a script can branch on them. Only on-screen matches count unless `--allow-offscreen` is passed. `wait --region x,y,w,h --changed` (or `--stable`) watches pixels, for content the accessibility tree cannot see, such as charts, maps and web views.

`batch` takes the same commands as steps, so one call can run a whole case:

```bash
offsider batch --device "$DEVICE" --json \
  --step "tap --id open-filters" \
  --step "wait --id apply-filters" \
  --step "tap --id apply-filters" \
  --step "assert --id filter-state --has-value Applied" \
  --step "screenshot --output after.png --scale points" \
  --step "describe-ui --summary"
```

With `--json`, stdout is one JSON line per step (`step`, `kind`, `line`, `ok`, `ms`, plus `exitCode` and `error` on failure and each read step's own result), then a summary line; human text goes to stderr. A failed step's `error` is the [JSON error object](#json-errors). The batch exits with the code of its first step that failed to run, else 5 when a `wait`, `assert` or `screenshot --compare` condition was not met, else 0.

`tap` warns when another element may cover its target, for example a banner over a tab bar, and `--fail-if-covered` stops instead of tapping. An overlay that is hidden from accessibility cannot be detected this way.

### Device lock

Input commands (`tap`, `type`, `swipe`, `drag`, `touch`, `gesture`, `key`, `key-combo`, `key-sequence`, `button`, `slider`, `shake`, `batch`, `rn prepare`, and `posture`, `orientation`, `appearance` and `content-size` when setting a value) lock the device for their run, so two agents cannot interleave input. On Android, any command that reads the screen through the helper or `uiautomator` (`describe-ui`, `wait`, `assert`, `screenshot --mask-secure`) also locks, since Android has one UiAutomation slot. A second command on a held device exits 8 with the reason `device_busy`, naming the holder's pid and command, and sends nothing. `--wait-lock <seconds>` (0 to 600) waits for the holder instead, and `OFFSIDER_WAIT_LOCK` sets that wait by default. `batch` takes the lock once for all its steps. Reads on iOS (`describe-ui`, `screenshot`, `wait`, `assert`, `logs`, `displays`, `list-devices`, `doctor` and the getters) never lock. Separate `touch --down` and `touch --up` commands each lock only for their own run, so another agent can act between them; keep a held touch in one `touch --down --up` or one `batch`. The lock is advisory: it stops other Offsider commands, not other tools.

Locks are files in a private per-user directory, `offsider-<uid>/locks/` under the per-user temp directory (`getconf DARWIN_USER_TEMP_DIR`), which ignores `TMPDIR` so agents with different sandboxes share one lock. When that directory cannot be used, Offsider falls back to `$TMPDIR/offsider-<uid>/`, and agents with different `TMPDIR` values then lock only among themselves. Each lock file is mode 0600 inside 0700 directories and holds only the holder's pid, command name and start time. The kernel drops a lock when its command exits, even when killed.

### React Native notes

- `testID` is `id` and `accessibilityLabel` is `label` on both platforms. A pressable row with neither takes its children's text as its label (`Inbox, 3 unread`), live values included, so prefer a `testID`.
- Views often stay mounted while off screen: a closed bottom sheet parked below the screen, or the previous screen of a JavaScript stack. On iOS they stay in the tree with off-screen frames; on Android nodes the user cannot see are left out. Selectors, `wait`, `assert` and `describe-ui --on-screen` count only what is on screen. A previous screen that is still partly on screen under the current one keeps its ids, so a duplicated id there needs `--element-type` or coordinates.
- Content under `accessibilityElementsHidden` or `importantForAccessibility="no-hide-descendants"` is not in the tree but still takes taps.
- On iOS, React Native writes the role of a checkbox, radio button, switch, tab, tab list, menu item, combo box or progress bar into the accessibility value, and Offsider reads it back: these report `checkbox`, `radioButton`, `switch`, `tab`, `tabBar`, `menuItem`, `picker` or `progress` instead of `other`, with `state.checked` and a `value` of `1`, `0` or `2` (mixed) for checkboxes, radio buttons and switches, as on Android. The new architecture writes only the checkbox and radio button words, so on it a combo box and a progress bar stay `other`. `native.type` keeps the platform's own type, so `--element-type Other` still finds them.
- `offsider logs --rn` prints `console.log`, `console.warn` and `console.error` output, in release builds too.
- `appearance`, `content-size` and `orientation` change the device for every later screen; set them back when done. On Android, `orientation` turns auto-rotate off. `orientation` names the device turn, so `landscape-left` is what React Native's and UIKit's interface orientation call landscape-right; `describe-ui` and `screenshot --json` report the shape as `orientation` and the turn as `rotation`.
- Debug builds: `rn prepare` skips an Expo dev client's first-launch intro. A LogBox error banner sits over the bottom of the screen and swallows taps; `tap` warns about it on both platforms, and `tap --verify` shows the tap had no effect.

### Foldables

A foldable has a `cover` and an `inner` display, and one of them is active at a time. `offsider displays` lists both and marks the active one, and `offsider posture` reads the posture (`closed` uses the cover display, `open` the inner one). `describe-ui`, `tap` and the other input commands use the active display, and `screenshot` captures it unless `--display` names the other one. `describe-ui --display inner` fails with a hint while the inner display is not active, so a script can check it is reading the screen it expects.

- iOS: `posture` folds and unfolds the iPhone Duo simulator by driving its hinge the way Device Hub does (a private CoreDevice path, best effort on Xcode 27.1; where the runtime has no hinge service the command says so and exits 1). Folded, the cover display is 466 x 678 pt; unfolded in portrait, the inner display is 951 x 669 pt (landscape-shaped, rotation 0: `screen.rotation` is the device's turn from portrait, as `orientation --json` reports it, not the UI's turn on the panel). The Duo refuses orientation changes.
- Android: `offsider posture open` (or `closed`, `half-opened`) folds the emulator through its gRPC endpoint, or `cmd device_state` over adb, and waits until the device reports it. A Pixel 9 Pro Fold emulator's inner display is about 852 x 883 dp and its cover display about 443 x 994 dp. Folding it shows "Swipe up to continue" on the cover, over the app, which keeps running: swipe up from the bottom edge to use it.

### Android notes

- IDs are emulator serials (`emulator-5554`) or the names of running AVDs; `list-devices` shows both. `boot` starts an AVD with its window (`--headless` hides it), passes only `-no-metrics` to the emulator, writes the emulator's output to `$TMPDIR/offsider-boot-<avd>.log` and never starts a second instance of an AVD that is already running.
- Coordinates, frames and `--delta` are in dp, the Android equivalent of points.
- Every screen read (`describe-ui`, selectors, `--wait-timeout`, `--verify`, `gesture` presets, `slider` and `type --replace`) goes through a small helper that Offsider pushes to `/data/local/tmp/offsider-helper-<hash>.dex` when that copy is missing, and runs with `app_process` as the shell user for the length of one command. A `describe-ui` takes about 0.3 s and a verified tap 1 to 1.5 s on a quiet Mac; both are slower while the Mac running the emulator is busy, because Android then starts the helper more slowly. Commands that only send input, such as `tap -x -y`, `swipe`, `key` and plain `type`, never start it.
- While the helper runs it holds Android's single UiAutomation connection, and the emulator reports an accessibility service as enabled (`accessibility_enabled`), which some apps notice. Both end with the command.
- Another UiAutomation client, such as Appium, Maestro, `uiautomator` or Layout Inspector, makes these commands fail with a message saying so: stop that client, then retry. An earlier Offsider helper that still holds the connection after 2 s (usually a command running in parallel) is named with its pid: it exits within 10 s of losing its command, or `adb -s <serial> shell kill <pid>` stops it at once.
- If the helper cannot run (for example the push fails, or the Android version lacks the API it uses), Offsider prints one `Warning:` line saying why and reads the screen with `uiautomator` instead, at about 2 s per read. `slider` then fails, as `uiautomator` reports no slider values.
- `--verify` leaves the status and navigation bars, as the helper measures them, out of screenshot comparisons; with gesture navigation there is no navigation bar to leave out. `--tap-style` and the `style` field keep their names: `simulator` is a single tap and `physical` a timed touch down and up.
- `slider` sets the value through Android's accessibility progress action, and drags when the control does not take it. A control whose steps cannot show the value stops at the nearest step, and the success line says so, for example `Slider set to 78 (the nearest step to 78.25)`. Apps that act only when a drag ends, such as React Native's `onSlidingComplete`, may not see the change; use `drag` on the track for those.
- `type` sends ASCII text as key events. Text with any other character is pasted through the emulator's clipboard, which Offsider saves first and restores afterwards. Into a focused password field that paste is refused, so a secret never reaches the clipboard: use `type --replace`, which sets the field without it. The emulator's clipboard sharing may copy a paste to the Mac's pasteboard; this has not been checked. Over adb, `input text` briefly shows the text in the emulator's process list to other shell-user processes; the gRPC transport avoids this.
- `type --replace` sets the focused field's text in one accessibility action, so any Unicode text works without gRPC, but key handlers such as `onKeyPress` do not run. A trailing newline is then pressed as Return, so `type --replace $'query\n'` submits a search field; other newlines become line breaks. A field that refuses the action, or an emulator where the helper cannot run, gets Ctrl+A, Delete and typing instead, with a warning. With nothing focused it fails: tap the field first.
- Offsider talks to the adb server and to the emulator's gRPC endpoint on loopback. An emulator started with `-port` has no gRPC endpoint, so Offsider falls back to adb: screenshots are slower, `type` accepts ASCII only (`type --replace` still takes any text) and `stream-video --format bgra` is unavailable.
- `stream-video --format bgra` sends a frame when the screen changes, not at a fixed rate, so a still screen sends one frame.
- `doctor --device` does not support Android emulators yet.
- For troubleshooting, `OFFSIDER_ANDROID_TRANSPORT=adb` (or `grpc`) forces one transport, `OFFSIDER_ANDROID_GRPC_AUTH=jwt` makes Offsider sign in to gRPC with a short-lived key instead of the emulator's token, and `OFFSIDER_ANDROID_TREE=uiautomator` (or `helper`) forces one way of reading the screen: `uiautomator` never starts the helper, and `helper` makes an unavailable helper an error instead of a fallback.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success; for `doctor`, every check passed or was skipped |
| 1 | The command failed for any other reason; the error is printed to stderr |
| 2 | The selector matched nothing, or only elements off screen |
| 3 | `doctor` found warnings |
| 4 | `doctor` found failures |
| 5 | A condition was not met: `--verify` saw no change after the input, `wait` timed out, `assert` failed, `screenshot --compare` found no change, or a `batch` had only such failures |
| 6 | The selector matched more than one element |
| 7 | The device was not found or is not booted |
| 8 | The device is busy: another Offsider command holds it (see [Device lock](#device-lock)), or another UiAutomation client holds an Android emulator |
| 9 | Xcode, adb or the Android SDK is missing or unusable |
| 64 | Invalid arguments or options, including the renamed `--udid` and `list-simulators`, a malformed device ID, an unknown display, a key or `button` the device's platform lacks and `boot` with a simulator UDID |

`batch` exits with the code of its first step that failed to run, else 5 when only conditions were not met.

### JSON errors

With `--json`, a failure prints one object on stdout, where the success output goes, and the `Error:` line still goes to stderr. `describe-ui` does the same when its output is JSON or NDJSON:

```json
{"version":1,"ok":false,"command":"screenshot","exitCode":7,"error":{"reason":"device_not_found","message":"No device with ID 5E1B... was found. Run `offsider list-devices` to see available devices.","hint":"offsider list-devices","dispatched":null,"candidates":[]}}
```

`--verify --json` reports (version 2) and `batch --json` step lines carry the same `error` object in place of their own envelope. `hint` is the next command to run and never repeats typed text. `candidates` lists up to five elements (`id`, `label`, `role`, `frame`, `onScreen`, never a value) for selector errors. `dispatched` says whether input may have reached the device: `no` (nothing was sent, so resending is safe), `unknown` (a send began and failed, so check the screen first) or `yes`; it is null for commands that send no input. A `--json` that is itself the mistake, such as `tap --json` without `--verify`, prints only the usage error.

### Error reasons

| Reason | Exit | When | What to do |
| --- | --- | --- | --- |
| `selector_not_found` | 2 | No element matched the selector | Read `candidates`, fix the selector, or wait with `--wait-timeout` |
| `selector_filtered_by_type` | 2 | Elements matched, but none of the `--element-type` | Drop or change `--element-type`; `candidates` shows the roles |
| `target_off_screen` | 2 | Every match is off screen | Scroll it into view, wait, or pass `--allow-offscreen` |
| `selector_ambiguous` | 6 | Several elements matched | Pick from `candidates`: use `--id`, add `--element-type` or tap by coordinates |
| `selector_ambiguous_switch` | 6 | The match holds several switches | Target the switch with `--id` or coordinates |
| `device_not_found` | 7 | No device has that ID | `offsider list-devices` |
| `device_not_booted` | 7 | The device exists but is not running | Boot it (`xcrun simctl boot`, `offsider boot`) |
| `device_not_ready` | 7 | The emulator is offline or still booting | Wait, or `offsider boot <AVD>` |
| `device_unauthorised` | 7 | adb is not authorised for the emulator | Accept the prompt, or restart it with `offsider boot` |
| `device_ambiguous` | 7 | An AVD name matches more than one running emulator | Pass one serial with `--device` |
| `avd_not_found` | 7 | No AVD has that name | Check the name in Android Studio's Device Manager |
| `device_busy` | 8 | Another Offsider command holds the device; the message names its pid | Wait and retry, or pass `--wait-lock <seconds>` |
| `uiautomation_busy` | 8 | Another UiAutomation client holds the emulator | Stop that client, or run the `hint`, then retry |
| `xcode_missing` | 9 | No usable Xcode is selected | `xcode-select -s <Xcode.app>/Contents/Developer` |
| `xcode_unusable` | 9 | The selected Xcode cannot load simulator support | Select Xcode 26 or later |
| `android_sdk_missing` | 9 | No Android SDK or adb was found | Install Platform-Tools or set `ANDROID_HOME` |
| `adb_server_unavailable` | 9 | The adb server is not running or not answering | `adb start-server` |
| `adb_server_misconfigured` | 9 | The adb server settings point off this Mac or cannot be read | Fix or unset the adb server variables |
| `emulator_missing` | 9 | The Android Emulator is not installed | Install it with the SDK Manager |
| `emulator_grpc_required` | 9 | The command needs the emulator's gRPC endpoint and it is not reachable | Restart the emulator with `offsider boot` |
| `helper_unavailable` | 9 | The UiAutomation helper cannot run on this emulator | Unset `OFFSIDER_ANDROID_TREE`, or use another image |
| `usage` | 64 | Invalid arguments or options | Fix the command line; see `--help` |
| `invalid_device_id` | 64 | The device ID is empty or not a device ID | `offsider list-devices` |
| `invalid_setting` | 64 | An `OFFSIDER_` variable has a value Offsider cannot read | Fix or unset it |
| `unsupported_button` | 64 | The device's platform has no such button | Use a button the platform has |
| `unsupported_key` | 64 | The key has no equivalent on the device | Use a supported key |
| `unknown_display` | 64 | `--display` names no display on the device | `offsider displays --device <ID>` |
| `legacy_argument` | 64 | A renamed option or command, such as `--udid` | Use the new name in the message |
| `not_verified` | 5 | `--verify` saw no change after the input (reports only) | Check the screen before sending again |
| `condition_not_met` | 5 | A `wait`, `assert` or `screenshot --compare` condition was not met (reports only) | Read the step's `reason` |
| `command_failed` | 1 | Any failure without a more specific reason | Read `message` |
| `internal_error` | 1 | Offsider reached a state it should not | Report it |
| `input_failed` | 1 | Sending input failed | Read `dispatched` before resending |
| `input_outcome_unknown` | 1 | The input request was lost on the way and not replayed | Check the screen before resending |
| `target_covered` | 1 | `--fail-if-covered` found something over the target | Dismiss the cover, then retry |
| `target_under_keyboard` | 1 | `--fail-if-covered` found the keyboard over the target | Dismiss the keyboard, then retry |
| `target_has_no_frame` | 1 | The match has no usable frame | Target another element |
| `target_moved` | 1 | The slider changed while it was being set | Retry when the screen is still |
| `not_a_slider` | 1 | `slider` matched something that is not a slider | Use `--element-type slider` or a narrower selector |
| `slider_unreadable` | 1 | The slider exposes no numeric value | Use `tap` or `drag` instead |
| `slider_unverified` | 1 | The slider did not reach the value | Retry, or read its value with `describe-ui` |
| `no_focused_field` | 1 | `type --replace` found no focused text field | Tap the field first |
| `field_not_editable` | 1 | The focused element is not a text field | Tap the text field first |
| `unsupported_text` | 1 | The text has characters the device cannot type | Remove them, or use `type --replace` on Android |
| `secure_paste_refused` | 1 | Typing into a password field would use the clipboard | Use `type --replace` |
| `mask_unproven` | 1 | `--mask-secure` could not locate every password field | Retry when the screen is still |
| `tree_read_failed` | 1 | The accessibility tree could not be read | Retry; on iOS run `offsider doctor --device <ID>` |
| `no_window` | 1 | The device shows no window | Unlock it and bring an app to the front |
| `screen_not_idle` | 1 | The screen did not settle for uiautomator | Retry when the screen is still |
| `screenshot_failed` | 1 | The screen could not be captured | Retry, or check the device with `offsider list-devices` |
| `baseline_unreadable` | 1 | The `--compare` baseline cannot be read | Check the path, or capture a new baseline |
| `baseline_mismatch` | 1 | The baseline and the capture differ in size | Capture both with the same `--region` and `--scale` |
| `display_unreadable` | 1 | The display size or turn could not be read | Retry, or check the device |
| `display_off` | 1 | The requested display is off | Fold or unfold the device with `offsider posture` |
| `not_supported` | 1 | The device or platform does not support the command or option | Use another device or option |
| `posture_failed` | 1 | The posture could not be set | Check it with `offsider posture --device <ID>` |
| `state_not_reached` | 1 | The posture or orientation did not take effect in time | Check the device, then retry |
| `orientation_unknown` | 1 | The device did not report its orientation | Check it with `describe-ui` |
| `device_restarted` | 1 | The simulator restarted while Offsider connected | Retry |
| `device_unresponsive` | 1 | The device stopped answering | `offsider doctor --device <ID>`, or restart the device |
| `device_control_failed` | 1 | A device setting could not be read or changed | Check the device is booted |
| `app_not_installed` | 1 | `logs --app` names an app that is not installed | Install it, or drop `--app` |
| `log_stream_failed` | 1 | The device's log could not be read | Retry |
| `video_failed` | 1 | Recording or streaming video failed | Check the output path, then retry |
| `helper_failed` | 1 | The UiAutomation helper stopped or failed | Retry; the `hint` names the log to read |
| `helper_timed_out` | 1 | The UiAutomation helper did not answer in time | Retry when the emulator responds |
| `adb_command_failed` | 1 | An adb command failed on the emulator | Read `message` |
| `adb_protocol_error` | 1 | The adb server sent a reply Offsider could not read | Restart the adb server |
| `emulator_grpc_unavailable` | 1 | The emulator's gRPC endpoint did not answer | Check the emulator is still running |
| `emulator_grpc_auth_failed` | 1 | The emulator rejected Offsider's gRPC credentials | Restart it with `offsider boot` |
| `emulator_grpc_failed` | 1 | A gRPC call to the emulator failed | Retry |
| `emulator_timed_out` | 1 | The emulator did not answer a gRPC call in time | Retry when it responds |
| `emulator_launch_failed` | 1 | The emulator could not start or exited during start-up | Read the log the message names |
| `boot_timed_out` | 1 | The emulator did not finish booting in time | Run `offsider boot` again to keep waiting |
| `hid_broker_failed` | 1 | The HID broker that sends iOS input failed | `offsider doctor --device <ID>` |
| `private_directory_unsafe` | 1 | The HID broker directory is not private to this user | `offsider doctor --device <ID> --fix` |
| `timed_out` | 1 | A helper process did not finish in time | Retry |
| `init_failed` | 1 | `init` could not install or remove the skill | Read `message` |
| `device_list_failed` | 1 | Devices could not be listed | Read `message` for each platform |
| `expo_dev_client_failed` | 1 | `rn prepare` could not prepare the Expo dev client | Read `message` |

## Privacy

Offsider has no telemetry and no accounts. It never connects to non-loopback addresses and never resolves hostnames; it may use Unix sockets and loopback TCP to local developer daemons (the adb server and the Android Emulator), so nothing leaves your Mac. It talks to simulators through Xcode's frameworks and writes only the files you ask for. See [SECURITY.md](SECURITY.md) for what it touches.

### Secure fields

Password fields (iOS secure text fields, Android `password="true"`) read as bullets, one per character, in `describe-ui`, selectors, `wait`, `assert` and `--verify`, so a typed password keeps its length and nothing else. Their `id`, `label` and hint stay readable; `--value` never matches them. `type` logs only the number of characters, never the text, and `batch` records and errors show `<N characters>` for a `type` step.

`screenshot --mask-secure` (or `OFFSIDER_MASK_SECURE=1`) reads the accessibility tree, then paints every password field opaque black before the image is written; when a password field has no frame, the image is withheld and no file is written. Plain screenshots, `record-video` and `stream-video` are never masked, and iOS briefly shows the last character typed into a secure field. Masking follows the platform's secure flag, so a secret in an ordinary text field, such as a custom PIN pad, is not masked, and a field that appears between the tree read and the capture is not covered.

## Building from source

Building needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [jq](https://jqlang.org) (`brew install xcodegen jq`).

```bash
make frameworks   # clone the pinned idb revision and build its XCFrameworks
swift build       # build the offsider executable
swift test        # unit tests; simulator suites are skipped
make e2e          # rebuild everything and run the simulator end-to-end suites
make e2e-android  # run the Android emulator end-to-end suites (see ./test-runner.sh --help)
make e2e-rn-ios   # run the React Native playground suites on a simulator (needs pnpm)
make e2e-foldable # run the foldable suite on the "Offsider Duo iPhone" simulator
make e2e-android-fold  # run the foldable suite on the Offsider_E2E_Pixel_9_Pro_Fold AVD
```

`make e2e-foldable` sets `OFFSIDER_FOLDABLE_E2E=1` and runs `FoldableTests` on an iPhone Duo simulator, folding and unfolding it with `offsider posture`. `make e2e-android-fold` sets `OFFSIDER_ANDROID_FOLD_E2E=1` and `OFFSIDER_ANDROID_E2E_AVD=Offsider_E2E_Pixel_9_Pro_Fold`; the Android suites drive only that AVD and `Offsider_E2E_Pixel_9`.

`make e2e-rn-debug-ios` and `make e2e-rn-debug-android` build the React Native debug app, run Metro on loopback port 8742 and run the debug smoke suite. `pnpm --dir OffsiderPlaygroundRN ios <udid>` or `android <serial|avd>` installs the debug app and runs it from the same background Metro (`scripts/rn-playground.sh metro stop` ends it).

`OFFSIDER_TIMINGS=1` prints phase timings for a command to stderr, as `offsider timing: <phase> <n> ms` lines.

The simulator frameworks come from [michael-palmes/idb](https://github.com/michael-palmes/idb), a mirror of facebook/idb with Cameron Cooke's Xcode 27 changes on the `offsider/xcode27` branch (tag `offsider-idb-v0.2.0`). `scripts/build.sh` pins the exact revision and verifies it before building.

The Android helper's Java source is in `AndroidHelper/`, and its compiled dex is committed, so `swift build` needs no JDK. Only when you change `AndroidHelper/`, rebuild it with `scripts/build.sh helper` (or `make helper`), which needs JDK 17 (`OFFSIDER_HELPER_JDK`, `JAVA_HOME` or `/usr/libexec/java_home -v 17`) and the Android SDK's build-tools 37.0.0 and android-37.0 platform, and commit the dex and manifest with the source. `scripts/build.sh helper --check` (or `make helper-check`) rebuilds it and compares it with the committed dex, as CI does.

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
