# Cloudflare Turnstile

A Turnstile checkbox or challenge is for a person. Offsider never taps it, and neither do you: not with `tap`, not on its label, not at its coordinates.

## Read the state

`offsider turnstile --device <DEVICE_ID>` reads the widget once and sends nothing. It prints `checkbox`, `verifying`, `passed`, `challenge`, `absent` or `unknown` and exits 0, or 6 when several checkboxes are on screen (pass `--id` for the app's wrapper). `--json` prints `{version, state, source, frame}`; `source` is `web-view-points` when iOS left the widget out of the tree and the state came from points in the web view.

## Ask the user

`checkbox` or `challenge`, or `login` stopping with `turnstile_required` (exit 1): the user may be busy in another session, so ask for the step and watch for the result yourself.

1. **Ask** in a plain message, using `error.ask` word for word, or "Can you tick the Turnstile checkbox on <device name>?" (`offsider devices` has the name). Say you will carry on by yourself. Never "Have you ticked it?", never hurry them, and no question dialog: it cannot close itself when the tick lands.
2. **Watch** with `error.hint`: `offsider turnstile --wait 600 --device <DEVICE_ID>` only reads, and returns the moment the widget passes or leaves the screen. Run it in the background and end your turn when your client wakes you as it exits; otherwise run it in the foreground.
3. **Carry on.** Exit 0: if `login` stopped before submit, run it once more straight away, as a widget can reset. Exit 5: nobody has done it yet, so say so, carry on with what needs no sign-in, and ask once more at the end.

`submitted` in `login --json` says whether submit was tapped. When it is true, never run `login` again: read the screen once the widget passes. Never loop on `login`.

## Other states

- `unknown`: an element named for Turnstile is on screen with no widget in it, so the widget failed to run or runs invisibly. Do not read it as absent: check `offsider logs --rn --grep turnstile` and `doctor`'s `android-device.webview`. `login` goes on past it and reports `turnstile: unknown`, and `--wait` stops on it.
- `verifying`: wait, then read again, or use `--wait`. Before submit, `login` reads it again until `--timeout`, sending nothing, then asks to finish it.
- On a phone, another app in front or the lock screen counts as not yet done for `--wait`, and nothing is read from it. Still there when the time runs out, it exits with that failure (`app_not_allowed` or `device_locked`). An app the phone never allows stops the wait at once.

Offsider never mints, reads or submits a token and never calls Cloudflare.

## Unattended tests

A test that must pass without a person uses a build whose sitekey and server secret are Cloudflare's test pair, which always passes (sitekey `1x00000000000000000000AA`, or `1x00000000000000000000BB` invisible; `3x00000000000000000000FF` forces a challenge). The project's `OFFSIDER.md` names that build; without one, ask the user.
