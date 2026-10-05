# React Native and Expo apps

## Ids, labels and roles

- `testID` is `id` and `accessibilityLabel` is `label` on both platforms (on Android from `content-desc`).
- A `View` with neither `accessible` nor `testID` can be flattened away on Android, so ask for a `testID` when a target is missing. A `Pressable` without a label takes its children's text as its label.
- Rows without a `testID` or `accessibilityLabel` take their children's text as the label (`Inbox, 3 unread`), live values included, so `--label` stops matching when a value changes. Prefer `--id`; otherwise find the row in `describe-ui --summary` and tap its centre.
- Checkboxes, radio buttons and switches report their role on both platforms, with `value` `1`, `0` or `2` (mixed), so `--element-type radioButton` works on iOS too. On iOS a combo box and a progress bar may still read as `other`; select those by `--id` or `--label`.
- `offsider button back` pops React Navigation and custom stacks on Android, like the hardware back button.

## Kept-mounted views

- Closed bottom sheets and the previous screens of a JavaScript stack often stay mounted. On iOS they stay in `describe-ui` with frames outside the screen; on Android nodes the user cannot see are left out.
- Selectors, `wait` and `assert` count only on-screen matches, so open the sheet, then `wait --id <id>` before tapping inside it; add `wait --settled` when it slides in. A partly visible element is tapped at the centre of its visible part.
- A previous screen still partly on screen under the current one keeps its ids: when `--id` reports multiple matches, add `--topmost` to tap the page on top (or `--nth <n>` from the candidates' `index`). On Android an earlier page in the tree is drawn beneath the later one, so it never counts as covering it.
- On Android a `Modal` is its own window, so only the modal is in the tree while it is open; `describe-ui --summary` then starts with `# window: <title> (modal)`.
- Content under `accessibilityElementsHidden` or `importantForAccessibility="no-hide-descendants"` (apps often wrap charts and web views this way) is missing from the tree, buttons included, but still takes taps. Tap by coordinates and say so, or ask for the wrapper to expose its controls.
- Charts, maps, canvases and web views change pixels, not the tree: check them with `wait --region <x,y,w,h> --changed` or `screenshot --region <x,y,w,h> --compare before.png`, and with the app's logs.

## Cloudflare Turnstile

The checkbox frame includes the words beside the square, so `tap --label "Verify you are human"` lands on the words. `offsider turnstile` taps the square. `turnstile --status` reads it without a tap. When testing sign-in, run `turnstile` yourself and hand back only after exit 1 (a visual challenge) or 5 (the device was not accepted). It does not bypass Turnstile: the widget passes only when Cloudflare accepts the device. Read `offsider guide turnstile` before you rely on it.

## Logs

`offsider logs --rn --device <DEVICE_ID>` prints `console.log`, `console.warn` and `console.error` output from the last 30 s, in release builds too, and is the best check that an action did something a screenshot cannot show, such as a request being sent. Windows, filters, `--json` and redaction are in `offsider guide evidence`.

## Debug builds

- Debug builds load JavaScript from Metro. An Expo dev client that cannot reach Metro shows its launcher instead of the app (`Development Build`, `Searching for development servers...`, and under `RECENTLY OPENED` a button named after the app and its Metro URL): ask the user to start Metro, then tap that button.
- A cold bundle can take minutes to load, so give the first `wait` after a launch a long `--timeout` (up to 900 s).
- Testing offline on an emulator: airplane mode, `svc wifi disable` and `svc data disable` also cut the dev client's route to Metro at `10.0.2.2`, so Metro goes quiet and a reload shows the launcher. A dev client pointed at `localhost:<port>` over an `adb reverse` the user set keeps reaching Metro in airplane mode, since the reverse runs over adb (Offsider never sets one). Blocking one app's network (`cmd connectivity set-package-networking-enabled`) also blocks its loopback on API 35 and 36 and does not exist on API 34, so Offsider has no `network` command. The app sees `onLost` within about a second of airplane mode, and `logs --rn` keeps reading the device log throughout; turn the network back on before reloading.
- Debug builds raise a LogBox toast at the bottom of the screen for `console.error` and uncaught errors, often over the tab bar (`console.warn` raises none; read warnings with `logs --rn`). It is in the tree (role `other` on iOS, `button` on Android), labelled with `!` or a count and then the message, such as `!, Request failed`, and `describe-ui --summary` starts with `# logbox: 2 logs`. `tap` warns when it covers a target on both platforms, including taps just below it on Android, where its touch area reaches the bottom of the screen. Note the text, then clear it: `offsider rn logbox dismiss --device <DEVICE_ID>` taps each toast's clear button, or opens the inspector and taps `Dismiss` once per log, and exits 5 when logs remain. `rn logbox status --json` reads `{logs, toasts, inspector}` without a tap.
- A tap that lands on a toast opens the full-screen LogBox inspector, which is in `describe-ui` (`Console Error`, `Log 1 of 1`; the summary says `# logbox: inspector open`): `rn logbox dismiss` or `tap --label Dismiss` clears the log and closes it, `tap --label Minimize` returns to the toast. On Android the inspector, the dev menu and its intro are separate windows, so while one is open `describe-ui` lists only that window and the app's elements seem to be missing.
- A fresh install of an Expo dev client opens its dev menu intro over the app: run `offsider rn prepare --bundle-id <bundle id or package> --device <DEVICE_ID>` before the first launch to skip it, or dismiss it with `tap --label Continue`, then `tap --id xmark` (on Android `tap --label Close --element-type button`). `rn prepare` needs a debug build and stops the app if it is running.
- `offsider shake` opens the dev menu on iOS debug builds (`Reload`, `Go home`; close with `tap --id xmark`); release builds ignore it. Taps on elements under the open dev menu get no cover warning, so close it first.
- An app dev menu behind a two-finger hold (a feature flag or debug panel) opens with `touch -x <X> -y <Y> --fingers 2 --hold 1000`.
