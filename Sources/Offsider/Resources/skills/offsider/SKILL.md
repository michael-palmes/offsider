---
name: offsider
description: Provides agent-ready Offsider CLI usage guidance for iOS Simulator and Android Emulator automation. Use when asked to "use Offsider", "automate a simulator", "automate an Android emulator", "boot an emulator", "tap/swipe/type on simulator or emulator", "replace or clear a text field", "press back", "set a slider", "describe UI", "take a screenshot", "record video", "batch steps", "wait for an element", "assert", "read app logs", "dark mode", "rotate", "text size", or "interact with an iOS, Android or React Native app (Expo dev client, LogBox, debug or release build)". Covers all commands including boot, touch, gestures, sliders, text input, keyboard, buttons, accessibility, waits and assertions, screenshots, logs, appearance, orientation, video, and batch workflows.
---

## Step 1: Confirm runtime context
1. Identify the target device ID first with `offsider list-devices` (iOS simulators, running Android emulators by serial and shut-down AVDs by name; watchOS, tvOS and visionOS are not listed), or `offsider list-devices --json` for `{"version": 1, "devices": [{id, platform, state, name, osVersion, deviceType}]}`. `--platform ios|android` filters. Simulator IDs are case-insensitive; Android IDs are serials (`emulator-5554`) or the name of a running AVD.
   - To start an Android emulator, run `DEVICE=$(offsider boot <AVD>)`: it waits until Android has booted and prints the serial (add `--headless` to hide the window). It never starts a second instance of a running AVD, so it is safe to call first. Never start emulators with `emulator -port` or `-grpc` yourself: Offsider then falls back to slower adb-only input.
2. For iOS simulators, run `offsider doctor --device <DEVICE_ID> --json` at the start of a session and whenever input seems ignored. Exit 0 means every check passed, 3 means warnings and 4 means failures; read each check's `status` and follow its `hint`. `offsider doctor --device <DEVICE_ID> --fix` opens Device Hub or the device window and removes a stale HID broker directory, then checks again. `doctor --device` does not check Android emulators yet (exit 64); use `list-devices` and `describe-ui` instead.
   - Offsider uses the Xcode that `DEVELOPER_DIR` or `xcode-select` selects, and doctor prints which. When the project builds with a different Xcode from the selected one, set the same `DEVELOPER_DIR` on every `offsider` call. If doctor reports Simulator.app running from another Xcode, follow its `DEVELOPER_DIR=...` hint before quitting anything.
3. Device-interaction Offsider commands require `--device <DEVICE_ID>`. Commands like `list-devices`, `boot`, `init` and `doctor` do not. `--udid` and `list-simulators` were renamed to `--device` and `list-devices` in 0.3.0 and now exit 64 with a hint.
4. Run `offsider describe-ui --summary --device <DEVICE_ID>` to scan the current screen: one line per on-screen node that has a label, id or value, such as `button "Save" id=save-button (170.7,313.3 61x34.3)` (role, label, id, value, then x,y and size). Use `offsider describe-ui --point <X,Y> --device <DEVICE_ID>` to inspect the element at a specific coordinate. Use the output to discover available `--id` and `--label` values for selector taps and slider setting, and to confirm coordinates for coordinate-based taps.
   - `--summary` is `--flat --on-screen --labelled --format text`. Combine the parts yourself when you need more: `--flat` (no nesting; each node has `index`, `parent` and `depth`, under `nodes`), `--on-screen`, `--labelled`, `--actionable` (controls only), `--fields role,id,label,value,frame`, `--format json|ndjson|text` and `--compact` (one-line JSON). A full screen can hold hundreds of nodes, many of them off screen, so reach for plain `describe-ui` only when you need the whole tree.
   - Without those flags the output is `{"version": 1, "platform", "device", "screen", "roots": [...]}`. Each node has `role`, `id`, `label`, `value`, `frame`, `enabled`, `state` (`checked`, `selected`, `focused`), `native` and `children`; every key is present, with `null` when unknown. `--point` returns the same envelope with the hit element as the only root.
   - `--id`, `--label` and `--value` match a node's `id`, `label` and `value`. In React Native apps, `testID` appears as `id`.
   - `role` is one of `application`, `window`, `group`, `other`, `button`, `link`, `menuItem`, `tab`, `tabBar`, `segmentedControl`, `text`, `header`, `image`, `progress`, `textField`, `secureTextField`, `searchField`, `textArea`, `switch`, `checkbox`, `radioButton`, `slider`, `picker`, `cell`, `list`, `scrollView` or `keyboard`. `native` keeps the platform attributes, such as the iOS `type` (`TextField`, `RadioButton`), `role` (`AXButton`) and `roleDescription`.
   - `--element-type` narrows selector matches by `role` in any case (`button`, `switch`, `slider`) or by the exact native type (`RadioButton`, `TextEditor`).
   - Selectors prefer matches that are on screen. Apps often keep views mounted off screen (a closed bottom sheet parked below the screen, rows below the fold), so a match whose frame is outside the screen fails with an "is off screen" error naming its frame instead of tapping nothing. Scroll it into view or open the sheet first; `--wait-timeout` waits for it to come on screen. `--allow-offscreen` on `tap` and `slider` resolves it anyway.
   - Copy `--label` and `--value` text from `describe-ui`. Typographic quotes and odd spaces fold to their plain forms when nothing matches exactly (`--label "Don't Allow"` finds `Don’t Allow`), and a miss suggests the closest labels ("Did you mean ...?").
