# Cloudflare Turnstile

A Turnstile checkbox or challenge is for a person. Offsider never taps it, and neither do you: not with `tap`, not on its label, not at its coordinates.

## Read the state

`offsider turnstile --device <DEVICE_ID>` reads the widget once and sends nothing. It prints `checkbox`, `verifying`, `passed`, `challenge` or `absent` and exits 0, or 6 when several checkboxes are on screen (pass `--id` for the app's wrapper). `--json` prints `{version, state, source, frame}`; `source` is `web-view-points` when iOS left the widget out of the tree and the state came from points in the web view.

## Hand back

- `checkbox` or `challenge`: stop and ask the user to complete it on the device. Carry on once `turnstile` reads `passed`.
- `login` stops with `turnstile_required` (exit 1) when a widget needs a person. Before typing, nothing was typed; after typing, the message and `submitted` in `--json` say whether submit was tapped. Hand back and never retry.
- `verifying`: wait, then read again. Before submit, `login` reads it again until `--timeout`, sending nothing, then hands back.

Offsider never mints, reads or submits a token and never calls Cloudflare.

## Unattended tests

A test that must pass without a person uses a build whose sitekey and server secret are Cloudflare's test pair, which always passes (sitekey `1x00000000000000000000AA`, or `1x00000000000000000000BB` invisible; `3x00000000000000000000FF` forces a challenge). The project's `OFFSIDER.md` names that build; without one, hand back.
