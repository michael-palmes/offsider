---
name: offsider
description: Provides agent-ready Offsider CLI usage guidance for iOS Simulator and Android Emulator automation. Use when asked to "use Offsider", "automate a simulator", "automate an Android emulator", "boot an emulator", "tap/swipe/type on simulator or emulator", "replace or clear a text field", "press back", "set a slider", "describe UI", "take a screenshot", "record video", "batch steps", "wait for an element", "assert", "read app logs", "dark mode", "grant a permission", "clean status bar", "Face ID or fingerprint", "keep a screen awake or unlock it", "rotate", "fold or unfold a foldable", "text size", "tick a Cloudflare Turnstile checkbox", or "interact with an iOS, Android or React Native app (Expo dev client, LogBox, debug or release build)". Covers all commands including boot, touch, gestures, sliders, text input, keyboard, buttons, accessibility, waits and assertions, screenshots, logs, appearance, permissions, status bar, biometrics, stay awake and unlocking, orientation, foldables, video, and batch workflows.
---
# Offsider

Offsider drives iOS Simulators, Android Emulators and USB Android phones from the terminal: it reads the screen as an accessibility tree, then taps, types, swipes and captures, all on this Mac. This file is the core. `offsider guide <topic>` prints version-matched depth for each topic in the table at the end; read a topic before guessing.

## Every session

1. Find the device with `offsider list-devices`: iOS simulators, running Android emulators and USB phones by serial, and shut-down AVDs by name (watchOS, tvOS and visionOS are not listed). `--json` prints `{"version": 1, "devices": [{id, platform, state, name, osVersion, deviceType, kind, connection}]}` (`kind` is `simulator`, `emulator`, `avd` or `physical`); `--platform ios|android` filters. Simulator IDs are case-insensitive UDIDs; Android IDs are serials (`emulator-5554`) or a running AVD's name. Never choose a `physical` device yourself: drive a phone only when the user names its serial (`guide android`).
2. Start an Android emulator with `DEVICE=$(offsider boot <AVD>)` (`--headless` hides the window): it waits until Android has booted, prints the serial and never starts a second instance of a running AVD. Never start emulators with `emulator -port` or `-grpc` yourself: Offsider then falls back to slower adb-only input.
3. Run `offsider doctor --device <DEVICE_ID> --json` at the start of a session and whenever input seems ignored or screen reads fail. Exit 0 means every check passed, 3 means warnings and 4 means failures; read each check's `status` and follow its `hint` (`guide errors`).
4. Pass `--device <DEVICE_ID>` to every device command. `list-devices`, `boot`, `init`, `guide` and `doctor` do not need it.

## The loop: look, act, verify

1. **Look.** `offsider describe-ui --summary --device <DEVICE_ID>` prints one line per on-screen node with a label, id or value, such as `button "Save" id=save-button (170.7,313.3 61x34.3)` (role, label, id, value, then x,y and size). Copy `--id` and `--label` values from it (`guide describe-ui`).
2. **Act with a selector.** `tap --id`, `tap --label`, `slider --id <id> --value <0-100>`. Selectors survive layout changes, prefer on-screen matches and wait with `--wait-timeout`; fall back to `tap -x <X> -y <Y>` with points from `describe-ui` (`guide selectors`). A Cloudflare Turnstile checkbox's frame includes the words beside the square, so `tap` on that label misses the box: `offsider turnstile` taps the square and waits until the widget passes. On iOS that square is outside the tree, where the green check sits. The tap does not bypass Turnstile: the widget passes only when Cloudflare accepts the device (`guide turnstile`).
3. **Verify.** Most input is fire-and-forget. Add `--verify` to `tap`, `type`, `key` or `button` (exit 5 when nothing changed), or check with `wait`, `assert` or `describe-ui --diff`, which prints only what changed since the previous command's tree (`guide verify`).
4. **Batch.** For three or more steps, run one `offsider batch` call (`guide batch`).

```bash
offsider tap --id <identifier> --verify --json --device <DEVICE_ID>
offsider type --replace 'new text' --device <DEVICE_ID>
offsider wait --id <identifier> --device <DEVICE_ID>
offsider assert --id <identifier> --has-value <text> --device <DEVICE_ID>
offsider describe-ui --diff --device <DEVICE_ID>
```

## Rules

