# Selectors, coordinates and gestures

## Selectors

- Prefer selectors (`tap --id`, `tap --label`, `slider --id`, `slider --label`) over raw coordinates: they are resilient to layout changes, work across device sizes and wait for elements with `--wait-timeout`.
- `--id`, `--label` and `--value` match a node's `id`, `label` and `value` from `describe-ui`. In React Native apps, `testID` appears as `id`.
- `--element-type` narrows matches by `role` in any case (`button`, `switch`, `slider`) or by the exact native type (`RadioButton`, `TextEditor`).
- On `tap`, `wait` and `assert`, `--id` with `--label`, `--value` or both matches only an element that has all of them, such as `tap --id interval-btn --label 1W` among buttons sharing one id. When the id matches but no match has that label or value, it fails as not found and lists them. `wait --any` still takes each selector on its own.
- Copy `--label` and `--value` text from `describe-ui`. Typographic quotes and odd spaces fold to their plain forms when nothing matches exactly (`--label "Don't Allow"` finds `Don’t Allow`), and a miss suggests the closest labels ("Did you mean ...?").
- Selectors prefer matches that are on screen. Apps often keep views mounted off screen (a closed bottom sheet parked below the screen, rows below the fold), so a match whose frame is outside the screen fails with an "is off screen" error naming its frame instead of tapping nothing. Scroll it into view or open the sheet first; `--wait-timeout` waits for it to come on screen. `--allow-offscreen` on `tap` and `slider` resolves it anyway.
- With several matches, a selector takes the only one not on a screen beneath a full-screen page (a pushed page drawn over a screen that stays mounted), and when the matches share one point, such as two stacked Back buttons, it taps that point, which reaches the one on top.
- When `tap --label` still reports multiple matches (exit 6), pick from the `candidates`, prefer `--id`, narrow with `--element-type`, or fall back to `tap -x <X> -y <Y>`. Each candidate names its `index` (the number `--nth` takes), its `window`, its `screen` (the page or covered screen it is on, else the id of the screen-filling view it sits in) and `beneath` (true when a page covers it). `tap --nth <n>` taps the nth on-screen match in tree order; `tap --topmost` taps the one drawn on top (the one a hit-test reaches on an iOS simulator, by Android's drawing order on Android, else the last in tree order), for a screen whose earlier pages stay mounted with the same ids.
- For UIKit `UISwitch` and SwiftUI `Toggle` rows, selector taps activate the contained switch or toggle when the match contains exactly one such control. The default `--tap-style automatic` uses physical touch down and up for switches and toggles and a single tap event for other taps; `--tap-style physical|simulator` forces one.
- Selector `tap` and `slider` wait out up to 500 ms after a recent input and tap the target where it settled; `--no-settle` skips that. An animation longer than 500 ms still needs `wait --settled` first.
- A selector `tap` refuses (`target_covered`, exit 1, nothing sent) when a hit-test on an iOS simulator, or Android's drawing order, finds another element over its target, such as a pushed page's button over a tab of the screen beneath; the message and `coveredBy` name it. `--wait-timeout` reads again until the cover goes; `--allow-covered` taps anyway. Where only tree order suggests a cover (a physical iPhone or iPad, or Android without drawing order) it warns on stderr and taps; `--fail-if-covered` refuses then too. Overlays hidden from accessibility give no warning: when the tree looks right and taps do nothing, take a `screenshot`. A target under the on-screen keyboard is always refused, by `tap` and `type --into-id` alike (`target_under_keyboard`, nothing sent): hide the keyboard (on Android, `button back`) or scroll the target above it, then retry.

## Coordinates and gestures

- Coordinate `tap`, `swipe`, `drag` and `touch` accept coordinates from `describe-ui` directly, in points (dp on Android). Offsider detects rotated landscape simulator orientation and letterboxed landscape-only app layouts automatically. A coordinate `tap` outside the screen prints a warning.
- `gesture` scroll presets are named for the finger: `scroll-up` swipes up and reveals content below, `scroll-down` reveals content above. Presets are sized to the foreground app's frame and go through the same orientation handling, so they fit any device and landscape; `--screen-width` and `--screen-height` override that size, in points (dp on Android) as the screen is currently oriented.
- Something that drags only after a long press (a reorderable row, a tile) needs a hold before the move: `drag ... --hold-ms 800`, or `gesture long-press-drag --x <X> --y <Y> --to-x <X2> --to-y <Y2>`. A plain `drag` holds 50 ms, so it scrolls or does nothing there.
- Use `--pre-delay` and `--post-delay` on `tap`, `swipe` and `gesture` for fixed delays around actions, and `--duration` for how long a swipe, gesture, button press or key press lasts.
- Keep a held touch in one command (`touch --down --up`) or one `batch`.
- `touch -x <X> -y <Y> --fingers 2 --hold <ms>` puts two fingers down `--spread` points apart (default 60) around the point, holds them and lifts both, for menus behind a two-finger hold. It works on a simulator's main display, Android emulators (gRPC) and Android phones (the UiAutomation helper, started for the command, about 1.7 s on a Pixel 2 XL); `OFFSIDER_ANDROID_INPUT=input`, a physical iPhone and the iPhone Duo's inner display refuse it.

```bash
offsider tap --label 'Weather Alerts' --device <DEVICE_ID>
offsider tap -x <X> -y <Y> --tap-style physical --device <DEVICE_ID>
offsider drag --start-x <X1> --start-y <Y1> --end-x <X2> --end-y <Y2> --device <DEVICE_ID>
offsider gesture scroll-up --device <DEVICE_ID>
offsider slider --label <text> --value 40 --element-type slider --device <DEVICE_ID>
```

## Text and buttons

- `type` adds to the focused field. Tap the field, then `type --replace 'text'` sets it exactly and `--replace ''` clears it; it works with `--stdin`, `--file`, `--verify` and as a batch step. iOS selects all with Command-A and deletes, then types (secure fields included); Android sets the text in one step.
- `type --into-id <id>` (or `--into-label`) taps the field and waits up to 2 s for it to take focus (on an iOS simulator, for the keyboard) before typing; when it never does, nothing is typed and it exits 5 (`focus_not_confirmed`). On a simulator only a keyboard appearing proves focus: when the keyboard is already up for another field, it taps and types anyway with a `Warning:` that it cannot confirm which field has focus, so check the field with `assert --has-value`. `type --require-focus-id <id>` types only when that field already has focus and exits 2 (`focus_mismatch`, naming the focused field) otherwise; iOS simulators do not report focus, so use `--into-id` there (a physical iPhone or iPad reports keyboard focus, so both work). Text the simulator keyboard cannot type fails before the focus tap.
- A trailing newline presses Return on both platforms, so `$'query\n'` submits. Use single quotes inline, and `--stdin` or `--file` for shell-sensitive text.
- `button` names depend on the platform: iOS has `apple-pay`, `home`, `lock`, `side-button` and `siri`; Android has `back`, `app-switch`, `home`, `lock` (the power key), `volume-up` and `volume-down`. A button the device lacks exits 64.

## Sliders

- Use `offsider slider --id <identifier> --value <0-100>` instead of approximating with raw swipe coordinates. It always checks its own result: it re-reads the slider's `value` and fails clearly if the observed 0 to 100 value stays outside tolerance.
- On iOS it sends one calibrated low-level HID drag from the resolved slider frame and current `value`, through the same composite touch-move path as `drag`. iOS slider controls quantise values to their rendered track resolution, so Offsider does not retry correction gestures to chase unreachable decimals.
- On Android it uses the accessibility progress action (`guide android`).
