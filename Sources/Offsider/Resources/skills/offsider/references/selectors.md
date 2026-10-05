# Selectors, coordinates and gestures

## Selectors

- Prefer selectors (`tap --id`, `tap --label`, `slider --id`, `slider --label`) over raw coordinates: they are resilient to layout changes, work across device sizes and wait for elements with `--wait-timeout`.
- `--id`, `--label` and `--value` match a node's `id`, `label` and `value` from `describe-ui`. In React Native apps, `testID` appears as `id`.
- `--element-type` narrows matches by `role` in any case (`button`, `switch`, `slider`) or by the exact native type (`RadioButton`, `TextEditor`).
- Copy `--label` and `--value` text from `describe-ui`. Typographic quotes and odd spaces fold to their plain forms when nothing matches exactly (`--label "Don't Allow"` finds `Don’t Allow`), and a miss suggests the closest labels ("Did you mean ...?").
- Selectors prefer matches that are on screen. Apps often keep views mounted off screen (a closed bottom sheet parked below the screen, rows below the fold), so a match whose frame is outside the screen fails with an "is off screen" error naming its frame instead of tapping nothing. Scroll it into view or open the sheet first; `--wait-timeout` waits for it to come on screen. `--allow-offscreen` on `tap` and `slider` resolves it anyway.
- When `tap --label` reports multiple matches (exit 6), pick from the `candidates`, prefer `--id`, narrow with `--element-type`, or fall back to `tap -x <X> -y <Y>`.
- For UIKit `UISwitch` and SwiftUI `Toggle` rows, selector taps activate the contained switch or toggle when the match contains exactly one such control. The default `--tap-style automatic` uses physical touch down and up for switches and toggles and a single tap event for other taps; `--tap-style physical|simulator` forces one.
- Selector `tap` and `slider` wait out up to 500 ms after a recent input and tap the target where it settled; `--no-settle` skips that. An animation longer than 500 ms still needs `wait --settled` first.
- `tap` warns on stderr when another element may cover its target, such as a banner over a tab bar; add `--fail-if-covered` in scripts to stop instead. Overlays hidden from accessibility give no warning: when the tree looks right and taps do nothing, take a `screenshot`.

## Coordinates and gestures

- Coordinate `tap`, `swipe`, `drag` and `touch` accept coordinates from `describe-ui` directly, in points (dp on Android). Offsider detects rotated landscape simulator orientation and letterboxed landscape-only app layouts automatically. A coordinate `tap` outside the screen prints a warning.
- `gesture` scroll presets are named for the finger: `scroll-up` swipes up and reveals content below, `scroll-down` reveals content above. Presets are sized to the foreground app's frame and go through the same orientation handling, so they fit any device and landscape; `--screen-width` and `--screen-height` override that size, in points (dp on Android) as the screen is currently oriented.
- Use `--pre-delay` and `--post-delay` on `tap`, `swipe` and `gesture` for fixed delays around actions, and `--duration` for how long a swipe, gesture, button press or key press lasts.
- Keep a held touch in one command (`touch --down --up`) or one `batch`.
- `touch -x <X> -y <Y> --fingers 2 --hold <ms>` puts two fingers down `--spread` points apart (default 60) around the point, holds them and lifts both, for menus behind a two-finger hold. It works on a simulator's main display and Android emulators (gRPC, or the UiAutomation helper when input goes over adb); a physical iPhone and the iPhone Duo's inner display refuse it.

```bash
offsider tap --label 'Weather Alerts' --device <DEVICE_ID>
offsider tap -x <X> -y <Y> --tap-style physical --device <DEVICE_ID>
offsider drag --start-x <X1> --start-y <Y1> --end-x <X2> --end-y <Y2> --device <DEVICE_ID>
offsider gesture scroll-up --device <DEVICE_ID>
offsider slider --label <text> --value 40 --element-type slider --device <DEVICE_ID>
```

## Text and buttons

- `type` adds to the focused field. Tap the field, then `type --replace 'text'` sets it exactly and `--replace ''` clears it; it works with `--stdin`, `--file`, `--verify` and as a batch step. iOS selects all with Command-A and deletes, then types (secure fields included); Android sets the text in one step.
- A trailing newline presses Return on both platforms, so `$'query\n'` submits. Use single quotes inline, and `--stdin` or `--file` for shell-sensitive text.
- `button` names depend on the platform: iOS has `apple-pay`, `home`, `lock`, `side-button` and `siri`; Android has `back`, `app-switch`, `home`, `lock` (the power key), `volume-up` and `volume-down`. A button the device lacks exits 64.

## Sliders

- Use `offsider slider --id <identifier> --value <0-100>` instead of approximating with raw swipe coordinates. It always checks its own result: it re-reads the slider's `value` and fails clearly if the observed 0 to 100 value stays outside tolerance.
- On iOS it sends one calibrated low-level HID drag from the resolved slider frame and current `value`, through the same composite touch-move path as `drag`. iOS slider controls quantise values to their rendered track resolution, so Offsider does not retry correction gestures to chase unreachable decimals.
- On Android it uses the accessibility progress action (`guide android`).
