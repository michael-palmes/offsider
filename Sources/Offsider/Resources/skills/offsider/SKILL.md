---
name: offsider
description: Provides agent-ready Offsider CLI usage guidance for iOS Simulator and Android Emulator automation. Use when asked to "use Offsider", "automate a simulator", "automate an Android emulator", "boot an emulator", "tap/swipe/type on simulator or emulator", "replace or clear a text field", "press back", "set a slider", "describe UI", "take a screenshot", "record video", "batch steps", "wait for an element", "assert", "read app logs", "dark mode", "grant a permission", "clean status bar", "Face ID or fingerprint", "keep a screen awake or unlock it", "rotate", "fold or unfold a foldable", "text size", "tick a Cloudflare Turnstile checkbox", "number and mask screenshots for a report", "redact logs", "React Native dev menu or LogBox", or "interact with an iOS, Android or React Native app (Expo dev client, LogBox, debug or release build)".
---
# Offsider

Offsider drives iOS Simulators, Android Emulators and USB phones and iPads from the terminal: it reads the screen as an accessibility tree, then taps, types, swipes and captures, all on this Mac. This file is the core. `offsider guide <topic>` prints version-matched depth for each topic in the table at the end; read a topic before guessing.

## Every session

1. Find the device with `offsider list-devices`: iOS simulators, USB iPhones and iPads by UDID, running Android emulators and USB phones by serial, and shut-down AVDs by name (watchOS, tvOS and visionOS are not listed). `--json` adds each device's `kind` and `connection` (`guide android`); `--platform ios|android` filters. Simulator IDs are case-insensitive UDIDs; Android IDs are serials (`emulator-5554`) or a running AVD's name. Never choose a `physical` device yourself: drive a phone only when the user names its serial or UDID (`guide android`, `guide ios-device`).
2. Start an Android emulator with `DEVICE=$(offsider boot <AVD>)` (`--headless` hides the window): it waits until Android has booted, prints the serial and never starts a second instance of a running AVD. Never start emulators with `emulator -port` or `-grpc` yourself: Offsider then falls back to slower adb-only input.
3. Run `offsider doctor --device <DEVICE_ID> --json` at the start of a session and whenever input seems ignored or screen reads fail. Exit 0 means every check passed, 3 means warnings and 4 means failures; read each check's `status` and follow its `hint` (`guide errors`).
4. Pass `--device <DEVICE_ID>` to every device command, or `export OFFSIDER_DEVICE=<DEVICE_ID>` once (`--device` wins). `list-devices`, `boot`, `init`, `guide` and `doctor` do not need it.
5. If the repository has an `OFFSIDER.md`, read `offsider guide --project .` first.

## The loop: look, act, verify

1. **Look.** `offsider describe-ui --summary --device <DEVICE_ID>` prints one line per on-screen node with a label, id or value, such as `button "Save" id=save-button (170.7,313.3 61x34.3)` (role, label, id, value, then x,y and size). Copy `--id` and `--label` values from it (`guide describe-ui`).
2. **Act with a selector.** `tap --id`, `tap --label`, `slider --id <id> --value <0-100>`. Selectors survive layout changes, prefer on-screen matches and wait with `--wait-timeout`; fall back to `tap -x <X> -y <Y>` with points from `describe-ui` (`guide selectors`). On a Cloudflare Turnstile checkbox run `offsider turnstile` yourself (`--status` reads it); hand back only after exit 1 or 5. It does not bypass Turnstile (`guide turnstile`).
3. **Verify.** Most input is fire-and-forget. Add `--verify` to `tap`, `type`, `key` or `button` (exit 5 when nothing changed; `--verify-id <id>` for navigation), or check with `wait` (`--any` for either outcome), `assert` or `describe-ui --diff`, which prints only what changed since the previous command's tree (`guide verify`).
4. **Batch.** For three or more steps, run one `offsider batch` call (`guide batch`).

```bash
offsider tap --id <identifier> --verify --json --device <DEVICE_ID>
offsider type --replace 'new text' --device <DEVICE_ID>
offsider wait --id <identifier> --device <DEVICE_ID>
offsider assert --id <identifier> --has-value <text> --device <DEVICE_ID>
offsider describe-ui --diff --device <DEVICE_ID>
```

## Rules

