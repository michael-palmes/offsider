---
name: offsider
description: Provides agent-ready Offsider CLI usage guidance for iOS Simulator and Android Emulator automation. Use when asked to "use Offsider", "automate a simulator", "automate an Android emulator", "boot an emulator", "tap/swipe/type on simulator or emulator", "replace or clear a text field", "press back", "set a slider", "describe UI", "take a screenshot", "record video", "batch steps", or "interact with an iOS, Android or React Native app". Covers all commands including boot, touch, gestures, sliders, text input, keyboard, buttons, accessibility, screenshots, video, and batch workflows.
---

## Step 1: Confirm runtime context
1. Identify the target device ID first with `offsider list-devices` (iOS simulators, running Android emulators by serial and shut-down AVDs by name; watchOS, tvOS and visionOS are not listed), or `offsider list-devices --json` for `{"version": 1, "devices": [{id, platform, state, name, osVersion, deviceType}]}`. `--platform ios|android` filters. Simulator IDs are case-insensitive; Android IDs are serials (`emulator-5554`) or the name of a running AVD.
   - To start an Android emulator, run `DEVICE=$(offsider boot <AVD>)`: it waits until Android has booted and prints the serial (add `--headless` to hide the window). It never starts a second instance of a running AVD, so it is safe to call first. Never start emulators with `emulator -port` or `-grpc` yourself: Offsider then falls back to slower adb-only input.
2. For iOS simulators, run `offsider doctor --device <DEVICE_ID> --json` at the start of a session and whenever input seems ignored. Exit 0 means every check passed, 3 means warnings and 4 means failures; read each check's `status` and follow its `hint`. `offsider doctor --device <DEVICE_ID> --fix` opens Device Hub or the device window and removes a stale HID broker directory, then checks again. `doctor --device` does not check Android emulators yet (exit 64); use `list-devices` and `describe-ui` instead.
3. Device-interaction Offsider commands require `--device <DEVICE_ID>`. Commands like `list-devices`, `boot`, `init` and `doctor` do not. `--udid` and `list-simulators` were renamed to `--device` and `list-devices` in 0.3.0 and now exit 64 with a hint.
4. Run `offsider describe-ui --device <DEVICE_ID>` to inspect the full current screen. Use `offsider describe-ui --point <X,Y> --device <DEVICE_ID>` to inspect the element at a specific coordinate. Use the output to discover available `--id` and `--label` values for selector taps and slider setting, and to confirm coordinates for coordinate-based taps.
   - The output is `{"version": 1, "platform", "device", "screen", "roots": [...]}`. Each node has `role`, `id`, `label`, `value`, `frame`, `enabled`, `state` (`checked`, `selected`, `focused`), `native` and `children`; every key is present, with `null` when unknown. `--point` returns the same envelope with the hit element as the only root.
   - `--id`, `--label` and `--value` match a node's `id`, `label` and `value`. In React Native apps, `testID` appears as `id`.
   - `role` is one of `application`, `window`, `group`, `other`, `button`, `link`, `menuItem`, `tab`, `tabBar`, `segmentedControl`, `text`, `header`, `image`, `progress`, `textField`, `secureTextField`, `searchField`, `textArea`, `switch`, `checkbox`, `radioButton`, `slider`, `picker`, `cell`, `list`, `scrollView` or `keyboard`. `native` keeps the platform attributes, such as the iOS `type` (`TextField`, `RadioButton`), `role` (`AXButton`) and `roleDescription`.
   - `--element-type` narrows selector matches by `role` in any case (`button`, `switch`, `slider`) or by the exact native type (`RadioButton`, `TextEditor`).
5. Prefer selectors (`tap --id` / `tap --label`, `slider --id` / `slider --label`) over raw coordinates. Selectors are resilient to layout changes, work across device sizes, and support element waiting where documented. For UIKit `UISwitch` and SwiftUI `Toggle` rows, selector taps activate the contained switch/toggle when the match contains exactly one such control. Default tap style is `automatic`: switches and toggles use physical touch down and up, while other taps send a single tap event.

