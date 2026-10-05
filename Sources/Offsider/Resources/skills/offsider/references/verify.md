# Verifying input and waiting

## The execution model

Most input commands (`tap`, `swipe`, `drag`, `type`, `key` and the rest) are fire-and-forget: Offsider confirms the event was dispatched but cannot know the app processed it. A tap may land before a view is interactive, or during a transition. `slider` is the exception: it sets the matched slider, re-reads its `value` and fails when the result is outside tolerance.

## --verify

- Add `--verify` to `tap`, `type`, `key` or `button` to wait for an observable change after the input. Offsider compares the accessibility tree (ignoring elements that were already changing), then falls back to screenshots; it exits 0 when something changed and 5 when nothing did. "Verified" means something changed, not that the right thing changed: check the new state when it matters.
- `--verify-timeout <seconds>` (0.5 to 30, default 2) is the wait per attempt. `--retries <n>` (0 to 3, default 1) repeats the input when nothing changed; tap retries switch between simulator and physical tap style. Use `--retries 0` for non-idempotent actions such as submit, send or delete, because a late effect plus a retry can act twice.
- `--json` (requires `--verify`) prints one object to stdout (version 2) with `verified`, `dispatched` (`yes`, `no` or `unknown`), `attempts`, `change` (`accessibility-tree`, `screenshot`, `activity` for Android `button home`, or `none`), `changes` (up to 10 `{kind, node, field, old, new}` entries, value and state changes first) with `changesTruncated`, `note` (`keyboard_closed` when only the keyboard went away: repeat the input if the control shows no effect), `style` (tap only), `exitCode` and `error` (null, or the error object from `guide errors`); human text goes to stderr.
- On Android, `button home` checks the launcher came to the front, sending the HOME intent once when the key is ignored (some images drop it while an app is in front). With `--verify`, `change` is `activity` and `note` is `home_intent` when the intent was needed; exit 5 means the app stayed in front.
- A `screenshot` change can be animation or the status bar clock in landscape, so confirm with `describe-ui`. `button lock` only shows as a black screen.
- Exit 5 from `--verify` means the input was dispatched but nothing observable changed. Run `describe-ui` to check the target is on screen and interactive, read the `change` field, then, on an iOS simulator, run `offsider doctor --device <DEVICE_ID>` if input seems ignored.
- Without `--verify`, check outcomes with `assert`, `wait`, `describe-ui` or `screenshot` when app behaviour matters.

## describe-ui --diff

After an action, `offsider describe-ui --diff --device <DEVICE_ID>` prints only what changed since the previous command's tree: `added`, `changed ... (was: ...)` and `removed` lines, or the full view when most of the screen changed. After a tap it compares with the screen before the tap. `unchanged since tap 840 ms ago` means the screen matches that earlier tree exactly: the action had no visible effect yet, so wait or check the target rather than re-reading. Text only.

## wait and assert

- `offsider wait --id <id>` waits until an element is on screen; also `--label`, `--value`, `--gone`, `--has-value <text>`, `--settled` (nothing changed for `--quiet-ms`, default 500), `--region <x,y,w,h> --changed|--stable` (pixels, for content the tree cannot see) or `--seconds <n>` when your environment blocks `sleep`.
- `--gone` holds for 500 ms by default: the element must stay off screen on every read for that long, so a node that disappears for one frame (a re-render, a list refresh) does not count as gone. `--stable-for <ms>` sets that hold for any selector wait (0 turns it off; with a plain selector the element must stay on screen that long). `--settled` and `--region --stable` use `--quiet-ms` instead.
- `--timeout` defaults to 10 s and `--timeout` and `--seconds` go up to 900 s: a cold React Native bundle can take minutes. Exit 0 means met and 5 means timed out, with the last state in the message. When `--settled` cannot read the tree at all it exits 1: use `--settle-by screen`.
- `offsider assert` checks once with the same selectors (and `--has-value`, `--gone`) and exits 5 on failure.
- Both take `--json` (`met`, `elapsedMs`, `reason`, `match`).
- Use `--wait-timeout` on selector taps, or a `wait` step in batch, for elements to come on screen, and `wait --settled` to let animations finish. Keep `sleep` steps and `--pre-delay` or `--post-delay` for when nothing observable marks the end.

## Content the tree cannot see

Charts, maps, canvases and web views change pixels only, and `--verify` can report a change caused by something else on screen. Compare that region instead: save a baseline with `screenshot --region <x,y,w,h> --output before.png`, act, then run `screenshot --region <x,y,w,h> --compare before.png` (`guide screenshots`), or use `wait --region <x,y,w,h> --changed`.