- Wait on a condition, never a guess: `wait --id`, `--gone`, `--has-value`, `--settled`. Never tap an element just to pass time.
- `type` adds to the focused field. Tap the field, then `type --replace 'text'` sets it exactly and `--replace ''` clears it; it works with `--stdin`, `--file`, `--verify` and as a batch step. iOS selects all with Command-A and deletes, then types (secure fields included); Android sets the text in one step. A trailing newline presses Return on both, so `$'query\n'` submits. Use single quotes inline, and `--stdin` or `--file` for shell-sensitive text.
- Secure fields read as bullets, one per character: find them by `--id` or `--label` (`--value` never matches them). To type a secret, tap the field and run `type`: Offsider never logs or echoes the text. Add `--mask-secure` to `screenshot` before sharing an image of a screen with a password field (`guide screenshots`).
- Use `--retries 0` with `--verify` for submit, send or delete, so a late effect plus a retry cannot act twice.
- One agent per device: input commands lock the device. Exit 8 (`device_busy`) names the holder's pid; wait, or rerun with `--wait-lock <seconds>`. Never resend in a loop, never kill the holder (`guide errors`).
- Screenshots are in pixels; taps and frames are in points (dp on Android). Capture with `screenshot --scale points` when you will tap what you see.
- `appearance`, `content-size`, `orientation`, `permission`, `status-bar`, `biometric` and `stay-awake` change the device and stay changed: read the current value first, and set it back when done (`guide device-state`).
- When an Android error says the screen is off or locked, run `offsider wake --device <DEVICE_ID>`. Exit 7 `device_locked` means a PIN, pattern or password lock screen: ask the user to unlock it, or run `wake --unlock` if they saved a code. Never ask for or handle a lock screen code; the user saves it with `unlock-code set` in their own terminal.

## Exit codes

Exit codes: 0 ok, 1 failure, 2 selector not found, 3 doctor warnings, 4 doctor failures, 5 unverified or condition unmet, 6 ambiguous selector, 7 device not found, not booted or locked, 8 device busy, 9 Xcode, adb or SDK missing, 64 usage.

With `--json`, a failure prints `exitCode` and an `error` object. `dispatched: no` means nothing was sent, so a resend is safe; after exit 5 or `dispatched: unknown`, check the screen before sending again (`guide errors`). After a batch fails, check its summary line's `dispatched` before resending: earlier steps may have run, so exit 2 or 6 alone does not make a batch resend safe.

## Commands

`doctor`, `init`, `guide`, `boot`, `list-devices`, `describe-ui`, `tap`, `turnstile`, `slider`, `swipe`, `drag`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`, `wait`, `assert`, `batch`, `screenshot`, `logs`, `appearance`, `content-size`, `permission`, `status-bar`, `biometric`, `stay-awake`, `wake`, `unlock-code`, `orientation`, `displays`, `posture`, `shake`, `rn prepare`, `record-video`, `stream-video`. Run `offsider <command> --help` for every option.

`button` names depend on the platform: iOS has `apple-pay`, `home`, `lock`, `side-button` and `siri`; Android has `back`, `app-switch`, `home`, `lock` (the power key), `volume-up` and `volume-down`. A button the device lacks exits 64.

## Topics

Run `offsider guide <topic>` to print one; `offsider guide` lists them.

| Topic | Read it when |
| --- | --- |
| `selectors` | A selector misses, matches twice, or the target is off screen, covered or moving; you need coordinates, gestures or sliders |
| `verify` | You need proof an input worked, `--verify` exited 5, or you are waiting on a condition |
| `errors` | A command exited non-zero, the device is busy, or doctor reports a problem |
| `android` | The device is an Android emulator or a USB phone |
| `react-native` | The app is React Native or Expo, debug or release |
| `turnstile` | You need to tick a Cloudflare Turnstile checkbox, or to know the tap does not bypass the check |
| `foldables` | The device folds or has more than one display |
| `batch` | A flow has three or more steps |
| `screenshots` | You need pixels: charts, maps, web views, masked secure fields or video |
| `describe-ui` | You need more than `--summary`: JSON, filters, the byte budget or `--diff` |
| `device-state` | You change appearance, text size, orientation, permissions, the status bar or biometrics, or keep an Android screen awake and unlocked |
| `migrate` | You know idb, Maestro or agent-device and want the Offsider equivalent |

## Before finishing

- Every device command includes `--device`, and only real Offsider commands and flags are used.
- Shell quoting is correct: single quotes for literals, `--stdin` or `--file` for complex text.
- Outcomes that matter were checked with `assert`, `wait`, `--verify` or a region compare.
- Labels were copied from `describe-ui`, selector targets were on screen when tapped, and coordinates read from a screenshot came from a `--scale points` capture.
- Device settings and state changed with `appearance`, `content-size`, `orientation`, `permission`, `status-bar` or `biometric` were set back.