## Step 2: Choose the right command

Available commands: `doctor`, `init`, `boot`, `tap`, `slider`, `swipe`, `drag`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`, `batch`, `describe-ui`, `screenshot`, `record-video`, `stream-video`, `list-devices`. Run `offsider --help` or `offsider <command> --help` for full options.

Common examples:
```bash
offsider doctor --device <DEVICE_ID> --json
offsider tap --id <identifier> --device <DEVICE_ID>
offsider tap --label <text> --device <DEVICE_ID>
offsider tap --label 'Weather Alerts' --device <DEVICE_ID>
offsider slider --id <identifier> --value 75 --device <DEVICE_ID>
offsider slider --label <text> --value 40 --element-type slider --device <DEVICE_ID>
offsider drag --start-x <X1> --start-y <Y1> --end-x <X2> --end-y <Y2> --device <DEVICE_ID>
offsider gesture scroll-up --device <DEVICE_ID>
offsider tap -x <X> -y <Y> --tap-style physical --device <DEVICE_ID>
offsider tap -x <X> -y <Y> --device <DEVICE_ID>
offsider tap --id <identifier> --verify --json --device <DEVICE_ID>
offsider type 'text' --device <DEVICE_ID>
offsider type --replace 'new text' --device <DEVICE_ID>
offsider describe-ui --device <DEVICE_ID>
offsider describe-ui --point <X,Y> --device <DEVICE_ID>
offsider screenshot --device <DEVICE_ID> --output screenshot.png
offsider boot <AVD> --headless
offsider button back --device <DEVICE_ID>
```

`button` names depend on the platform: iOS has `apple-pay`, `home`, `lock`, `side-button` and `siri`; Android has `back`, `app-switch`, `home`, `lock` (the power key), `volume-up` and `volume-down`. A button the device lacks exits 64.

## Step 3: Understand the execution model

Most HID commands (`tap`, `swipe`, `drag`, `type`, `key`, etc.) are fire-and-forget: Offsider confirms the event was dispatched to the simulator but cannot verify the app actually processed it. A tap may land before a view is interactive, or during a transition. `slider` is the exception: it sets the matched slider (one selector-resolved low-level HID drag on iOS, the accessibility progress action on Android), re-reads its `value`, and fails if the observed 0-100 value is outside tolerance. iOS slider controls quantize values to their rendered track resolution, so Offsider does not retry correction gestures to chase unreachable decimals. This means:
- Add `--verify` to `tap`, `type`, `key` or `button` to wait for an observable change after the input. Offsider compares the accessibility tree (ignoring elements that were already changing), then falls back to screenshots; it exits 0 when something changed and 5 when nothing did. "Verified" means something changed, not that the right thing changed: check the new state when it matters.
- `--verify-timeout <seconds>` (0.5 to 30, default 2) is the wait per attempt. `--retries <n>` (0 to 3, default 1) repeats the input when nothing changed; tap retries switch between simulator and physical tap style. Use `--retries 0` for non-idempotent actions such as submit, send or delete, because a late effect plus a retry can act twice.
- `--json` (requires `--verify`) prints one object to stdout with `verified`, `dispatched`, `attempts`, `change` (`accessibility-tree`, `screenshot` or `none`) and `style` (tap only); human text goes to stderr. A `screenshot` change can be animation or the status bar clock in landscape, so confirm with `describe-ui`. `button lock` only shows as a black screen.
- Without `--verify`, verify outcomes separately with `describe-ui` or `screenshot` when app behavior matters beyond the direct command result.
- Use `--wait-timeout` in batch to wait for tap elements to appear, and `sleep` steps or `--pre-delay` / `--post-delay` to allow animations to settle.

## Step 4: Apply timing and input best practices
- Use `--pre-delay` / `--post-delay` on tap, swipe, and gesture commands for fixed delays around actions.
- Use `--duration` to control how long a swipe, gesture, button press, or key press lasts.
- Coordinate-based `tap`, `swipe`, `drag`, and `touch` accept coordinates from `describe-ui` directly; Offsider detects rotated landscape simulator orientation and letterboxed landscape-only app layouts automatically.
- `gesture` presets are sized to the foreground app's frame and go through the same orientation handling, so they fit any device and landscape. `--screen-width` and `--screen-height` override that size, in points as the screen is currently oriented.
- Use `offsider slider --id <identifier> --value <0-100>` for sliders instead of approximating with raw swipe coordinates. On iOS it uses one calibrated low-level HID drag from the resolved slider frame and current `value`, through the same composite touch-move path as `drag`; on Android it uses the accessibility progress action (Step 4a). Either way it verifies the result within tolerance and fails clearly if the observed `value` remains outside tolerance.
- `type` adds to whatever the focused field holds. To set a field to exact text, tap the field, then run `offsider type --replace 'new text' --device <DEVICE_ID>`; `--replace ''` clears it. It works with `--stdin`, `--file`, `--verify` and as a batch step. iOS selects all with Command-A and deletes, then types (secure fields included); Android sets the text in one step (Step 4a). A trailing newline is pressed as Return on both platforms, so `$'query\n'` submits.
- For text with shell-sensitive characters, prefer `--stdin` or `--file` over inline quotes.
- Use single quotes for inline text arguments to avoid shell expansion issues.

## Step 4a: Android emulators and React Native
- Coordinates, frames and `--delta` are in dp on Android (points on iOS); take them from `describe-ui` as usual.
- Screen reads (`describe-ui`, selectors, `--wait-timeout`, `--verify`, `slider`, `type --replace`) go through a small UiAutomation helper that Offsider starts on the emulator for one command: about 0.3 s per `describe-ui` and 1 to 1.5 s per verified tap on a quiet Mac, slower when the Mac is busy. Poll and verify as on iOS. While a command reads the screen, the emulator reports an accessibility service as enabled, which some apps react to.
- A "found no window" error while an activity starts is retried by `--wait-timeout` and `tap --verify`.
- "Another UiAutomation client is connected" means Appium, Maestro, `uiautomator`, an instrumentation test or Layout Inspector holds Android's single UiAutomation connection. Offsider never reads around it: ask the user to stop that client, then retry.
- "An earlier Offsider helper (pid N) still holds UiAutomation" usually means another Offsider command is still running on the same emulator. Run commands on one emulator one at a time; the helper exits within 10 s, or run the `adb -s <serial> shell kill <pid>` command the message gives.
- A `Warning:` that the UiAutomation helper is unavailable means Offsider fell back to `uiautomator`: reads take about 2 s, the tree has no keyboard root and no slider values, and `slider` fails. Pass the reason in the warning on to the user.
- Roots: the app window is `application`, labelled with its window title (such as `Settings`); while the keyboard is up, a second root with role `keyboard` follows it. Status and navigation bars are not in the tree.
- Sliders and progress bars report `value` as a percentage of their range (`"25%"`, `"39.95%"`), and a partly checked checkbox reports `"2"`. A Jetpack Compose `testTag` is the `id` when the node has no resource id.
- `slider` sets the value through the accessibility progress action, falling back to a drag. A control with coarse steps stops at the nearest step and says so, for example `Slider set to 78 (the nearest step to 78.25)`. Apps that act only when a drag ends (React Native `onSlidingComplete`) may miss the change: then `drag` on the track and read the app's own readout with `describe-ui`.
- `type` sends ASCII as key events; text with any other character is pasted through the emulator's clipboard, which Offsider restores afterwards. On an emulator without gRPC, `type` accepts ASCII only.
- `type --replace` sets the focused field's text in one accessibility action: any Unicode works, even without gRPC, but key handlers such as `onKeyPress` do not run. A single trailing newline is pressed as Return afterwards; other newlines become line breaks. "type --replace needs a focused text field" means nothing has input focus: tap the field first. A `Warning:` that Offsider clears the field with Ctrl+A and Delete means it could not set the text in one step; it then clears the field with keys and types the text as `type` would.
- `stream-video --format bgra` sends a frame only when the screen changes.
- React Native on Android: `testID` is `id` and `accessibilityLabel` is `label` (from `content-desc`), as on iOS. A `View` with neither `accessible` nor `testID` can be flattened away, so ask for a `testID` when a target is missing. A `Pressable` without a label takes its children's text as its label.
- Android alerts show upper-case button text (`DELETE`, `CANCEL`) with ids `android:id/button1` and `android:id/button2`; `--id button1` matches through the `:id/` suffix. A `Modal` is its own window, so only the modal is in the tree while it is open.
- Radio segments are `radioButton` on Android but `other` on iOS, so select them by `--id` or `--label` rather than `--element-type`.
- `offsider button back` pops React Navigation and custom stacks, like the hardware back button.

## Step 5: Batch vs discrete commands

**Prefer `offsider batch`** for multi-step flows. Batch executes every step in a single process invocation, which means:
- One tool call and one AI turn instead of many, which significantly reduces agent latency and cost.
- A single HID session is reused across all steps, lowering per-step overhead.
- Steps execute sequentially: each step runs before the next is resolved, so earlier taps can trigger navigation and later selector taps will find newly appeared elements (with `--wait-timeout`).

**Fall back to discrete commands** when:
- A step's parameters depend on runtime inspection of a previous step's result (e.g. parsing `describe-ui` JSON to choose coordinates dynamically).
- Using `slider`; batch steps do not support slider verification.
- You need `--verify`; batch steps reject `--verify`, `--verify-timeout`, `--retries` and `--json`. Run that input on its own with `--verify`, or check with `describe-ui` after the batch.

**Handling animations and transitions in batch:**
- Use `--wait-timeout <seconds>` so selector taps (`--id` / `--label`) poll the accessibility tree until the element appears or the timeout expires. This is the primary mechanism for multi-screen flows.
- Use `--poll-interval <seconds>` to control polling frequency during waiting (default 0.25s).
- Use `--ax-cache perStep` when *not* using `--wait-timeout` but the UI still changes between steps; this ensures each selector tap gets a fresh accessibility snapshot rather than a stale cached one.
- Insert explicit `sleep <seconds>` steps when coordinate-based taps need the UI to be stable (selectors with `--wait-timeout` are preferred over sleep where possible).
- Keep batch output quiet by default. Add `--verbose` only when troubleshooting.
- Selector taps in batch share direct `tap` semantics, including switch/toggle activation-point handling and `--tap-style automatic` behavior. Use batch-level `--tap-style physical|simulator` as the default for tap steps, or step-level `tap --tap-style ...` to override one step.
- If `tap --label` reports multiple matches and none of them has an `id`, narrow with `--element-type` or fall back to `tap -x/-y` for that step.

Key rules:
- Use exactly one step source per run: `--step`, `--file`, or `--stdin`.
- Steps run in order; default is fail-fast.
- Add `--continue-on-error` for best-effort execution.
- Do not pass `--device` inside step lines; keep it at batch level.

## Step 6: Verify outcomes
Batch and commands without `--verify` are execution-focused, not assertion-focused. Always suggest verification when outcomes matter.

Exit 5 from a `--verify` command means the input was dispatched but nothing observable changed. Run `describe-ui` to check the target is on screen and interactive, then, on an iOS simulator, `offsider doctor --device <DEVICE_ID>` if input seems ignored. Read the `change` field of the JSON result to see how the change was detected.

```bash
offsider describe-ui --device <DEVICE_ID>
offsider describe-ui --point <X,Y> --device <DEVICE_ID>
# or
offsider screenshot --device <DEVICE_ID> --output post-state.png
```

## Step 7: Exit criteria
Before finalising guidance, verify:
- Every device-interaction command includes `--device`.
- Only valid Offsider commands and flags are used.
- Shell quoting is correct (single quotes for literals, `--stdin`/`--file` for complex text).
- Verification is suggested as a separate step when results matter.