- Wait on a condition, never a guess: `wait --id`, `--gone` (`--stable-for`), `--has-value`, `--settled`. Never tap an element just to pass time.
- `type` adds to the focused field. Tap the field (or pass `--into-id <id>`), then `type --replace 'text'` sets it exactly (`''` clears it); a trailing newline presses Return; single quotes inline, `--stdin` or `--file` for shell-sensitive text (`guide selectors`).
- Secure fields read as bullets, one per character: find them by `--id` or `--label` (`--value` never matches them). To type a secret, tap the field and run `type`: Offsider never logs or echoes the text. Add `--mask-secure` to `screenshot` before sharing an image of a screen with a password field (`guide evidence`).
- For a report, `offsider run start <dir>` numbers screenshots and logs into one folder; mask personal data with `--mask-emails` (`guide evidence`).
- Use `--retries 0` with `--verify` for submit, send or delete, so a late effect plus a retry cannot act twice.
- One agent per device: input commands lock the device. Exit 8 (`device_busy`) names the holder's pid; wait, or rerun with `--wait-lock <seconds>`. Never resend in a loop, never kill the holder (`guide errors`).
- Screenshots are in pixels; taps and frames are in points (dp on Android). Capture with `screenshot --scale points` when you will tap what you see.
- `appearance`, `content-size`, `orientation`, `permission`, `status-bar`, `biometric` and `stay-awake` change the device and stay changed: read the current value first, and set it back when done (`guide device-state`).
- A physical iPhone or iPad works over USB only, unlocked, with Settings > Developer > UI Automation on (ask the user; `ui_automation_off` or `device_locked` means it is not). Input needs Xcode 27 on the Mac and starts a background session: run `offsider session stop --device <UDID>` when done. `describe-ui`, `tap`, `wait` and `assert` take `--app <bundle-id>` to read that app (`guide ios-device`).
- React Native debug builds: `rn open` (Metro), `rn logbox dismiss`, `rn devmenu` (`guide react-native`).
- When an Android error says the screen is off or locked, run `offsider wake --device <DEVICE_ID>`. Exit 7 `device_locked` means a PIN, pattern or password lock screen: ask the user to unlock it, or run `wake --unlock` if they saved a code. Never ask for or handle a lock screen code; the user saves it with `unlock-code set` in their own terminal.

## Exit codes

Exit codes: 0 ok, 1 failure, 2 selector not found, 3 doctor warnings, 4 doctor failures, 5 unverified or condition unmet, 6 ambiguous selector, 7 device not found, not booted or locked, 8 device busy, 9 Xcode, adb or SDK missing, 64 usage.

With `--json`, a failure prints `exitCode` and an `error` object. `dispatched: no` means nothing was sent, so a resend is safe; after exit 5 or `dispatched: unknown`, check the screen before sending again (`guide errors`, which covers resending a batch).

## Commands

`doctor`, `init`, `guide`, `boot`, `list-devices`, `describe-ui`, `tap`, `turnstile`, `slider`, `swipe`, `drag`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`, `wait`, `assert`, `batch`, `run`, `screenshot`, `logs`, `appearance`, `content-size`, `permission`, `status-bar`, `biometric`, `stay-awake`, `wake`, `unlock-code`, `lease`, `orientation`, `displays`, `posture`, `shake`, `rn` (`prepare`, `open`, `logbox`, `devmenu`, `tools off`), `record-video`, `stream-video`, `runner`, `session`. Run `offsider <command> --help` for every option; `guide selectors` lists `button` names.

## Topics

Run `offsider guide <topic>` to print one; `offsider guide` lists them.

| Topic | Read it when |
| --- | --- |
| `selectors` | A selector misses, matches twice, or the target is off screen, covered or moving; you need coordinates, gestures, sliders, text replacement or button names |
| `verify` | You need proof an input worked, `--verify` exited 5, or you are waiting on a condition |
| `errors` | A command exited non-zero, the device is busy, or doctor reports a problem |
| `android` | The device is an Android emulator or a USB phone |
| `ios-device` | The device is a physical iPhone or iPad, named by its UDID |
| `react-native` | The app is React Native or Expo, debug or release |
| `turnstile` | You need to tick a Cloudflare Turnstile checkbox, or to know the tap does not bypass the check |
| `foldables` | The device folds or has more than one display |
| `batch` | A flow has three or more steps |
| `screenshots` | You need pixels: charts, maps, web views, masked secure fields or video |
| `evidence` | You need numbered screenshots and logs for a report, masked or redacted, a pixel diff, or log entries as JSON |
| `describe-ui` | You need more than `--summary`: JSON, filters, the byte budget or `--diff` |
| `device-state` | You change appearance, text size, orientation, permissions, the status bar or biometrics, or keep an Android screen awake and unlocked |
| `migrate` | You know idb, Maestro or agent-device and want the Offsider equivalent |

## Before finishing

- Every device command has `--device`; every command and flag is real.
- Quoting is right: single quotes for literals, `--stdin` or `--file` for complex text.
- Outcomes that matter were checked with `assert`, `wait`, `--verify` or a region compare.
- Labels came from `describe-ui`, targets were on screen, and screenshot coordinates came from `--scale points`.
- Device state changed with a setter (`guide device-state`) was set back.
- Any run was stopped with `run stop`.
