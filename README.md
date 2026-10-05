# Offsider

A hand for your agent on the iOS Simulator and the Android Emulator.

[![CI](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml/badge.svg)](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/michael-palmes/offsider?sort=semver)](https://github.com/michael-palmes/offsider/releases/latest)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Offsider is a command-line tool that inspects and drives iOS Simulators and Android Emulators, and iPhones, iPads and Android phones connected over USB: describe the UI through accessibility, tap, type, swipe, press buttons and capture screenshots or video. It is built for terminals, scripts and AI coding agents, and it runs entirely on your Mac.

Offsider is a fork of [AXe](https://github.com/cameroncooke/axe) v1.8.0 by Cameron Cooke, used under the MIT licence. It is not endorsed by AXe's author. See [Licensing and attribution](#licensing-and-attribution).

## Install

### Homebrew

```bash
brew install michael-palmes/tap/offsider
```

### Verified tarball

Each release publishes `offsider-<version>-arm64.tar.gz`, a `SHA256SUMS` file and a GitHub build provenance attestation from `.github/workflows/release.yml`. The binary is signed with a Developer ID certificate and notarised.

```bash
VERSION=0.6.0
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
- For a physical iPhone or iPad: a USB cable, and the host's Xcode decides what works. Xcode 27 (CoreDevice 636 or later) gives every command, with input and screenshots through a per-device session broker that needs a logged-in desktop session on the Mac. Xcode 26 gives listing, `doctor`, screenshots, appearance, text size, orientation, and through the runner the accessibility tree, `wait`, `assert`, element taps, coordinate `tap`, `swipe` and `button home`. The device can run iOS or iPadOS 26 or 27 (with Xcode 27's developer disk image). Hosts are macOS 26.7 or later, or macOS 27, on Apple silicon. See [Physical iPhones and iPads](#physical-iphones-and-ipads).
- For Android: the Android SDK with Platform-Tools (and the Android Emulator for emulators), and `arm64-v8a` system images (tested on API 36; the adb fallback needs API 33 or later). Offsider finds the SDK through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk` (where Android Studio installs it) or `adb` on your `PATH`.

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
offsider guide                                   # list the skill's topics; guide <topic> prints one
```

On Android, start an emulator with `boot` (it prints the serial once Android has booted), then use the same commands:

```bash
offsider list-devices --platform android       # running emulators and USB phones by serial, AVDs by name
DEVICE=$(offsider boot Pixel_9)                 # add --headless to hide the window
offsider describe-ui --device "$DEVICE"
offsider tap --id LoginButton --verify --device "$DEVICE"
offsider type 'héllo' --device "$DEVICE"
offsider button back --device "$DEVICE"
```

On a physical iPhone or iPad, connected by cable, pass its UDID and name the app to read (see [Physical iPhones and iPads](#physical-iphones-and-ipads)):

```bash
offsider doctor --device <UDID>                                 # trust, Developer Mode, UI Automation, signing
offsider describe-ui --summary --app com.example.app --device <UDID>   # builds the runner on first use
```

Most input commands confirm dispatch, not effect. Add `--verify` to `tap`, `type`, `key` or `button` to wait for an observable change (accessibility tree, then screenshot); the command exits 5 if nothing changes. `slider` always checks its value. If input seems to be ignored, or screen reads fail, run `offsider doctor --device "$DEVICE"` (simulators, Android devices and iPhones).

A simulator can fall into a crash loop after boot, with macOS showing a "quit unexpectedly" dialog for each crash. `doctor --device <UDID>` reads the crash reports macOS wrote in the last 10 minutes (only their header and process name, never paths or stack frames): `simulator.crash-loop` warns at two to four crashes of one process and fails at five or more (a busy host sees a few daemon crashes without a loop), printing `xcrun simctl shutdown <UDID> && xcrun simctl erase <UDID>` without running it. Erasing removes the simulator's apps and settings. Plain `doctor` lists every simulator with five or more crashes of one process as `simulators.crash-loop`, and `test-runner.sh` refuses to start on a simulator in a crash loop.

## Commands

Every device command takes `--device <id>`, using an ID from `offsider list-devices`: a simulator UDID (case-insensitive), a USB iPhone or iPad's UDID (such as `00008130-001C...`), an Android emulator serial such as `emulator-5554`, the name of a running AVD, or a USB phone's serial. Run `offsider <command> --help` for the full list of options.

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
      "deviceType": "iPhone 17 Pro",
      "kind": "simulator",
      "connection": null
    }
  ]
}
```

`kind` is `simulator`, `emulator` (running), `avd` (shut down) or `physical`; `connection` is `usb` for a phone (`network` for one Offsider refuses), else null. An iPhone or iPad's `state` is `Booted` when Offsider can drive it, else `Wireless`, `Untrusted`, `Developer Mode off`, `Preparing`, `Reconnecting` or `Unavailable`, with a hint on stderr.

In 0.3.0, `--udid` was renamed to `--device` and `list-simulators` to `list-devices`. The old names exit 64 with a hint.

| Command | What it does |
| --- | --- |
| `list-devices` | List iOS simulators (iPhone and iPad), iPhones and iPads known to this Mac, running Android emulators, USB Android phones and shut-down AVDs with their IDs as a table, or as JSON with `--json`; `--platform ios\|android` filters |
| `boot` | Start an Android emulator by AVD name and wait until it has booted, then print its serial (`--headless`, `--timeout`); an AVD that is already running is not started again |
| `doctor` | Check Xcode, Device Hub, CoreSimulator, HID settings, booted simulators and simulator crash loops, plus the Android SDK and adb server when an SDK is installed; with `--device`, a simulator's state, Resize Mode, dtuhidd, HID transport, accessibility and recent crashes, or an Android device's state, image, screen and lock screen, stay awake, gRPC endpoint, UiAutomation slot, helper start and Metro reverse, plus a phone's adb authorisation expiry and automatic system updates (Android host checks only, no Xcode checks), or an iPhone or iPad's `ios-device.*` checks; `--json` prints one object, `--fix` applies safe fixes (on Android, only starting an absent adb server with `ADB_MDNS=0`, never when `--device` names a simulator; on an iPhone or iPad, only mounting the developer disk image) |
| `describe-ui` | Print the screen's UI as versioned, platform-neutral JSON, or only the element at `--point x,y`; `--summary` prints a short on-screen text view, and `--flat`, `--on-screen`, `--labelled`, `--actionable`, `--fields`, `--format json\|ndjson\|text`, `--compact` and `--max-bytes` shape the output; `--diff` prints only what changed since the previous command's tree. `--display <id>` checks that the active display is the one you expect; `--app <bundle-id>` names the app to read on an iPhone or iPad |
| `init` | Install the bundled agent skill (`--client auto\|claude\|agents`, `--dest`, `--force`, `--uninstall`, `--print`) |
| `guide` | Print one topic of the skill, matched to this version (`selectors`, `verify`, `errors`, `android`, `ios-device`, `react-native`, `turnstile`, `foldables`, `batch`, `screenshots`, `describe-ui`, `device-state`, `migrate`), or list the topics with no argument |
| `tap` | Tap a point (`-x`, `-y`) or an element by `--id`, `--label` or `--value`; supports `--element-type`, `--wait-timeout`, `--allow-offscreen`, `--fail-if-covered`, `--no-settle`, `--tap-style`, delays and `--verify, --retries, --json`; `--app <bundle-id>` on an iPhone or iPad |
| `turnstile` | Tap the checkbox square of a Cloudflare Turnstile widget and wait until it passes. The checkbox frame includes the words beside the square, so a normal tap misses the box. On iOS the web view leaves the checkbox out of the tree, so the tap is the square where the green check sits. It does not bypass Turnstile: the widget passes only when Cloudflare accepts the device. `--timeout`, `--jitter`, `--seed`, `--id`, `--json`. Exits 5 when the checkbox remains, and 2 when no widget is on screen. See `offsider guide turnstile` |
| `slider` | Set a slider to `--value` 0 to 100 by `--id` or `--label` (`--allow-offscreen`, `--no-settle`), then verify the result |
| `type` | Type text from an argument, `--stdin` or `--file` (US keyboard characters on iOS); `--replace` replaces the focused field's text instead, and an empty text clears it; supports `--verify, --retries, --json` |
| `swipe` | Swipe from `--start-x`/`--start-y` to `--end-x`/`--end-y`, with optional `--duration` and `--delta` |
| `drag` | Low-level point-to-point drag using explicit touch moves (`--duration`, `--steps`) |
| `gesture` | Run a preset: `scroll-up`, `scroll-down`, `scroll-left`, `scroll-right`, `swipe-from-left-edge`, `swipe-from-right-edge`, `swipe-from-top-edge`, `swipe-from-bottom-edge`. Presets fit the foreground app's frame in the current orientation; `--screen-width` and `--screen-height` override the size |
| `touch` | Send touch down and/or up at `-x`/`-y` (`--down`, `--up`, `--delay`) |
| `button` | Press a hardware button (optional `--duration`): on iOS `home`, `lock`, `side-button`, `siri`, `apple-pay`; on Android `back`, `app-switch`, `home`, `lock` (the power key), `volume-up`, `volume-down`. A button the device's platform lacks exits 64. Supports `--verify, --retries, --json` |
| `key` | Press one HID keycode (0 to 255), optionally held for `--duration`; supports `--verify, --retries, --json` |
| `key-sequence` | Press comma-separated `--keycodes` in order, with an optional `--delay` |
| `key-combo` | Press `--key` while holding comma-separated `--modifiers` |
| `wait` | Wait until an element is on screen (`--id`, `--label`, `--value`, `--has-value`) or `--gone`, the screen is `--settled`, a `--region x,y,w,h` is `--changed` or `--stable`, or `--seconds` pass; `--timeout`, `--json`, and `--app <bundle-id>` on an iPhone or iPad. Exits 5 on timeout |
| `assert` | Check once that an element is on screen, optionally with `--has-value`, or `--gone`; exits 5 when it is not; `--app <bundle-id>` on an iPhone or iPad |
| `batch` | Run a whole case in one device session from `--step`, `--file` or `--stdin`: input steps, `sleep`, and the read steps `wait`, `assert`, `screenshot` and `describe-ui`; supports `--wait-timeout`, `--ax-cache`, `--no-settle`, `--continue-on-error`, `--mask-secure` (every screenshot step masks password fields) and `--json` (one NDJSON line per step; a `type` step's line shows `<N characters>`, never its text). Selector steps read the screen again after any step that sends input |
| `screenshot` | Save a PNG or JPEG of the active display (`--output`, `--format`, `--quality`); `--display <id>` captures another display of a foldable, `--scale points` makes one pixel one point, `--region x,y,w,h` crops in points, `--json` prints the image's size, scale, `orientation`, `rotation`, `display` and `posture`, `--compare <baseline>` (`--threshold`) exits 0 when the capture changed and 5 when it did not, and `--mask-secure` paints password fields black first |
| `logs` | Print recent device log entries (`--last 30s` by default, up to `8760h`, or `--since` a time up to the year 9999), or collect live ones with `--duration` or `--follow`; `--rn` for React Native, `--app`, `--process`, `--predicate` (iOS), `--grep`, `--max-lines`, `--raw`, `--json` |
| `appearance` | Read or set light or dark appearance; on Android a reading can be `auto` or `custom` when night mode follows a schedule |
| `content-size` | Read or set the text size: a Dynamic Type category on iOS, the matching font scale on Android; `reset` restores `large` |
| `permission` | Grant, revoke or reset an app's permissions by service (`--app` required): `simctl privacy` on iOS, runtime permissions on Android; `show` lists an Android app's runtime permissions, `services` the names each platform supports; `--json` |
| `status-bar` | `override` sets a clean status bar (9:41, full battery and signal, or `--time`, `--battery`, `--charging`, `--wifi`, `--cellular`, `--operator`, `--data-network`, `--notifications`), `clear` removes it, `show` reads it; `--json` |
| `biometric` | `enrol`, `unenrol` or `status` of Face ID or Touch ID on iOS simulators; `match` and `no-match` send a face or finger to an app that is asking, also on Android emulators (`--modality`, `--finger-id`, `--json`) |
| `stay-awake` | Read Android's Developer options > Stay awake with the screen timeout and whether it takes effect, or set it `on` (every power source) or `off`; `--json` |
| `wake` | Turn an Android screen on and dismiss its lock screen, sending nothing when it is already on and unlocked; a PIN, pattern or password lock screen exits 7 (`device_locked`) unless `--unlock` types the code saved with `unlock-code`; `--json` |
| `unlock-code` | `set`, `status` or `remove` the PIN or password `wake --unlock` types, kept in the login Keychain under a phone serial or AVD name; `set` asks with typing hidden, or reads `--stdin`; `--json` |
| `orientation` | Read or set the device orientation, waiting until the device has turned: `portrait`, `landscape-left`, `landscape-right`, `portrait-upside-down`, named after how the device is turned, as Maestro and devicectl name them (`landscape-left` is turned 90 degrees anticlockwise, home edge on the right; UIKit calls that interface orientation `landscape-right`), or `--rotation 0\|90\|180\|270` in degrees anticlockwise; `--json` |
| `displays` | List the device's built-in displays (`main`, or `cover` and `inner` on a foldable) with platform ID, size, scale, rotation and which one is active, then the posture; `--json` |
| `posture` | Read a foldable's posture (`closed`, `half-opened`, `open`) and its active display, or set it: Android emulators through the emulator, the iPhone Duo simulator through its hinge (`--angle 0-180`, `--timeout`, `--json`), waiting until the display has swapped |
| `shake` | Send the shake gesture (iOS only) |
| `rn prepare` | Before a fresh Expo dev client (debug build) first launches: mark its dev menu intro as seen and stop the menu opening at launch (`--bundle-id`); stops the app first if it is running |
| `record-video` | Record the display to an H.264 MP4 until Ctrl+C (`--output`, `--fps`, `--quality`, `--scale`) |
| `stream-video` | Stream frames to stdout as `mjpeg`, `raw`, `ffmpeg` or `bgra` (`--format`, `--fps`, `--quality`, `--scale`) |
| `runner` | `status` lists the XCUITest runner sessions that read physical iPhones and iPads, `stop` stops one (`--device`) or all; `--json`. A runner stops by itself after `OFFSIDER_IOS_RUNNER_IDLE` seconds without a request (default 300) |
| `session` | `status` lists each physical device's background sessions, the XCUITest runner and the session broker that holds its screen stream and HID input, without starting either; `stop` stops both on one device (`--device`) or all, ending the screen stream so the device's screen-sharing indicator clears; `--json`. A broker stops by itself after `OFFSIDER_IOS_SESSION_IDLE` seconds without a request (default 300) |

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
  group id=rows (0,400 402x474)
    button "Inbox, 3 unread" (0,400 402x56)
    [off-screen below] 34 items: id=rows-item-9 to id=rows-end
# folded 2 repeated labels
```

On a foldable the header line ends with the display and posture, such as `inner open`.

`--summary` is short for `--flat --on-screen --labelled --format text --max-bytes 16384`. `--flat` lists nodes without nesting under `nodes`, each with `index`, `parent` and `depth`; `--on-screen` keeps nodes with at least 1 point on screen, judged as selectors judge it; `--labelled` keeps nodes with a label, id or value; `--actionable` keeps controls; `--fields` picks keys; `--format ndjson` prints a screen line and then one node per line; `--compact` prints JSON on one line. Without these flags the output is unchanged.

Text output (`--summary` and `--format text`) saves bytes in three ways; JSON and ndjson keep every node and label:

- A child whose label its parent already shows, whole or as one of its comma-separated parts (React Native merges `Inbox` and `3 unread` into `Inbox, 3 unread`), loses the label, and its line goes when nothing else is left (no id, value, control role or checked or selected state). A text's value equal to its label is left out. One closing `# folded N repeated labels` line counts them.
- With `--on-screen`, nodes wholly past an edge that would otherwise show are summarised where they start, per side and counting rows rather than their texts: `[off-screen below] 34 items: id=rows-item-9 to id=rows-end`, also `above`, `left` and `right`. Scroll that way to bring them on screen.
- Nested lines stop indenting at 10 levels.

`--max-bytes <n>` cuts text output at whole lines (UTF-8 bytes, newline included) so it fits `n` bytes, always keeping the header and the first node, and ends with `# truncated: 87 more nodes past the 16384-byte budget; pass --max-bytes 0 for all, or narrow with --actionable`. `--summary` defaults to 16384 bytes, `--max-bytes 0` lifts the limit, plain `--format text` has none unless asked, and with JSON or ndjson `--max-bytes` is a usage error (exit 64), as is a value from 1 to 511. When the Android device stops listing nodes at its own limit, text output ends with `# the device stopped listing nodes at its limit; this tree is incomplete`.

`describe-ui --diff` compares this read with the previous command's tree for the device (see [Privacy](#privacy)) and prints only what changed, in the `--summary` view unless `--format text` and filters are given:

```text
# ios <ID> 402x874 @3x portrait 0°
# changes since tap 840 ms ago: 1 added, 1 changed, 0 removed
changed text "State: Unread" id=filter-state value="Unread" (16,120 370x44) (was: text "State: All" id=filter-state value="All" (16,120 370x44))
added button "Apply" id=apply-filters (142,640 118x34)
```

A node is named by its `id` (UUIDs normalised), else by its role, label and position on a 4 pt grid. A screen with no change prints `# unchanged since <command> <n> ms ago (<hash>)`; with no earlier tree, or when 60 or more lines or over half of them changed, the full view follows a comment saying so. After a tap the base is the tree read before the tap, so tap then `--diff` shows what the tap did. `--diff` is text only, and refused with JSON formats, `--compact` and `--point`.

### Selectors

`--id`, `--label` and `--value` match `id`, `label` and `value`. Selectors prefer matches that are on screen: apps often keep views mounted off screen (a closed bottom sheet parked below the screen, rows below the fold), and a match whose frame lies outside the screen fails with an error naming its frame instead of tapping nothing. `--wait-timeout` waits for it to come on screen, and `--allow-offscreen` resolves it anyway. An element that is only partly on screen is tapped at the centre of its visible part. When no label or value matches exactly, typographic quotes and unusual spaces are folded (`--label "Don't Allow"` finds `Don’t Allow`), and a miss suggests the closest labels. On Android, `--id alert_title` also matches `com.example:id/alert_title` when no id matches exactly. `--element-type` matches `role` in any case or the native `type` exactly, so `button`, `Button` and `RadioButton` all work.

Selector `tap`, `slider` and batch `tap` steps guard against a target still moving from an earlier input, such as a sheet sliding in. They act at once when the last input was 500 ms or more ago, or when the target sits within 1 pt of where the cached tree had it; otherwise they wait out the rest of 500 ms (150 ms when there is no cached tree), read once more and tap the target where it is now. `--no-settle` turns this off, for scripted loops that already wait. Under `tap --verify` the verifier's own second read does the same job, so it reads the tree once fewer than before.

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

With `--json`, stdout is one JSON line per step (`step`, `kind`, `line`, `ok`, `ms`, plus `exitCode` and `error` on failure and each read step's own result), then a summary line with `steps`, `failed` and `dispatched` (`yes`, `no` or `unknown`: whether any step sent input); human text goes to stderr and ends a failure with `Dispatched: <state>`. A failed step's `error` is the [JSON error object](#json-errors). The batch exits with the code of its first step that failed to run, else 5 when a `wait`, `assert` or `screenshot --compare` condition was not met, else 0. Earlier steps may have run whatever the code, so resend a failed batch whole only when `dispatched` is `no`.

`tap` warns when another element may cover its target, for example a banner over a tab bar, and `--fail-if-covered` stops instead of tapping. An overlay that is hidden from accessibility cannot be detected this way.

### Device lock

Input commands (`tap`, `turnstile`, `type`, `swipe`, `drag`, `touch`, `gesture`, `key`, `key-combo`, `key-sequence`, `button`, `slider`, `shake`, `batch`, `rn prepare`, and `posture`, `orientation`, `appearance`, `content-size`, `permission`, `status-bar` and `biometric` when setting a value) lock the device for their run, so two agents cannot interleave input. On Android, any command that reads the screen through the helper or `uiautomator` (`describe-ui`, `wait`, `assert`, `screenshot --mask-secure`) also locks, since Android has one UiAutomation slot. A second command on a held device exits 8 with the reason `device_busy`, naming the holder's pid and command, and sends nothing. `--wait-lock <seconds>` (0 to 600) waits for the holder instead, and `OFFSIDER_WAIT_LOCK` sets that wait by default; it exists only on commands that can lock, so `logs`, `displays`, `stream-video` and `record-video` reject it with exit 64. `batch` takes the lock once for all its steps. Reads on iOS (`describe-ui`, `screenshot`, `wait`, `assert`, `logs`, `displays`, `list-devices`, `doctor` and the getters) never lock. Separate `touch --down` and `touch --up` commands each lock only for their own run, so another agent can act between them; keep a held touch in one `touch --down --up` or one `batch`. The lock is advisory: it stops other Offsider commands, not other tools.

Locks are files in a private per-user directory, `offsider-<uid>/locks/` under the per-user temp directory (`getconf DARWIN_USER_TEMP_DIR`), which ignores `TMPDIR` so agents with different sandboxes share one lock. When that directory cannot be used, Offsider falls back to `$TMPDIR/offsider-<uid>/`, and agents with different `TMPDIR` values then lock only among themselves. Each lock file is mode 0600 inside 0700 directories and holds only the holder's pid, command name and start time. The kernel drops a lock when its command exits, even when killed.

### React Native notes

- `testID` is `id` and `accessibilityLabel` is `label` on both platforms. A pressable row with neither takes its children's text as its label (`Inbox, 3 unread`), live values included, so prefer a `testID`.
- Views often stay mounted while off screen: a closed bottom sheet parked below the screen, or the previous screen of a JavaScript stack. On iOS they stay in the tree with off-screen frames; on Android nodes the user cannot see are left out. Selectors, `wait`, `assert` and `describe-ui --on-screen` count only what is on screen. A previous screen that is still partly on screen under the current one keeps its ids, so a duplicated id there needs `--element-type` or coordinates.
- Content under `accessibilityElementsHidden` or `importantForAccessibility="no-hide-descendants"` is not in the tree but still takes taps.
- On iOS, React Native writes the role of a checkbox, radio button, switch, tab, tab list, menu item, combo box or progress bar into the accessibility value, and Offsider reads it back: these report `checkbox`, `radioButton`, `switch`, `tab`, `tabBar`, `menuItem`, `picker` or `progress` instead of `other`, with `state.checked` and a `value` of `1`, `0` or `2` (mixed) for checkboxes, radio buttons and switches, as on Android. The new architecture writes only the checkbox and radio button words, so on it a combo box and a progress bar stay `other`. `native.type` keeps the platform's own type, so `--element-type Other` still finds them.
- `offsider logs --rn` prints `console.log`, `console.warn` and `console.error` output, in release builds too.
- A Cloudflare Turnstile checkbox's frame includes the words beside the square, so `tap` on that label misses the box. `offsider turnstile` taps the square and waits until the widget passes. On iOS the web view leaves the checkbox out of the tree, and the tap is the square where the green check sits. It does not bypass the check: see [Cloudflare Turnstile](#cloudflare-turnstile).
- `appearance`, `content-size` and `orientation` change the device for every later screen; set them back when done. On Android, `orientation` turns auto-rotate off. `orientation` names the device turn, so `landscape-left` is what React Native's and UIKit's interface orientation call landscape-right; `describe-ui` and `screenshot --json` report the shape as `orientation` and the turn as `rotation`.
- Debug builds: `rn prepare` skips an Expo dev client's first-launch intro. A LogBox error banner sits over the bottom of the screen and swallows taps; `tap` warns about it on both platforms, and `tap --verify` shows the tap had no effect.

### Cloudflare Turnstile

`offsider turnstile` taps the checkbox square a person would tap. It does not bypass Turnstile. Cloudflare still decides whether the device is eligible, and the widget passes only when Cloudflare accepts it. The command never mints, reads or submits a token, and never calls Cloudflare. A simulator or emulator is often not eligible: the checkbox stays, a visual challenge appears, or the app rejects the token, and the command cannot make that login succeed. Exit 0 means the widget on screen reads Success, not that the server accepted a token. `offsider guide turnstile` is the full note.

### Device state

`permission`, `status-bar`, `biometric` and `stay-awake` change state that outlives the command, and each has a reset. Setting a value already in place succeeds and says it changed nothing where the platform can read it. Set state before launching the app and reset it when done.

| Service | iOS (`simctl privacy`) | Android runtime permissions |
| --- | --- | --- |
| `all` | `all` | every runtime permission the app requests |
| `calendar` | yes | `READ_CALENDAR`, `WRITE_CALENDAR` |
| `camera` | not offered | `CAMERA` |
| `contacts` | yes | `READ_CONTACTS`, `WRITE_CONTACTS`, `GET_ACCOUNTS` |
| `contacts-limited` | yes | not offered |
| `location` | yes | `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` |
| `location-always` | yes | the above plus `ACCESS_BACKGROUND_LOCATION` |
| `media-library` | yes | `READ_MEDIA_AUDIO` |
| `microphone` | yes | `RECORD_AUDIO` |
| `motion` | yes | `ACTIVITY_RECOGNITION` |
| `notifications` | not offered | `POST_NOTIFICATIONS` |
| `photos` | yes | `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED` |
| `photos-add`, `reminders`, `siri` | yes | not offered |
| `bluetooth` | not offered | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` |
| `phone` | not offered | `READ_PHONE_STATE`, `CALL_PHONE`, `READ_CALL_LOG`, `WRITE_CALL_LOG` |
| `sms` | not offered | `SEND_SMS`, `RECEIVE_SMS`, `READ_SMS` |
| `body-sensors` | not offered | `BODY_SENSORS` |

- `permission` always needs `--app`; Offsider never changes every app's permissions at once. On Android it reads `dumpsys package` first, grants or revokes only what is not already in place, and also takes a literal `android.permission.NAME`. A service the app requests none of fails naming the manifest entries it needs; one it requests only some of applies to those and adds a note. `reset` revokes and clears the user-set and user-fixed flags so the app asks again (`reset all` also resets the app's app ops); it never runs `pm reset-permissions`, which resets every app. Android stops an app when one of its permissions is revoked, and the output says so. iOS simulators offer no read, so `show` is Android only and iOS reports earlier values as unknown.
- `status-bar` uses `simctl status_bar` on iOS. On Android it uses System UI demo mode in one adb round trip: `override` sets `sysui_demo_allowed` to 1 and sends the demo broadcasts, and `clear` exits demo mode and deletes the setting (the override's `--json` reports its earlier value, so a caller can restore it). Android cannot report whether demo mode is showing, and some vendor builds ignore it.
- `biometric` on iOS posts the BiometricKit notifications behind the simulator's Face ID and Touch ID menus: Face ID, or Touch ID on the iPhone SE and iPads other than iPad Pro (`--modality` overrides). On an Android emulator `match` touches the fingerprint sensor with finger 1 and `no-match` with finger 10 through the emulator console (`adb emu finger`, `--finger-id` overrides). `match` and `no-match` are events: nothing confirms the app saw them, so check its screen. Enrolling a fingerprint on Android needs a screen lock, which Offsider does not set, so `enrol` there explains how to do it in Settings.
- `permission`, `status-bar`, `stay-awake`, `wake` and `unlock-code` work on a named USB phone; `biometric` is refused there. Location simulation is not offered.

#### Screen, stay awake and unlocking

`stay-awake`, `wake` and `unlock-code` are Android only and refuse an iOS simulator or iPhone: simulators never sleep or lock, and an iPhone or iPad is unlocked by hand. Their output names a phone by maker and model, such as `Motorola moto g57 (ZY22FAKE01)`, and an emulator by its AVD name; commands in their messages keep the serial.

- `stay-awake on` writes the `stay_on_while_plugged_in` global setting that Developer options > Stay awake uses, for every power source (AC, USB, wireless and dock), and `off` writes 0. It survives reboots and keeps an awake screen on while the device charges, which a phone on USB and an emulator do; it does not turn a dark screen on. The output says when it has no effect: the device is not charging, charges over a source the setting leaves out, or a device policy caps the screen timeout.
- `wake` reads the screen and lock screen in one adb round trip (`dumpsys power`, `dumpsys window policy`) and sends nothing when the screen is on and unlocked. Otherwise it sends `KEYCODE_WAKEUP`, runs `wm dismiss-keyguard` and waits about 3 s. A swipe lock screen goes; a PIN, pattern or password lock screen stays, and `wake` exits 7 (`device_locked`).
- `wake --unlock` then types the PIN or password saved with `unlock-code set` (`input text`, then Enter), once, and only into a focused password field inside System UI's lock screen; with no such field it types nothing. A code that does not unlock the device is not typed again until the device is unlocked by hand (the next `wake` that finds it unlocked clears this) or the code is saved again, so a retrying agent cannot run up failed attempts towards a lockout or a wipe. Patterns are not supported, and a password is never typed into a PIN pad.
- `unlock-code set --device <phone serial or AVD name>` names a connected phone by maker and model (one `getprop`), asks for the code twice with typing hidden, or reads one line with `--stdin`, and keeps it in your login Keychain as a generic password (service `com.mpalmes.offsider.unlock-code`, never synchronised). `status` says whether a code is saved and whether its last attempt failed, never the code; `remove` deletes it. A code is 4 to 64 printable ASCII characters. Save codes only for test devices: anything that can run commands as you can then unlock them, and while `input text` runs the code is in its arguments on the device. macOS asks once before a new or rebuilt `offsider` reads the Keychain.
- When an Android command fails because a selector matched nothing, no window was found, `--verify` saw no change, or `wait`, `assert` or `screenshot --compare` was not met, and the screen is off or locked, the error says so and its hint becomes `offsider wake --device <id>`, in `--verify --json` errors too; the reason and exit code stay the same. A `--verify` that saw no change, `wait`, `assert` and `screenshot --compare` print their own result first, so they add a `Note:` line on stderr instead.

### Foldables

A foldable has a `cover` and an `inner` display, and one of them is active at a time. `offsider displays` lists both and marks the active one, and `offsider posture` reads the posture (`closed` uses the cover display, `open` the inner one). `describe-ui`, `tap` and the other input commands use the active display, and `screenshot` captures it unless `--display` names the other one. `describe-ui --display inner` fails with a hint while the inner display is not active, so a script can check it is reading the screen it expects.

- iOS: `posture` folds and unfolds the iPhone Duo simulator by driving its hinge the way Device Hub does (a private CoreDevice path, best effort on Xcode 27.1; where the runtime has no hinge service the command says so and exits 1). Folded, the cover display is 466 x 678 pt; unfolded in portrait, the inner display is 951 x 669 pt (landscape-shaped, rotation 0: `screen.rotation` is the device's turn from portrait, as `orientation --json` reports it, not the UI's turn on the panel). The Duo refuses orientation changes.
- Android: `offsider posture open` (or `closed`, `half-opened`) folds the emulator through its gRPC endpoint, or `cmd device_state` over adb, and waits until the device reports it. A Pixel 9 Pro Fold emulator's inner display is about 852 x 883 dp and its cover display about 443 x 994 dp. Folding it shows "Swipe up to continue" on the cover, over the app, which keeps running: swipe up from the bottom edge to use it.

### Android notes

- IDs are emulator serials (`emulator-5554`), the names of running AVDs, or USB phone serials; `list-devices` shows all three. `boot` starts an AVD with its window (`--headless` hides it), passes only `-no-metrics` to the emulator, writes the emulator's output to `$TMPDIR/offsider-boot-<avd>.log` and never starts a second instance of an AVD that is already running.
- Coordinates, frames and `--delta` are in dp, the Android equivalent of points.
- Every screen read (`describe-ui`, selectors, `--wait-timeout`, `--verify`, `gesture` presets, `slider` and `type --replace`) goes through a small helper that Offsider pushes to `/data/local/tmp/offsider-helper-<hash>.dex` when that copy is missing, and runs with `app_process` as the shell user for the length of one command. A `describe-ui` takes about 0.3 s and a verified tap 1 to 1.5 s on a quiet Mac; both are slower while the Mac running the emulator is busy, because Android then starts the helper more slowly. Commands that only send input, such as `tap -x -y`, `swipe`, `key` and plain `type`, never start it unless `OFFSIDER_ANDROID_INPUT=helper` is set, and a plain `screenshot` starts it only with `OFFSIDER_ANDROID_CAPTURE=helper`.
- While the helper runs it holds Android's single UiAutomation connection, and the emulator reports an accessibility service as enabled (`accessibility_enabled`), which some apps notice. Both end with the command.
- Another UiAutomation client, such as Appium, Maestro, `uiautomator` or Layout Inspector, makes these commands fail with a message saying so: stop that client, then retry. An earlier Offsider helper that still holds the connection after 2 s (usually a command running in parallel) is named with its pid: it exits within 10 s of losing its command, or `adb -s <serial> shell kill <pid>` stops it at once.
- If the helper cannot run (for example the push fails, or the Android version lacks the API it uses), Offsider prints one `Warning:` line saying why and reads the screen with `uiautomator` instead, at about 2 s per read. `slider` then fails, as `uiautomator` reports no slider values.
- `--verify` leaves the status and navigation bars, as the helper measures them, out of screenshot comparisons; with gesture navigation there is no navigation bar to leave out. `--tap-style` and the `style` field keep their names: `simulator` is a single tap and `physical` a timed touch down and up.
- `slider` sets the value through Android's accessibility progress action, and drags when the control does not take it. A control whose steps cannot show the value stops at the nearest step, and the success line says so, for example `Slider set to 78 (the nearest step to 78.25)`. Apps that act only when a drag ends, such as React Native's `onSlidingComplete`, may not see the change; use `drag` on the track for those.
- `type` sends ASCII text as key events. Text with any other character is pasted through the emulator's clipboard, which Offsider saves first and restores afterwards. Into a focused password field that paste is refused, so a secret never reaches the clipboard: use `type --replace`, which sets the field without it. The emulator's clipboard sharing may copy a paste to the Mac's pasteboard; this has not been checked. Over adb, `input text` briefly shows the text in the emulator's process list to other shell-user processes; the gRPC transport avoids this.
- `type --replace` sets the focused field's text in one accessibility action, so any Unicode text works without gRPC, but key handlers such as `onKeyPress` do not run. A trailing newline is then pressed as Return, so `type --replace $'query\n'` submits a search field; other newlines become line breaks. A field that refuses the action, or an emulator where the helper cannot run, gets Ctrl+A, Delete and typing instead, with a warning. With nothing focused it fails: tap the field first.
- Offsider talks to the adb server and to the emulator's gRPC endpoint on loopback. An emulator started with `-port` has no gRPC endpoint, so Offsider falls back to adb: screenshots are slower, `type` accepts ASCII only (`type --replace` still takes any text) and `stream-video --format bgra` is unavailable.
- `stream-video --format bgra` sends a frame when the screen changes, not at a fixed rate, so a still screen sends one frame.
- `doctor --device <serial or AVD>` runs read-only Android checks: the SDK, adb and its server (on loopback, and whether its mDNS discovery is off), the emulator package, the bundled helper, then the emulator's state and system image, its gRPC endpoint with the auth mode (never the token), the UiAutomation slot and any accessibility service, one helper start with its times, and any Metro reverse (shown, never changed). The helper start holds UiAutomation for about half a second, so it is skipped while another Offsider helper runs. `doctor` never kills a process, restarts the adb server or changes a setting; `--fix` only starts an absent adb server with `ADB_MDNS=0`.
- `batch` starts the helper once and reuses it for every step, so several reads in one `batch` pay the helper start once; prefer it to separate commands when no reasoning is needed between reads.
- For troubleshooting, `OFFSIDER_ANDROID_TRANSPORT=adb` (or `grpc`) forces one transport, `OFFSIDER_ANDROID_GRPC_AUTH=jwt` makes Offsider sign in to gRPC with a short-lived key instead of the emulator's token, and `OFFSIDER_ANDROID_TREE=uiautomator` (or `helper`) forces one way of reading the screen: `uiautomator` never starts the helper, and `helper` makes an unavailable helper an error instead of a fallback. `OFFSIDER_ANDROID_INPUT` and `OFFSIDER_ANDROID_CAPTURE` choose how input and screenshots run without gRPC (see Physical Android phones).

### Physical Android phones

- Offsider drives a phone connected over USB, and only when you pass its serial to `--device`. AVD names, `boot`, the playground scripts and the test suites only ever choose emulators, so an attached phone is never picked by accident. A name that is both a phone's serial and a running AVD's name is refused as ambiguous.
- Turn on Developer options and USB debugging on the phone, connect the cable, unlock it and accept the "Allow USB debugging?" prompt. Until then `list-devices` shows the phone as `Unauthorised` with a hint on stderr; Offsider never tries to accept the prompt. Some vendor builds (for example MIUI) also need a "USB debugging (security settings)" switch before input and screen reads work.
- `list-devices` reads phones from adb's device list alone, with the model adb reports and no OS version, and never sends a listed phone a command. Wi-Fi and TCP adb connections (`adb connect`, wireless debugging) are listed as `Unsupported` and refused: connect the phone over USB.
- A phone has no emulator gRPC endpoint, so every command uses adb: screenshots use `screencap -p`, input uses `input` (or the helper, below), and rotation, appearance and content size use `settings` and `cmd uimode`. Plain `type` of non-ASCII text is refused with a pointer to `type --replace`, which sets the field through the helper. `boot`, setting a `posture` (reading it works), `biometric`, `stream-video --format bgra` and `OFFSIDER_ANDROID_TRANSPORT=grpc` are refused on a phone with a message naming the alternative.
- `doctor --device <serial>` checks a phone from its row in adb's device list: its state, system image, screen and lock screen, stay awake, the UiAutomation slot, one helper start, any reverse, whether this Mac's adb authorisation lapses (Developer options > Disable adb authorization timeout) and whether automatic system updates can restart it. The emulator gRPC check is skipped, and the report says why.
- For long or overnight runs, run `offsider stay-awake on --device <serial>` so the screen never sleeps and the lock screen never returns while the phone charges; with a PIN, unlock it once and it stays unlocked until it reboots or is unplugged. Turn off automatic system updates and the adb authorisation timeout in Developer options. `offsider wake --unlock` can unlock a test phone with a code saved by `unlock-code set`.
- The helper works as on an emulator: it is pushed to `/data/local/tmp/offsider-helper-<hash>.dex` and holds UiAutomation, with `accessibility_enabled` reading 1, only while one command runs.
- Input and screenshots without gRPC (a phone, or an emulator with `OFFSIDER_ANDROID_TRANSPORT=adb`) can also go through the helper. By default, `OFFSIDER_ANDROID_INPUT=auto` sends input through the helper only when the command has already started it to read the screen (a selector tap, `type --replace`), and through `input` otherwise; `OFFSIDER_ANDROID_CAPTURE=auto` uses `screencap -p`. The defaults come from medians on a Galaxy Z Fold3 (USB 3) and a moto g57 (USB 2): starting the helper costs 280 to 390 ms per command, while an injected tap saves only 40 to 75 ms over `input`. Through the helper, a coordinate `tap` was 61% and 90% slower, `swipe` 40% and 52%, `type` 92% and 110% and `screenshot` 33% and 63%; raw `screencap` encoded on the Mac was 60% slower in a debug build. A selector tap with `--verify` was 2 to 5% faster under `auto`. Injection as the shell user worked on One UI 6 (API 34) and Android 16 (API 36).
- `OFFSIDER_ANDROID_INPUT=helper` sends all such input through the helper, starting it if needed, and fails with a hint when the helper cannot start or another command holds it; `input` never uses the helper. `OFFSIDER_ANDROID_CAPTURE=screencap` takes the device's PNG, `raw` reads `screencap`'s raw pixels and encodes the PNG on the Mac, and `helper` takes the pixels through the helper; `raw` and `helper` fall back to `screencap -p` when they cannot serve (`helper` with a `Warning:` line). While the helper carries input, Android reports an accessibility service as enabled for the length of the command, as it does for screen reads. Through the helper, a key or button can stay held across other input, which `input` refuses.
- Separate `touch --down` and `touch --up` commands always use `input motionevent`, whatever `OFFSIDER_ANDROID_INPUT` says. On a phone with several displays, such as the Galaxy Z Fold3, `screenshot` captures the active display: it keeps `screencap`'s own pick (skipping the warning printed before the image) when that has the active display's size, and otherwise captures again with `screencap -d` and the active display's platform ID, as `offsider displays` lists it. Later captures in the same command, such as `record-video` frames, pass `-d` straight away.
- Offsider never sets `adb reverse`. To reach Metro from a debug build on a phone, run `adb -s <serial> reverse tcp:8081 tcp:8081` yourself (8742 for the playground), and `adb -s <serial> reverse --remove tcp:8081` when done; while it is set every app on the phone can reach Metro, so prefer release builds on phones.
- A phone's screen and notifications reach `describe-ui` and screenshots, and from there whatever your agent sends to its model provider; Offsider itself sends nothing. Turn on Do Not Disturb first.

### Physical iPhones and iPads

- Offsider drives an iPhone or iPad connected over USB, and only when you pass its UDID to `--device`; nothing else ever chooses one. A device connected over Wi-Fi is refused with `device_not_wired` (exit 7) and a hint to connect its cable. Offsider never pairs a device, and never accepts a prompt on it.
- Prepare the device once: connect the cable, unlock it and tap Trust, turn on Developer Mode (Settings > Privacy & Security > Developer Mode, then restart it), and for input turn on Settings > Developer > UI Automation. Until then `list-devices` shows it as `Untrusted`, `Developer Mode off` or `Preparing` (while Xcode prepares it for development) with a hint on stderr. Keep it unlocked while Offsider drives it: a locked device refuses input with `device_locked` (exit 7). Unlock it by hand, as Offsider never types an iPhone passcode.
- `list-devices` reads iPhones and iPads from `xcrun devicectl list devices`, with `kind` `physical` and `connection` `usb` or `network`. `doctor --device <UDID>` runs the `ios-device.*` checks: `xcode`, `coredevice`, `listed`, `transport`, `pairing`, `developer-mode`, `ddi`, `tunnel`, `lock-state`, `hid`, `ui-automation`, `session`, `usbmuxd` and `runner-signing`. `ios-device.hid` opens the HID button socket and round-trips a barrier on it. iOS does not report the UI Automation setting, so `ios-device.ui-automation` is skipped with the Settings path unless the unlocked device refused input. `ios-device.session` reports the session broker and its screen stream, and is a skip when none is running: doctor never starts one. `--fix` only mounts the developer disk image.
- On an Xcode 27 host (CoreDevice 636 or later), screenshots and input go through a session broker, one per device. The first command that needs it starts it in the background. It holds the device's CoreDevice screen stream, its UniversalHID service (touchscreen and keyboard) and its hardware button socket, so later commands skip that setup. Taps, touches, swipes, gestures, drags, keys and US keyboard text are sent as UniversalHID reports, and the `home`, `lock`, `side-button` and `siri` buttons as button events. `apple-pay` is refused; press `side-button` twice instead.
- Measured on an iPad Pro over USB with Xcode 27, with the broker running: `tap` 132 to 148 ms, `type` 69 to 84 ms, `button home` 151 to 164 ms, a 0.3 s `swipe` about 370 ms and `screenshot` about 230 ms. The first command after the broker has stopped pays about 3 s to start it and its stream.
- The broker stops after `OFFSIDER_IOS_SESSION_IDLE` seconds without a command (default 300), when the device goes, or on `offsider session stop`. While it runs, the device shows its screen-sharing indicator; stopping the broker ends the stream and clears it. `offsider session status` lists each device's broker and runner without starting either, and `session stop` stops both (`--device`, `--json`); `runner status` and `runner stop` still cover the runner alone. Run `offsider session stop --device <UDID>` when you are done with a device.
- The broker needs a logged-in desktop session on the Mac: run Offsider from a terminal there, not over plain `ssh`. Without one, screenshots fall back to `devicectl device capture screenshot` (about 2.3 s each, with a one-line notice) and input falls back to the runner, as the table shows.

| | Xcode 27, broker | Xcode 27, no broker | Xcode 26 |
| --- | --- | --- | --- |
| `list-devices`, `doctor`, `appearance`, `content-size`, `orientation` | yes | yes | yes |
| `screenshot` | stream | `devicectl` | `devicectl` |
| `describe-ui`, `wait`, `assert` (runner) | yes | yes | yes |
| Element and coordinate `tap`, `swipe`, `button home` | broker | runner | runner |
| Plain ASCII `type` | broker | runner | `xcode_too_old` |
| Non-ASCII `type`, `type --replace` | runner | runner | runner |
| `key`, `key-sequence`, `key-combo`, `touch`, `gesture`, `drag`, the other buttons | broker | refused | `xcode_too_old` |

- `xcode_too_old` exits 9 with the hint to install Xcode 27 for HID input. The device can run iOS or iPadOS 26 or 27; HID input needs Xcode 27's developer disk image on it, which Xcode 27 mounts.
- The accessibility tree comes from a small XCUITest runner app. The first command that reads the screen builds it from source bundled with Offsider, with `xcodebuild` (about a minute, with a line on stderr), into `~/Library/Caches/offsider/runner/`; the build is reused until the source, Xcode or team changes. It is signed with the team in `OFFSIDER_IOS_TEAM_ID`, or with the one team signed in to Xcode; with none, or several, commands exit 9 with `team_missing`. A failed build exits 1 with `runner_build_failed` and names its log.
- The runner is launched detached with `xcodebuild test-without-building` and listens only on the device's loopback, with a token per session. Offsider reaches it through usbmuxd (`/var/run/usbmuxd`), which connects USB devices only. It keeps running so later commands answer quickly, and stops after `OFFSIDER_IOS_RUNNER_IDLE` seconds without a request (default 300). `offsider runner status` lists sessions and `offsider runner stop` stops them (`--device`, `--json`); the token is never printed.
- XCTest reads one named app, or the Home Screen. `describe-ui`, `tap`, `wait` and `assert` take `--app <bundle-id>` on a device, and later commands remember it; simulators and Android ignore it. Without it the runner reads the app in front when it can tell which that is, else the Home Screen. A named app that is not in front fails with a message saying so.
- An iPad app in a Stage Manager window reports frames relative to its window, so element taps (`tap --id`, `tap --label`) are refused with `not_supported` and a hint to make the app full screen. Coordinate taps, screenshots and the tree itself still work.
- `--verify` may take several screenshots: about 230 ms each from the stream, 2.3 s each through `devicectl`. Prefer `wait` or `assert` when the tree shows the effect. `record-video` and `stream-video` build each frame from a screenshot, so their frame rate is low.
- `appearance` and `content-size` read and set the device through `devicectl`, and `orientation` turns it. The screen follows a new orientation only while the device is awake and unlocked and the app in front supports it; otherwise the command times out and says so.
- Refused on a device, with a message naming the alternative where there is one: `permission`, `status-bar`, `biometric`, `shake`, `posture`, `stream-video --format bgra`, `logs`, `rn prepare`, a `touch --down` without `--up` in the same command, `boot`, `wake`, `stay-awake` and `unlock-code`. Install and launch apps with `xcrun devicectl`.
- A device's screen and notifications reach `describe-ui` and screenshots, and from there whatever your agent sends to its model provider; Offsider itself sends nothing. Turn on a Focus first.

### Agent skill and guide

`offsider init` installs one short `SKILL.md`: the core loop, the rules every session needs and a table of topics. The depth lives in topics printed on demand by `offsider guide <topic>`, so an agent reads only what the task needs and always gets the text that matches the installed binary. `offsider guide` lists the topics and when to read each; an unknown topic exits 64.

### Coming from idb, Maestro or agent-device

`offsider guide migrate` maps each tool's commands to Offsider, marking every row same, renamed, missing or by design. The most common:

| From | Offsider |
| --- | --- |
| `idb list-targets` | `list-devices` |
| `idb ui describe-all`, agent-device `snapshot` | `describe-ui --summary` |
| `idb ui tap X Y`, agent-device `press` | `tap -x X -y Y`, or `tap --id` and `tap --label` |
| Maestro `tapOn` | `tap --id` or `tap --label` |
| `idb ui text`, Maestro `inputText` | `type` |
| agent-device `fill`, Maestro `eraseText` | `tap` on the field, then `type --replace` |
| Maestro `assertVisible`, `extendedWaitUntil` | `assert --id`, `wait --id` |
| Maestro `waitForAnimationToEnd` | `wait --settled` |
| `idb approve`, `idb revoke` | `permission grant`, `permission revoke` |
| `idb record video`, `idb video-stream` | `record-video`, `stream-video` |

Installing and launching apps stays with `xcrun simctl` and `adb`, and Offsider keeps no element refs or session state: selectors and the automatic device lock cover them.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success; for `doctor`, every check passed or was skipped |
| 1 | The command failed for any other reason; the error is printed to stderr |
| 2 | The selector matched nothing, or only elements off screen |
| 3 | `doctor` found warnings |
| 4 | `doctor` found failures |
| 5 | A condition was not met: `--verify` saw no change after the input, `wait` timed out, `assert` failed, `turnstile` left the checkbox on screen, `screenshot --compare` found no change, or a `batch` had only such failures |
| 6 | The selector matched more than one element |
| 7 | The device was not found or is not booted, or its lock screen stayed up |
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

A verified `--verify --json` report also lists what changed: `changes` holds up to 10 entries, value and state changes first, then added, removed and moved nodes, each as `{"kind": "changed", "node": "text \"State\" id=state", "field": "value", "old": "All", "new": "Unread"}` (`kind` is `added`, `removed` or `changed`; `field`, `old` and `new` are null where they do not apply). `changesTruncated` counts the entries left out, and `note` is `keyboard_closed` when the keyboard left and nothing outside it changed except frames: the input may have been spent closing the keyboard, so repeat it if the control shows no effect. A change seen only in the screenshot gives `changes: []`.

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
| `device_locked` | 7 | A PIN, pattern or password lock screen stayed up after `wake`, or its saved code did not unlock it, or an iPhone or iPad is locked and refused input | Unlock it on the device, or on Android `offsider wake --unlock` with a code saved by `offsider unlock-code set` |
| `device_ambiguous` | 7 | An AVD name matches more than one running emulator, or names both a phone and an AVD | Pass one serial with `--device` |
| `avd_not_found` | 7 | No AVD has that name | Check the name in Android Studio's Device Manager |
| `device_not_wired` | 7 | The iPhone or iPad is connected over Wi-Fi, and Offsider drives it over USB only | Connect its cable |
| `device_untrusted` | 7 | The iPhone or iPad has not trusted this Mac | Unlock it and tap Trust |
| `developer_mode_off` | 7 | Developer Mode is off on the iPhone or iPad | Turn it on in Settings > Privacy & Security, then restart the device |
| `device_preparing` | 7 | Xcode is still preparing the iPhone or iPad for development | Wait for Xcode to finish, then retry; `offsider doctor --device <UDID>` shows progress |
| `ui_automation_off` | 7 | UI Automation is off on the iPhone or iPad | Turn it on in Settings > Developer |
| `device_busy` | 8 | Another Offsider command holds the device; the message names its pid | Wait and retry, or pass `--wait-lock <seconds>` |
| `uiautomation_busy` | 8 | Another UiAutomation client holds the emulator | Stop that client, or run the `hint`, then retry |
| `xcode_missing` | 9 | No usable Xcode is selected | `xcode-select -s <Xcode.app>/Contents/Developer` |
| `xcode_unusable` | 9 | The selected Xcode cannot load simulator support | Select Xcode 26 or later |
| `android_sdk_missing` | 9 | No Android SDK or adb was found | Install Platform-Tools or set `ANDROID_HOME` |
| `adb_server_unavailable` | 9 | The adb server is not running or not answering | `adb start-server` |
| `adb_server_misconfigured` | 9 | The adb server settings point off this Mac or cannot be read | Fix or unset the adb server variables |
| `emulator_missing` | 9 | The Android Emulator is not installed | Install it with the SDK Manager |
| `emulator_grpc_required` | 9 | The command needs the emulator's gRPC endpoint and it is not reachable | Restart the emulator with `offsider boot` |
| `helper_unavailable` | 9 | The UiAutomation helper cannot run on this device | Unset `OFFSIDER_ANDROID_TREE` or `OFFSIDER_ANDROID_INPUT`, or use another image |
| `xcode_too_old` | 9 | The selected Xcode cannot drive this feature on an iPhone or iPad | Select Xcode 27 or later |
| `team_missing` | 9 | No signing team was found for the iPhone runner | Set `OFFSIDER_IOS_TEAM_ID`, or sign in to one team in Xcode |
| `usbmux_unavailable` | 9 | usbmuxd, which reaches iPhones over USB, is not answering | Reconnect the cable; restart the Mac if it persists |
| `usage` | 64 | Invalid arguments or options | Fix the command line; see `--help` |
| `invalid_device_id` | 64 | The device ID is empty or not a device ID | `offsider list-devices` |
| `invalid_setting` | 64 | An `OFFSIDER_` variable has a value Offsider cannot read | Fix or unset it |
| `unsupported_button` | 64 | The device's platform has no such button | Use a button the platform has |
| `unsupported_key` | 64 | The key has no equivalent on the device | Use a supported key |
| `unknown_display` | 64 | `--display` names no display on the device | `offsider displays --device <ID>` |
| `legacy_argument` | 64 | A renamed option or command, such as `--udid` | Use the new name in the message |
| `not_verified` | 5 | `--verify` saw no change after the input (reports only) | Check the screen before sending again |
| `condition_not_met` | 5 | A `wait`, `assert`, `turnstile` or `screenshot --compare` condition was not met | Read the message: the checkbox was still there, or the widget was still checking |
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
| `not_supported` | 1 | The device or platform does not support the command or option, such as a network adb device or an emulator-only feature on a phone | Use another device or option |
| `posture_failed` | 1 | The posture could not be set | Check it with `offsider posture --device <ID>` |
| `state_not_reached` | 1 | The posture or orientation did not take effect in time | Check the device, then retry |
| `orientation_unknown` | 1 | The device did not report its orientation | Check it with `describe-ui` |
| `device_restarted` | 1 | The simulator restarted while Offsider connected | Retry |
| `device_unresponsive` | 1 | The device stopped answering | `offsider doctor --device <ID>`, or restart the device |
| `device_control_failed` | 1 | A device setting could not be read or changed | Check the device is booted |
| `app_not_installed` | 1 | `logs --app` or an Android permission command names an app that is not installed | Install it (`adb -s <serial> install <apk>` on Android), or drop `--app` |
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
| `hid_broker_failed` | 1 | The HID broker that sends iOS input, or an iPhone or iPad's session broker, failed | `offsider doctor --device <ID>`; on a device, `offsider session stop --device <UDID>` restarts the broker |
| `private_directory_unsafe` | 1 | The HID broker directory is not private to this user | `offsider doctor --device <ID> --fix` |
| `timed_out` | 1 | A helper process did not finish in time | Retry |
| `init_failed` | 1 | `init` could not install or remove the skill, or `guide` could not read a bundled topic | Read `message` |
| `device_list_failed` | 1 | Devices could not be listed | Read `message` for each platform |
| `expo_dev_client_failed` | 1 | `rn prepare` could not prepare the Expo dev client | Read `message` |
| `runner_build_failed` | 1 | The iPhone runner could not be built or signed | Read `message`; check the team and the device in Xcode |
| `runner_unavailable` | 1 | The iPhone runner did not answer; no input was sent | Retry; `offsider doctor --device <UDID>` |

## Privacy

Offsider has no telemetry and no accounts. It never connects to non-loopback addresses and never resolves hostnames; it may use Unix sockets and loopback TCP to local developer daemons (the adb server, the Android Emulator and usbmuxd), so nothing leaves your Mac. It talks to simulators through Xcode's frameworks, and beyond the files you ask for it writes only to a private per-user directory, `offsider-<uid>/` under your user temp directory (mode 0700): device locks, and the last accessibility tree read from each device, so `describe-ui --diff` and the tap guard can compare against it. Each tree is one 0600 file per device, named by a hash of the device ID, holding the neutral tree with password values already masked and platform attributes left out, the command that wrote it and when. It is overwritten by the next command, ignored after 10 minutes or a reboot of the device, and capped at 1 MB. `OFFSIDER_TREE_CACHE=off` turns it off. After a saved unlock code fails, an empty `unlock/device-<id>.failed` file there stops Offsider typing it again. Unlock codes saved with `unlock-code set` live only in your login Keychain. For an iPhone or iPad it also keeps, under `ios-devices/<UDID>/`, the runner session (pid, port and its token, mode 0600), the runner log, the session broker's record and log, and the display geometry, and `devicectl` screenshots pass through a `captures/` folder there and are removed once read. The session broker listens on a 0600 Unix socket in the private directory's `sessions/` and refuses other users, and its screen stream reaches the Mac only through CoreDevice's USB tunnel; the runner build lives in `~/Library/Caches/offsider/runner/`. See [SECURITY.md](SECURITY.md) for what it touches.

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
OFFSIDER_ANDROID_PHONE=<serial> make e2e-android-phone  # run the phone suites on one USB phone
OFFSIDER_IOS_DEVICE=<UDID> OFFSIDER_IOS_TEAM_ID=<team> make e2e-ios-device  # run the device suites on one iPhone or iPad
```

`make e2e-foldable` sets `OFFSIDER_FOLDABLE_E2E=1` and runs `FoldableTests` on an iPhone Duo simulator, folding and unfolding it with `offsider posture`. `make e2e-android-fold` sets `OFFSIDER_ANDROID_FOLD_E2E=1` and `OFFSIDER_ANDROID_E2E_AVD=Offsider_E2E_Pixel_9_Pro_Fold`; the Android suites drive only that AVD and `Offsider_E2E_Pixel_9`. `make e2e-android-phone` (`./test-runner.sh --android-phone`) runs the `AndroidPhone*Tests` suites on the one USB phone whose exact serial `OFFSIDER_ANDROID_PHONE` names, and refuses beside `OFFSIDER_ANDROID_E2E`. It installs the React Native playground APK on that phone and leaves it there; Google Play Protect may ask on the phone to send the app for a security check on the first install, so answer it there. `make e2e-ios-device` (`./test-runner.sh --ios-device`) sets `OFFSIDER_IOS_DEVICE_E2E=1` and runs the device suites on the one iPhone or iPad whose UDID `OFFSIDER_IOS_DEVICE` names, signing the runner with `OFFSIDER_IOS_TEAM_ID`; the device must be on its cable, unlocked and with UI Automation on.

`make e2e-rn-debug-ios` and `make e2e-rn-debug-android` build the React Native debug app, run Metro on loopback port 8742 and run the debug smoke suite. `pnpm --dir OffsiderPlaygroundRN ios <udid>` or `android <serial|avd>` installs the debug app and runs it from the same background Metro (`scripts/rn-playground.sh metro stop` ends it).

Committed, scrubbed trees of the React Native playground live in `Tests/Goldens/trees/`, with a byte budget per screen in `budgets.json`: `swift test` fails when a `--summary` or `--format text` rendering outgrows its budget, or when a budget sits more than 20 percent above it. After a mapping or renderer change, `OFFSIDER_GOLDENS_UPDATE=1 swift test --filter TreeGoldenRefresh` re-renders them offline; `Tests/Goldens/README.md` covers recapturing from a device.

`OFFSIDER_TIMINGS=1` prints phase timings for a command to stderr, as `offsider timing: <phase> <n> ms` lines; `tree-cache` is a tree cache read or write, `tree-diff` the `--diff` comparison and `settle` the transition guard's wait and second read. Android commands add `prepare`, `adb-devices`, `adb-shell`, `display-probe`, `helper-launch`, `dex-push`, `helper-hello`, `helper-dump`, `tree-map`, `helper-close`, `helper-inject` (input through the helper), `helper-capture` (a helper screenshot), `capture-encode` (encoding raw pixels as PNG on the Mac), `grpc-connect`, `grpc-call`, `input` and `capture`; an iPhone or iPad adds `runner` (connecting to or starting the runner), `accessibility` (the runner's snapshot), `session` (connecting to or starting the session broker), `stream-capture` (a frame from the broker's stream) and `capture` (a `devicectl` screenshot). The broker writes its own `stream-open` and `stream-frame` lines to `ios-devices/<UDID>/session.log` when the command that started it had `OFFSIDER_TIMINGS=1`. A phase that repeats prints one line each time.

`scripts/bench-ab.sh --device <id> --scenario android-describe` compares a base build (the merge base with `origin/main` by default, built once in a detached worktree under `$TMPDIR`) with this checkout on one Offsider device, in paired runs whose order comes from `--seed`. Pairs whose exit code or output differ are dropped; the summary gives medians per side and per phase, a bootstrap 95% interval of the change and a verdict (`faster`, `slower`, `same` within 5% or 10 ms, or `unresolved`). Records go to `${OFFSIDER_BENCH_DIR:-$TMPDIR/offsider-bench}` as hashes, never output, and only Offsider-named simulators and the Offsider E2E AVDs are driven. `--phone --device <serial> --scenario android-tap-xy` (or another `android-*` scenario) benchmarks a USB phone instead: the serial must match an `adb devices -l` row with `usb:` and state `device`, and the React Native playground must already be installed, as bench never installs it. `--help` lists the scenarios.

The simulator frameworks come from [michael-palmes/idb](https://github.com/michael-palmes/idb), a mirror of facebook/idb with Cameron Cooke's Xcode 27 changes on the `offsider/xcode27` branch (tag `offsider-idb-v0.2.0`). `scripts/build.sh` pins the exact revision and verifies it before building.

The iPhone runner's source is in `Sources/Offsider/Resources/runner/`: an XcodeGen `project.yml` with the generated `OffsiderRunner.xcodeproj` committed beside it. After changing `project.yml`, run `scripts/build.sh runner` to regenerate the project, and `scripts/build.sh runner --check` regenerates it and compares it with the committed project. Both need XcodeGen.

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
