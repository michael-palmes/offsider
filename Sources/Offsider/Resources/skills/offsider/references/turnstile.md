# Cloudflare Turnstile

## It does not bypass the check

`offsider turnstile` only taps the checkbox a person would tap. It does not bypass Cloudflare Turnstile.

Cloudflare still runs the widget in the page and decides whether this device is eligible. The widget passes only when Cloudflare accepts the device: a managed or non-interactive check that this visitor is allowed, or a test sitekey the app and its server are both built to accept. A simulator or emulator is often not eligible. The checkbox then stays, a visual challenge appears, or the app rejects the token. The command cannot make that login succeed.

Offsider never mints, reads or submits a Turnstile token, never calls siteverify or any other Cloudflare API, and never changes the sitekey or the secret. Exit 0 means the widget on screen reads Success. It does not mean the app's server accepted a token.

A visual challenge fails with a message (exit 1). A tap on the checkbox cannot complete an image grid, so do not retry the tap to wear the check down. For a test that must pass on a device Cloudflare will not accept, use a build whose sitekey and server secret are Cloudflare's matching test pair.

## Reading the state

`offsider turnstile --status --device <DEVICE_ID>` reads the widget once and taps nothing. It prints `checkbox` (with the checkbox frame), `verifying`, `passed`, `challenge` or `absent`, and exits 0 for all five (6 when several checkboxes are on screen). `--json` prints `{version, state, source, frame}`, where `source` is `tree`, or `web-view-points` on iOS when the state came from points read inside the web view. `--id` works as below; `--jitter`, `--seed` and `--timeout` do not apply.

## When to hand back

When you test sign-in end to end, run `offsider turnstile` yourself first; do not stop at the checkbox and ask a person to tick it. Hand back only after it exits 1 with `turnstile_challenge` (a visual challenge) or 5 (the checkbox stayed: Cloudflare did not accept the device). Never loop on it: one run is one tap, and repeating it cannot change Cloudflare's answer.

## What the tap does

The checkbox's accessibility frame includes the words beside the square, so `tap --label "Verify you are human"` lands on the words. `offsider turnstile --device <DEVICE_ID>` taps the square, a few points off its centre (`--jitter`, repeat one offset with `--seed`), and waits until the widget reads Success or `--timeout` runs out (default 15 seconds).

It finds a `cf-chl-widget` container, or that checkbox label when the container id is missing. `--id` limits the search to one element, such as the app's wrapper around the widget. On iOS the web view leaves the checkbox and the Success text out of the tree. The command reads a point in the short web view: Success means it has already passed and nothing is tapped, and otherwise the tap is the square where the green check sits.

One run taps once. A widget that already reads Success is left alone.

## When it does not pass

- Exit 5: the checkbox is still there, the widget was still checking, or it left the screen before it passed. The device was not accepted, or the check had not finished. Read the message, then `describe-ui --summary`.
- Exit 2: no widget is on screen.
- Exit 6: more than one checkbox is on screen. Pass `--id` for the wrapper you want.
- Exit 1 (`turnstile_challenge`): the widget is showing a visual challenge.

To wait for whichever comes first after the tap, the next screen or a challenge, use `wait --any --label 'Success!' --label 'Verify you are human'`.

The widget can reload while the screen sits there. A Success that returns to the checkbox is a new check, so to confirm it passed for good, wait with `wait --label 'Verify you are human' --gone --stable-for 2000` rather than a single read. Run `turnstile` again only after a reload; it still taps only once, and it still passes only when Cloudflare accepts the device.