5. Prefer selectors (`tap --id` / `tap --label`, `slider --id` / `slider --label`) over raw coordinates. Selectors are resilient to layout changes, work across device sizes, and support element waiting where documented. For UIKit `UISwitch` and SwiftUI `Toggle` rows, selector taps activate the contained switch/toggle when the match contains exactly one such control. Default tap style is `automatic`: switches and toggles use physical touch down and up, while other taps send a single tap event.

## Step 2: Choose the right command

Available commands: `doctor`, `init`, `boot`, `tap`, `slider`, `swipe`, `drag`, `gesture`, `touch`, `type`, `button`, `key`, `key-sequence`, `key-combo`, `wait`, `assert`, `batch`, `describe-ui`, `screenshot`, `logs`, `appearance`, `content-size`, `orientation`, `shake`, `rn prepare`, `record-video`, `stream-video`, `list-devices`. Run `offsider --help` or `offsider <command> --help` for full options.

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
offsider describe-ui --summary --device <DEVICE_ID>
offsider describe-ui --point <X,Y> --device <DEVICE_ID>
offsider screenshot --device <DEVICE_ID> --output screenshot.png --scale points
offsider screenshot --device <DEVICE_ID> --region <X,Y,W,H> --compare before.png
offsider wait --id <identifier> --device <DEVICE_ID>
offsider assert --id <identifier> --has-value <text> --device <DEVICE_ID>
offsider logs --rn --last 1m --device <DEVICE_ID>
offsider appearance dark --device <DEVICE_ID>
offsider orientation landscape-left --device <DEVICE_ID>
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
- Use `--wait-timeout` or a `wait` step in batch to wait for elements to come on screen, and `wait --settled` to let animations finish; keep `sleep` steps and `--pre-delay` / `--post-delay` for when nothing observable marks the end.

## Step 4: Apply timing and input best practices
- Wait on a condition, never a guess: `offsider wait --id <id>` (on screen), `--gone`, `--has-value <text>`, `--settled` (nothing changed for `--quiet-ms`, default 500), `--region <x,y,w,h> --changed|--stable` (pixels, for content the tree cannot see) or `--seconds <n>` when your environment blocks `sleep`. `--timeout` defaults to 10 s; exit 0 means met and 5 means timed out, with the last state in the message. `offsider assert` checks once with the same selectors and exits 5 on failure. Both take `--json` (`met`, `elapsedMs`, `reason`, `match`). Never tap an element just to pass time.
- `tap` warns on stderr when another element may cover its target, such as a banner over a tab bar; add `--fail-if-covered` in scripts to stop instead. Overlays hidden from accessibility give no warning: when the tree looks right and taps do nothing, take a `screenshot`.
- Use `--pre-delay` / `--post-delay` on tap, swipe, and gesture commands for fixed delays around actions.
- Use `--duration` to control how long a swipe, gesture, button press, or key press lasts.
- Coordinate-based `tap`, `swipe`, `drag`, and `touch` accept coordinates from `describe-ui` directly; Offsider detects rotated landscape simulator orientation and letterboxed landscape-only app layouts automatically. A coordinate `tap` outside the screen prints a warning.
- Screenshots are in pixels by default; taps and `describe-ui` frames are in points. Capture with `screenshot --scale points` so image coordinates are tap coordinates, and crop with `--region <x,y,w,h>` (points, from `describe-ui`) instead of reading a full screen. `--scale <0.1-1>`, `--format jpeg` and `--quality` shrink the file; `--json` prints `path`, `width`, `height`, `pixelsPerPoint`, `region` and `orientation`. Landscape captures are upright.
- `gesture` scroll presets are named for the finger: `scroll-up` swipes up and reveals content below, `scroll-down` reveals content above.
- `gesture` presets are sized to the foreground app's frame and go through the same orientation handling, so they fit any device and landscape. `--screen-width` and `--screen-height` override that size, in points (dp on Android) as the screen is currently oriented.
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

