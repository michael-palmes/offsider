# App guard

An `offsider.guard.json` in your app's repository names the controls an agent asks you before tapping (`ask`) or never taps (`never`). Everything else in the app is free, so once you approve the rules an agent can drive a production or store build without asking first. You set it up through your agent: it finds the guard through the bundled skill and `offsider guard status`, writes and keeps the file, and hands you one command to run once, `offsider guard approve`.

## The file

Offsider looks for `offsider.guard.json` from the working directory up to the repository root, as it does `offsider.mask.json`:

```json
{
  "// why": "Orders ask first; the password screen is the user's.",
  "apps": ["com.mpalmes.offsider.playground", "com.mpalmes.offsider.playground.rn"],
  "askUsers": ["qa-member"],
  "ask": [
    { "name": "Place an order", "id": "order-confirm-button" },
    { "name": "Confirm a transfer", "label": "Confirm", "screen": { "id": "transfer-review-screen" } }
  ],
  "never": [
    { "name": "Password", "screen": { "label": "Change password" }, "except": [{ "id": "password-help-link" }] },
    { "name": "Delete account", "labelContains": "Delete account" }
  ]
}
```

- `apps` lists the bundle ids and packages the rules cover. `ask` and `never` hold the rules. `askUsers`, when given, names the saved logins (as `credential status` lists them) an `ask` may be offered for; without it, any saved login. Top-level keys starting with `//` are comments.
- A rule has a `name` and a control: `id`, `idPrefix`, `label` or `labelContains`, and every one given must match. `id` is exact; labels ignore case, quote style and spacing.
- `screen` takes the same keys and limits the rule to while a matching element is on screen, so a common label such as Confirm guards only its own screen.
- A rule with a `screen` and no control makes that whole screen look-only: swipes, Back, Close, Cancel, Dismiss, Navigate up, Not now and its `except` controls still work.
- Unknown keys, repeated names and empty entries are refused, naming where. At most 16 apps, 64 rules per list and 64 KiB.

## What is guarded

Offsider judges the control an input would land on, not the command's text, reading the screen before it sends anything:

- a tap (by selector or coordinates), long press or touch on a guarded control, a drag or swipe that starts on one, and a `slider` set on one, alone or as a `batch` step;
- Return or Enter (`key`, `key-sequence`, or a newline in `type` text) while a guarded control, or a look-only screen, is up;
- `alert accept` and `alert choose` on a [permission prompt](device-state.md#permission-prompts) for the app: the prompt's button is judged against that app's rules, loaded by the app `--app` names, since the app itself has no element on screen. A rule's `screen` counts as showing, as the screen beneath a prompt cannot be read, so a prompt never loosens a rule. `alert deny` is free.

Rules apply to the app in front; when Offsider cannot name it, every guarded app's rules apply. Hardware buttons, plain typing and scrolling are free. When the tree shows nothing under a tap on a screen where a rule with both a `screen` and a control applies, Offsider reads the words around the point from a screenshot it never saves, with the Mac's own text recognition: words matching a rule's label apply that rule, no words lets the tap through, and when it cannot tell, it asks as an `ask` rule would.

## Ask or never

- `never`: nothing is sent, and the command exits 1 with `guarded_control`.
- `ask`: a Touch ID (or login password) sheet at the Mac names the control, the rule, the app and the saved login signed in. Yes sends that one input; no, or no answer, exits 1 with `person_required` and an `ask` for the agent to pass on.

An `ask` is offered only on a simulator, an emulator or a [test device](device-access.md#test-devices), and only when Offsider signed the account in with a saved login (`offsider login`) that `askUsers` allows. Otherwise the control is refused with `guarded_control`, and its `ask` says it is yours to tap.

## Approval

`offsider guard approve`, run by you in the app's repository, shows a short summary, takes Touch ID (or your login password) and keeps a copy of the file's rules for every app it names in `~/.config/offsider/guards.json`, sealed by a digest in the login Keychain. An agent gets `person_required`. `devices add`, run in the app's repository, can offer the same approval under its own Touch ID.

Offsider then enforces every approved rule, from any folder, and every rule in the file, when the command runs inside the repository. So an agent can only tighten:

- A new or stricter rule in the file applies at once, with no approval.
- Removing or loosening an approved rule, or adding a name to `askUsers`, changes nothing until you approve again. `guard status` lists it under `loosened`.
- An approvals file changed outside Offsider puts its apps in `changed`: their taps, swipes and Return are refused until you approve again.

A file that does not parse stops every input command with exit 64, naming the error, until it is fixed or moved aside.

## States

`offsider guard status --app <id> --json` gives each app a `state` and a `next` (`say`, `command`, and `person`, true when only you may run the command):

| State | Means | Next |
| --- | --- | --- |
| `missing` | No rules for the app | The agent runs `offsider guard init` |
| `unapproved` | The file is in force, and nobody has approved it | The agent asks before driving the app, and hands you `offsider guard approve` |
| `ready` | You approved rules | The agent drives freely; the guard asks you itself |
| `changed` | The approvals file was changed outside Offsider | You run `offsider guard approve` again |

## Commands

| Command | What it does |
| --- | --- |
| `guard status` | Where each app's guard stands and what to do next (`--app`) |
| `guard init --app <id>` | Writes a starter file in the working directory or `--project`: plain English labels, money controls under `ask`, sign-in and account security under `never`, with a todo list (swap labels for the app's ids or testIDs, scope common labels to a screen, leave device-only settings such as Face ID out); `--app` repeats for each build |
| `guard check` | Checks the file; with `--device <DEVICE_ID>`, says for each rule whether its control is on screen, or its screen is up without it, which usually means it was renamed |
| `guard show` | Lists the rules in force, and any waiting for approval |
| `guard approve` | You approve the file's rules, with Touch ID |

Each takes `--json`, and `--project <dir>` to look somewhere other than the working directory. `tap --dry-run` also names the rule that guards its target, sending nothing.

## Limits

- A rule by label misses a button whose copy changes, so prefer ids. `guard check --device` on each guarded screen shows a rule that no longer matches.
- Return and Enter are judged; Space on a control that holds keyboard focus is not, as Space is also plain typing. Guard such a control's screen with a whole-screen rule if keyboard focus can reach it.
- The approvals are sealed against edits, as the device allow-list is. Anything that can run commands as you can delete both the file and its Keychain seal, which leaves the app `unapproved` or `missing`, never quietly looser rules under `ready`.
- A guard governs Offsider's input only. Raw `adb` or `devicectl` input goes around it, and `offsider init`'s permission rules make an agent ask before running either.
- With rules in force, each input reads the screen before it is sent, reusing a tree the same command read in the last 1.5 s. With no rules, nothing more is read from the device.
