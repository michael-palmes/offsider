# App guard

`offsider.guard.json` in an app's repository names the controls you ask the user before tapping (`ask`) or never tap (`never`). Before anything is sent, Offsider judges the control under every tap, long press, touch, drag or swipe start, slider and batch step, and Return while a guarded control is up, whatever the command looks like. Everything else in the app is free.

## Before you drive an app

Before a production or store build, or when the repository has an `offsider.guard.json`, run `offsider guard status --app <id> --json` inside the app's repository, where its file applies, and do what the app's `next` says. `person: true` means only the user may run its `command`: give it to them on its own line, to run in the app's repository.

- `ready`: drive the app freely. The guard asks the user itself at a guarded control, so never ask first, and never work around a refusal.
- `unapproved`: the file is in force and nobody has approved it. Ask before driving the app, and give the user `offsider guard approve`.
- `missing`: no rules. Set them up (below); until the user approves them, ask before production or store builds, real accounts and anything that moves money or assets.
- `changed`: the approved rules were edited outside Offsider, which refuses input to the app. Give the user `offsider guard approve`.

`loosened` lists approved rules the file would weaken; they stay in force until the user approves again.

## Set one up

1. In the repository root, `offsider guard init --app <bundle id> --app <package>` writes a starter file of plain English labels, in force at once: money controls under `ask`, sign-in and account security under `never`.
2. Do its `todo` list. Search the app's source for each label and swap it for the control's testID or accessibility id (`"id": "order-confirm-button"`); delete rules the app has no control for; add any other control that moves money or assets (`ask`) or changes sign-in or account security (`never`); scope a common label such as Confirm to its screen (`"screen": { "id": "<an id on that screen>" }`); leave device-only settings such as Face ID out.
3. `offsider guard check` validates the file. Then open each guarded screen and prove its rules with `offsider guard check --device <DEVICE_ID> --app <id> --json`: `onScreen` is true where the control shows.
4. Give the user, on its own line, `offsider guard approve`. It takes Touch ID, once.

A rule matches by `id` (exact), `idPrefix`, `label` or `labelContains` (case, quotes and spacing ignored), all given; `screen` limits it to while a matching element is up. A rule with only `screen` makes that screen look-only: swipes, Back, Close, Cancel, Dismiss, Navigate up, Not now and its `except` controls still work. `askUsers` names the saved logins an `ask` may be offered for.

## Keep it current

- A rule whose `screenUp` is true and `onScreen` false was probably renamed: fix the file. A new or stricter rule needs no approval and applies at once.
- Removing or loosening a rule, or adding to `askUsers`, waits for the user's `offsider guard approve`; until then the approved rule holds.
- A file that does not parse stops every input command with exit 64: fix what it names.

## At a guarded control

Before a guarded tap, screenshot the review screen and tell the user in one line what you are about to tap.

- An `ask` is offered only on a simulator, emulator or test device, when `offsider login` signed the account in with a saved login `askUsers` allows. The user approves that one tap with Touch ID at the Mac.
- `guarded_control` (exit 1, nothing sent): a `never` control, or an `ask` the guard may not offer. Leave it, or tell the user it is theirs, passing on `error.ask`.
- `person_required` (exit 1, nothing sent): nobody approved the tap. Pass on `error.ask` word for word and carry on with what needs no tap.
- Never retry in a loop, and never reword the command, tap by coordinates, swipe or use raw `adb` to get past a refusal: the guard judges the control, not the command.