## Step 4b: React Native and Expo apps
- Kept-mounted views: closed bottom sheets and the previous screens of a JavaScript stack often stay mounted. On iOS they stay in `describe-ui` with frames outside the screen; on Android nodes the user cannot see are left out. Selectors, `wait` and `assert` count only on-screen matches, so open the sheet, then `wait --id <id>` before tapping inside it; add `wait --settled` when it slides in. A previous screen still partly on screen under the current one keeps its ids: when `--id` reports multiple matches, narrow with `--element-type` or tap by coordinates.
- Rows without a `testID` or `accessibilityLabel` take their children's text as the label (`Inbox, 3 unread`), live values included, so `--label` stops matching when a value changes. Prefer `--id`; otherwise find the row in `describe-ui --summary` and tap its centre.
- Content under `accessibilityElementsHidden` or `importantForAccessibility="no-hide-descendants"` (apps often wrap charts and web views this way) is missing from the tree, buttons included, but still takes taps. Tap by coordinates and say so, or ask for the wrapper to expose its controls.
- Charts, maps, canvases and web views change pixels, not the tree: check them with `wait --region ... --changed` or `screenshot --region ... --compare`, and with the app's logs.
- `offsider logs --rn --device <DEVICE_ID>` prints `console.log`, `console.warn` and `console.error` output from the last 30 s, in release builds too. Use `--last 2m` or `--since <time>` to widen it, `--grep <regex>` to filter, `--app <bundle id or package>` for one app's native logs and `--duration <seconds>` to collect live output. Logs are the best check that an action did something a screenshot cannot show, such as a request being sent.
- Debug builds load JavaScript from Metro. An Expo dev client that cannot reach Metro shows its launcher instead of the app (`Development Build`, `Searching for development servers...`, and under `RECENTLY OPENED` a button named after the app and its Metro URL): ask the user to start Metro, then tap that button.
- Debug builds raise a LogBox banner at the bottom of the screen for `console.error` and uncaught errors, often over the tab bar (`console.warn` raises none; read warnings with `logs --rn`). It is in the tree (role `other` on iOS, `button` on Android), labelled with `!` or a count and then the message, such as `!, Request failed`. On iOS `tap` warns when it covers a target; on Android the banner also swallows taps just below it with no warning, so use `tap --verify` near one. Note the text, then continue. A tap that lands on the banner opens the full-screen LogBox inspector, which is in `describe-ui` (`Console Error`, `Log 1 of 1`): `tap --label Dismiss` clears the log and closes it, `tap --label Minimize` returns to the banner. On Android the inspector, the dev menu and its intro are separate windows, so while one is open `describe-ui` lists only that window and the app's elements seem to be missing.
- A fresh install of an Expo dev client opens its dev menu intro over the app: run `offsider rn prepare --bundle-id <bundle id or package> --device <DEVICE_ID>` before the first launch to skip it, or dismiss it with `tap --label Continue`, then `tap --id xmark` (on Android `tap --label Close --element-type button`). `rn prepare` needs a debug build and stops the app if it is running. `offsider shake` opens the dev menu on iOS debug builds (`Reload`, `Go home`; close with `tap --id xmark`); release builds ignore it. Taps on elements under the open dev menu get no cover warning, so close it first.
- `offsider appearance light|dark`, `content-size <category>|reset` and `orientation portrait|landscape-left|landscape-right` change the device and stay changed: read the current value by omitting the argument, and set it back when done. `orientation` waits until the screen has turned and prints the new size; a portrait-only app stays portrait and the command times out. On Android it turns auto-rotate off. Apps with their own theme setting follow `appearance` only when that setting is on automatic.

## Step 5: Batch vs discrete commands

**Prefer `offsider batch`** for multi-step flows. Batch runs input steps, `sleep`, and the read steps `wait`, `assert`, `screenshot` and `describe-ui`, written like the standalone commands without `--device`, in a single process invocation, which means:
- One tool call and one AI turn instead of many, which significantly reduces agent latency and cost.
- A single HID session is reused across all steps, lowering per-step overhead.
- Steps execute sequentially: each step runs before the next is resolved, so earlier taps can trigger navigation and later selector taps will find newly appeared elements (with `--wait-timeout`).

