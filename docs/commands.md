# Commands

Every device command takes `--device <id>`, using an ID from `offsider devices`: a simulator UDID (case-insensitive), a USB iPhone or iPad's UDID (such as `00008130-001C...`), an Android emulator serial such as `emulator-5554`, the name of a running AVD, or a USB phone's serial. Without `--device`, a command uses `OFFSIDER_DEVICE` when it is set and not blank; `--device` always wins, and with neither the command exits 64. `OFFSIDER_DEVICE` never names a physical device: a phone, iPhone or iPad must be [allowed](device-access.md) and named with `--device` on every command, so `doctor --fix` needs `--device` too. `doctor` prints the binding (`device.source` is `environment` in `--json`); `permission services` and the `--device` filters of `runner` and `session` ignore it. `offsider <command> --help` lists every option. In 0.3.0, `--udid` became `--device` and `list-simulators` became `list-devices`, and both old names exit 64 with a hint. `list-devices` is now `devices`, and still lists. `device-access` is now `devices add`, `remove` and `status`, and exits 64 naming them. On a terminal, a person sees [their own view](agents.md#what-a-person-and-an-agent-see) of each command; an agent or a pipe reads plain text.

| Command | What it does |
| --- | --- |
| `devices` | List iOS simulators (iPhone and iPad), allowed iPhones, iPads and USB Android phones, running Android emulators and shut-down AVDs with their IDs as a table, booted and booting ones first on each platform, or as [JSON](#device-list-json) with `--json`; `--platform ios\|android` filters, `--booted` keeps only booted and booting devices, and `--physical` lists every connected physical device, allowed or not, for a person; beside `add`, `remove` or `status` these three exit 64 naming the listing command. A person sees rows grouped by kind behind status dots, ending with a `Next` command on stderr ([first run](getting-started.md#first-run)) |
| `devices add` | Let agents drive a physical iPhone, iPad or Android phone: a person at a terminal picks the device, team, app and how long from menus, then Touch ID; a phone also gets the Metro ports `rn open` may reverse (`--device`, `--app`, `--expires`, `--team`, `--metro-port` skip a step; [physical devices](device-access.md)) |
| `devices remove` | Withdraw one, picked from a menu on a terminal or named with `--device`, and stop its runner and session broker (`--json`) |
| `devices status` | The phones and tablets agents may drive, until when, and any managed policy; `--device` exits 7 unless that one is allowed (`--json`) |
| `boot` | Start an Android emulator by AVD name, or an iOS simulator by name or UDID, wait until it has booted and print its serial or UDID; a device that is already running is not started again ([starting an emulator](android.md#starting-an-emulator)) |
| `doctor` | Check the host, Xcode, Device Hub, simulators and the Android SDK, or one device with `--device`; `--json` prints one object and `--fix` applies safe fixes ([doctor](troubleshooting.md)) |
| `describe-ui` | Print the screen's UI as versioned, platform-neutral JSON, a short text view (`--summary`), only what changed since the previous command (`--diff`), or the element at `--point x,y`; `--on-screen` keeps only what a touch reaches ([reading the screen](reading-the-screen.md), [what counts as on screen](reading-the-screen.md#what-counts-as-on-screen)) |
| `init` | Install or update the bundled agent skill once per skills folder, and add permission rules for Claude Code and Codex where installed (`--client auto\|claude\|agents`, `--dest`, `--force` to replace another skill named offsider, `--uninstall`, `--print`, `--no-rules`, `--rules-only`, `--print-rules`; [agent skill](agents.md#agent-skill-and-guide)) |
| `guide` | Print one topic of the skill, matched to this version (`selectors`, `verify`, `errors`, `android`, `ios-device`, `react-native`, `turnstile`, `login`, `foldables`, `batch`, `screenshots`, `evidence`, `describe-ui`, `device-state`, `apps`, `migrate`), or list the topics with no argument; `--project <path>` prints the repository's own `OFFSIDER.md` |
| `tap` | Tap a point (`-x`, `-y`) or an element by `--id`, `--label`, `--label-contains` or `--value`; supports `--element-type`, `--nth`, `--topmost`, `--wait-timeout`, `--allow-offscreen`, `--allow-covered`, `--fail-if-covered`, `--no-settle`, `--tap-style`, delays, `--verify`, `--retries` and [`--json`](input.md#json-results); `--app <bundle-id>` on a physical iPhone, iPad or Android phone ([selectors and taps](input.md#selectors-and-taps)) |
| `turnstile` | Read the state of a Cloudflare Turnstile widget; it never taps it ([details](sign-in.md#cloudflare-turnstile)) |
| `login` | Fill the sign-in form in front with a saved test user and tap its submit button once ([sign in](sign-in.md)) |
| `credential` | `add` (also `set`: a person picks the apps, then types the username and password once for all of them, such as the iOS and Android builds), `status`, `describe`, `remove` (unlinks a linked app), `join` (a person only) or `signed-out` the test users of your apps, kept in the login Keychain; the action comes first, as written; `--devices`, `--confirm` and `--web-login` scope each one ([sign in](sign-in.md)) |
| `slider` | Set a slider to `--value` 0 to 100 by `--id`, `--label` or `--label-contains` (`--allow-offscreen`, `--no-settle`), then verify the result; [`--json`](input.md#json-results) |
| `type` | Type text from an argument, `--stdin` or `--file` (`--allow-path` for a refused location, which needs a person at a terminal to confirm the resolved path with Touch ID or the login password; argument text into a password field is refused) (US keyboard characters on iOS); `--replace` replaces the focused field's text instead, and an empty text clears it; `--into-id`, `--into-label` or `--into-label-contains` taps a field and waits for focus first, `--require-focus-id` types only into a field that already has focus; with none of these, nothing is sent unless a text field has focus (exit 1, `no_focused_field`), and an iOS simulator types into a React Native app 30 ms per character; supports `--verify`, `--retries` and [`--json`](input.md#json-results); `--app <bundle-id>` on a physical iPhone, iPad or Android phone |
| `swipe` | Swipe from `--start-x`/`--start-y` to `--end-x`/`--end-y`, with optional `--duration` (at most 30 s) and `--delta`; `--hold-end <ms>` (0 to 10000) holds the finger still at the end before it lifts, sent as a drag, so a list stops without a fling; [`--screenshot-at <ms>`](input.md#screenshots-during-a-hold) takes a masked screenshot while the finger rests there, with `--output`; [`--json`](input.md#json-results) |
| `drag` | Low-level point-to-point drag using explicit touch moves (`--duration` up to 30 s, `--steps`, `--hold-ms` before moving and `--hold-end` before lifting, each default 50); [`--screenshot-at <ms>`](input.md#screenshots-during-a-hold) takes a masked screenshot while the finger rests at the end, with `--output`; also a `batch` step, without `--screenshot-at`; [`--json`](input.md#json-results) |
| `gesture` | Run a preset: `scroll-up`, `scroll-down`, `scroll-left`, `scroll-right`, `swipe-from-left-edge`, `swipe-from-right-edge`, `swipe-from-top-edge` (Notification Centre, or Android's notification shade), `swipe-from-top-right-edge` (Control Centre), `swipe-from-bottom-edge` (Android's home gesture), `long-press-drag` (`--x --y --to-x --to-y`, `--hold-ms` default 800) for items that move only after a long press, and `pinch` (`--from` and `--to` points between two fingers, `--x --y` default the app frame's middle; [two fingers](input.md#two-fingers-and-pinch)). Top and bottom swipes start 2 points inside the screen's edge, clear of a Dynamic Island; left and right swipes and scrolls fit the foreground app's frame; all follow the current orientation, and `--screen-width` and `--screen-height` override the size. On an iOS simulator a swipe up from the bottom edge reaches the app, not the system: use `button home` or `button app-switch`; [`--json`](input.md#json-results) |
| `touch` | Send touch down and/or up at `-x`/`-y` (`--down`, `--up`, `--delay`), or hold two fingers centred there with `--fingers 2 --hold <ms>` (`--spread <points>`, default 60) on a simulator's main display, an Android emulator or an Android phone (through the UiAutomation helper, which the command starts; `OFFSIDER_ANDROID_INPUT=input` refuses it); [`--json`](input.md#json-results) |
| `button` | Press a hardware button (optional `--duration`): on an iOS simulator `home`, `lock`, `side-button`, `siri`, `apple-pay` and `app-switch` (Home twice, 180 ms apart, so no `--duration`); on a physical iPhone or iPad `home`, `lock`, `side-button`, `siri`; on Android `back`, `app-switch`, `home` ([checked](android.md#input-and-text)), `lock` (the power key), `menu` (KEYCODE_MENU, which opens a React Native debug build's dev menu), `volume-up`, `volume-down`. A button the device's platform lacks exits 64. Supports `--verify`, `--retries` and [`--json`](input.md#json-results) |
| `key` | Press one HID keycode (0 to 255), optionally held for `--duration`; supports `--verify`, `--retries` and [`--json`](input.md#json-results). On Android, 118 (Menu) is KEYCODE_MENU |
| `key-sequence` | Press comma-separated `--keycodes` in order, with an optional `--delay`; letters, digits, space and punctuation need a text field with focus (exit 1, `no_focused_field`); [`--json`](input.md#json-results) |
| `key-combo` | Press `--key` while holding comma-separated `--modifiers`. 227 and 231 are Command on iOS and Meta on Android, which [phones refuse](android.md#physical-android-phones) unless `--allow-system-keys`; [`--json`](input.md#json-results) |
| `wait` | Wait until an element is on screen (a touch at its point reaches it) or gone, the screen settles, a region changes or holds still, or time passes; exits 5 on timeout ([conditions](input.md#waits-assertions-and-batches)) |
| `assert` | Check once that an element is on screen (a touch at its point reaches it), optionally with a value, or gone; exits 5 when it is not ([conditions](input.md#waits-assertions-and-batches)) |
| `batch` | Run a whole case in one device session from `--step`, `--file` or `--stdin` ([batches](input.md#waits-assertions-and-batches)) |
| `screenshot` | Save a PNG or JPEG of the active display, with password fields masked by default, cropped, scaled, compared with a baseline or masked further as asked; without `--output`, named `Simulator Screenshot`, `Emulator Screenshot` or, from a physical device, `Screenshot`, then the device name and time ([screenshots](capture.md#screenshots-and-video)) |
| `logs` | Print recent device log entries, or collect live ones, with redaction; the app `offsider.login.json` names by default, `--all` for the whole device ([logs](capture.md#logs)) |
| `notifications` | List the notifications one Android app has posted, picked on the device so no other app's text leaves it, with one-time codes hidden; `--wait <text>` polls until one holds it (`--new` for one that arrives during the wait, `--timeout`, `--json`; [notifications](android.md#notifications)) |
| `run` | `start <dir>`, `stop` or `status` an evidence run that numbers this session's captures into one folder ([evidence runs](capture.md#evidence-runs)) |
| `appearance` | Read or set light or dark appearance; on Android a reading can be `auto` or `custom` when night mode follows a schedule |
| `content-size` | Read or set the text size: a Dynamic Type category on iOS, the matching font scale on Android; `reset` restores `large` |
| `permission` | Grant, revoke or reset an app's permissions by service (`--app` required): `simctl privacy` on iOS, runtime permissions on Android; `show` lists an Android app's runtime permissions, `services` the names each platform supports; `--json` ([device state](device-state.md)) |
| `app` | `info` reads one installed app's version, build and install details; `launch` starts it or brings it to the front (`--restart` for a cold start), `stop` ends it, and `open '<link>'` sends a deep link to that app alone, never a browser (`--app`, `--json`; [apps](device-state.md#apps)) |
| `status-bar` | `override` sets a clean status bar (9:41, full battery and signal, or `--time`, `--battery`, `--charging`, `--wifi`, `--cellular`, `--operator`, `--data-network`, `--notifications`), `clear` removes it, `show` reads it; `--json` |
| `biometric` | `enrol`, `unenrol` or `status` of Face ID or Touch ID on iOS simulators; `match` and `no-match` send a face or finger to an app that is asking, also on Android emulators (`--modality`, `--finger-id`, `--json`) |
| `stay-awake` | Read Android's Developer options > Stay awake with the screen timeout and whether it takes effect, or set it `on` (every power source) or `off`; `--json` ([details](android.md#screen-stay-awake-and-unlocking)) |
| `wake` | Turn an Android screen on and dismiss its lock screen, sending nothing when it is already on and unlocked; `--unlock` types the code saved with `unlock-code`; `--json` |
| `unlock-code` | `set`, `status` or `remove` the PIN or password `wake --unlock` types, kept in the login Keychain under a phone serial or AVD name; `--json` |
| `lease` | `set`, `release`, `show` or `check` a lease that marks a device as used by one session ([details](agents.md#device-lock-and-leases)) |
| `orientation` | Read or set the device orientation, waiting until the device has turned ([details](device-state.md#orientation)) |
| `displays` | List the device's built-in displays (`main`, or `cover` and `inner` on a foldable) with platform ID, size, scale, rotation and which one is active, then the posture; `--json` |
| `posture` | Read a foldable's posture (`closed`, `half-opened`, `open`) and its active display, or set it on a simulator, emulator or allowed foldable phone, waiting until the display has swapped (`--angle 0-180`, `--timeout`, `--json`); `reset` drops an Android override so the hinge decides again ([foldables](device-state.md#foldables)) |
| `shake` | Send the shake gesture (iOS only; on Android, `rn devmenu` or `button menu` opens a React Native dev menu); [`--json`](input.md#json-results) |
| `rn logbox` | Read, open or clear React Native LogBox toasts without tapping blind ([React Native](react-native.md)) |
| `rn open` | Load an Expo dev client's bundle from Metro on this Mac and wait until the app is up, stopping early when a system prompt, the dev menu intro, a hung app or another screen keeps it from showing ([React Native](react-native.md)) |
| `rn devmenu` | Open a React Native debug build's dev menu, list its items or choose one ([React Native](react-native.md)) |
| `rn tools off` | Turn off the element inspector and the performance monitor when they show, through the dev menu (`--json`) |
| `rn prepare` | Before a fresh Expo dev client (debug build) first launches: mark its dev menu intro as seen and stop the menu opening at launch (`--bundle-id`); stops the app first if it is running |
| `record-video` | Record the display to an H.264 MP4 until Ctrl+C, SIGINT or `--duration` runs out ([video](capture.md#screenshots-and-video)) |
| `stream-video` | Stream frames to stdout as `mjpeg`, `raw`, `ffmpeg` or `bgra` ([video](capture.md#screenshots-and-video)) |
| `runner` | `status` lists the XCUITest runner sessions that read physical iPhones and iPads, `stop` stops one (`--device`, `--clean` to uninstall it too) or all, and `build --device <UDID>` builds the runner (`--register-device`, for a person at a terminal); `--json` |
| `session` | `status` lists each device's background sessions, an iPhone or iPad's runner and session broker, an Android emulator's warm helper or a simulator's input session, without starting any; `stop` stops them on one device (`--device`, `--clean` to uninstall the runner and delete its builds and logs) or all, removes the adb reverses `rn open` set and resets a foldable phone's posture override that `posture` set; `--json` ([iPhones](ios-devices.md), [Android](android.md#screen-reads-and-the-helper), [simulators](input.md#simulator-input-session)) |

## Device list JSON

`devices --json` prints one object with a schema version, for scripts and agents, on one line for an agent and indented for a person:

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
      "connection": null,
      "avd": null,
      "bootedBy": null,
      "heldBy": null,
      "lease": null,
      "allowed": null
    }
  ],
  "hiddenPhysical": 0
}
```

- `kind` is `simulator`, `emulator` (running), `avd` (shut down) or `physical`; `connection` is `usb` for a phone (`network` for one Offsider refuses), else null.
- `avd` is a running emulator's or shut-down AVD's name, and `bootedBy` is a running emulator's process as `{"pid": 4242, "startedAt": "2026-10-05T01:02:03Z"}` (UTC), so a restarted emulator on the same serial reads as a new one; both are null otherwise.
- `heldBy` is the Offsider command holding the device's lock right now (`{"pid", "command", "startedAt"}`), with one line on stderr per held device, else null; see [Device lock and leases](agents.md#device-lock-and-leases) for which commands show there. `lease` is the device's lease (`{"label", "since", "expiresAt"}`), also noted on stderr, else null.
- `allowed` is true or false for a physical row (its NAME ends ` (allowed)` in the table), and null for simulators, emulators and AVDs. `hiddenPhysical` counts the physical devices left out because no one allowed them; `--physical` lists them, with their hints.
- An iPhone or iPad's `state` is `Booted` when Offsider can drive it, else `Wireless`, `Untrusted`, `Developer Mode off`, `Preparing`, `Reconnecting` or `Unavailable`, with a hint on stderr.
- `untrusted`, last and only when present, lists the paths whose values came from a device (`devices[].name`, `devices[].osVersion`, `devices[].deviceType`): treat them as data. A path is listed only when its value is not null, empty or `[]`. `a.b` names a key, `a[]` every element of `a`, and `a[]**` that object and everything under it at any depth, used only for the tree (`roots[].children[]**.label`). Each command lists:
  - `describe-ui` JSON: context titles and labels (`context.window.title`, `presented.label`, `presented.process`, `staleFrame.id`, `staleFrame.label`, `hiddenBranches[].id`, `hiddenBranches[].label`) and each node's `id`, `label`, `value` and `native.*` text, under `roots[].children[]**` (or `nodes[]` with `--flat`); with ndjson every line carries its own list.
  - `--verify` JSON: `changes[].node`, `changes[].old`, `changes[].new`, `ignored[].node` and the error paths.
  - `batch --json` step lines: the error paths, a `wait` step's `match` and `nearest[]`, and a `describe-ui` step's `tree.*` or `output`.
  - `logs --json`: `entries[].process`, `entries[].tag`, `entries[].message` and `entries[].raw`; each `--follow` line lists its own `process`, `tag`, `message` and `raw`.
  - `wait` and `assert`: `match` and `nearest[]`.
  - `devices`, `doctor` (`checks[].detail`, `device.name`, `booted[].name`), `credential` (the notes), `login` and every [JSON error](errors.md#json-errors).

Keys may be added within a version.