**Fall back to discrete commands** when:
- A step's parameters depend on runtime inspection of a previous step's result (e.g. parsing `describe-ui` JSON to choose coordinates dynamically).
- Using `slider`; batch steps do not support slider verification.
- You need `--verify`; batch steps reject `--verify`, `--verify-timeout`, `--retries` and `--json`. Run that input on its own with `--verify`, or follow the input with a `wait` or `assert` step.

```bash
offsider batch --device <DEVICE_ID> --json \
  --step 'tap --id open-filters' --step 'wait --id apply-filters' \
  --step 'tap --id apply-filters' --step 'assert --id filter-state --has-value Applied' \
  --step 'screenshot --output after.png --scale points' --step 'describe-ui --summary'
```

`batch --json` prints one JSON line per step to stdout (`step`, `kind`, `line`, `ok`, `ms`; `exitCode` and `error` on failure; `met`, `reason`, `match` for `wait` and `assert`; the screenshot fields; `tree` or `output` for `describe-ui`), then a summary line with `steps` and `failed`. Parse it instead of the text output. The batch exits 1 when a step failed to run, else 5 when a `wait`, `assert` or `screenshot --compare` condition was not met, else 0.

**Handling animations and transitions in batch:**
- Use `--wait-timeout <seconds>` (batch-level, or on one tap step to override it) so selector taps (`--id` / `--label`) poll the accessibility tree until the element is on screen, not merely mounted, or the timeout expires. A selector can resolve while a sheet is still sliding in: put `wait --settled` before the tap when that matters.
- Use `--poll-interval <seconds>` to control polling frequency during waiting (default 0.25s).
- Batch reuses an accessibility snapshot only until a step sends input or sleeps, so a selector step after a tap reads the new screen. A read straight after input can still see the old screen while the app reacts: add `--wait-timeout`. `--ax-cache perStep` reads fresh for every selector step.
- Before coordinate-based taps, use a `wait` step (`wait --settled`, or `wait --region ... --stable` for motion the tree cannot see); use `sleep <seconds>` only as a last resort.
- Keep batch output quiet by default. Add `--verbose` only when troubleshooting.
- Selector taps in batch share direct `tap` semantics, including switch/toggle activation-point handling and `--tap-style automatic` behavior. Use batch-level `--tap-style physical|simulator` as the default for tap steps, or step-level `tap --tap-style ...` to override one step.
- If `tap --label` reports multiple matches and none of them has an `id`, narrow with `--element-type` or fall back to `tap -x/-y` for that step.

Key rules:
- Use exactly one step source per run: `--step`, `--file`, or `--stdin`.
- Steps run in order; default is fail-fast.
- Add `--continue-on-error` for best-effort execution.
- After an exploratory run, keep the working sequence as a `batch --file` and re-run it once to prove it replays.
- Do not pass `--device` inside step lines; keep it at batch level.

## Step 6: Verify outcomes
Input commands without `--verify` are execution-focused, not assertion-focused. Check outcomes with `assert` or `wait` (as commands or batch steps) when they matter.

Exit 5 from a `--verify` command means the input was dispatched but nothing observable changed. Run `describe-ui` to check the target is on screen and interactive, then, on an iOS simulator, `offsider doctor --device <DEVICE_ID>` if input seems ignored. Read the `change` field of the JSON result to see how the change was detected.

```bash
offsider describe-ui --summary --device <DEVICE_ID>
offsider describe-ui --point <X,Y> --device <DEVICE_ID>
# or
offsider screenshot --device <DEVICE_ID> --output post-state.png --scale points
```

Content the accessibility tree cannot see (charts, maps, canvases, WebViews) changes pixels only, and `--verify` can report a change caused by something else on screen. Check that region itself: save a baseline with `screenshot --region <x,y,w,h> --output before.png`, act, then run `screenshot --region <x,y,w,h> --compare before.png`. It exits 0 when the region changed and 5 when it did not, and prints the changed share; `--threshold <0-1>` ignores small changes. Use the same `--region` and `--scale` for both captures.

## Step 7: Exit criteria
Before finalising guidance, verify:
- Every device-interaction command includes `--device`.
- Only valid Offsider commands and flags are used.
- Shell quoting is correct (single quotes for literals, `--stdin`/`--file` for complex text).
- Outcomes that matter are checked with `assert`, `wait`, `--verify` or a region compare.
- Device settings changed with `appearance`, `content-size` or `orientation` were set back.
- Labels were copied from `describe-ui`, and selector targets were on screen when tapped.
- Coordinates read from a screenshot came from a `--scale points` capture.
