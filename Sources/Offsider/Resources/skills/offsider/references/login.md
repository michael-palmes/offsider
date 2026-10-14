# Sign in and test users

A saved user is a test username and password for one app, in the login Keychain, with a name, tags and notes that say what it is for. Choose one from those, never by guessing.

## Choose a user

`offsider credential status --app com.example.app --json` lists the app's users with no macOS prompt and no usernames:

```json
{"version":2,"action":"status","app":"com.example.app","users":[{"name":"qa-admin","default":true,"tags":["env=staging","role=admin"],"about":"Admin on staging, can change team settings","avoid":"Checkout tests: no store credit","state":"Cart holds 2 items","updated":"2026-10-11T09:30:00Z","signedIn":[]}]}
```

1. Work out what the test needs: role, environment, platform and starting data.
2. Keep users whose `tags` and `about` cover it. Drop any whose `avoid` names the test: `avoid` wins.
3. `state` was true at `updated`; it drifts.
4. One fits: `offsider login qa-admin --device <DEVICE_ID>`, or select it by tags with `--where`.
5. None fits: stop and tell the user what access the test needs. Never retag a user to make it fit.

`--where <tag>` repeats, and a user must have every tag; a bare word such as `credit` matches only a bare tag. One match signs in. None exits 2 (`user_not_found`), several exit 6 (`user_ambiguous`), and nothing is typed; the JSON error's `users` lists each one's `name`, `tags` and `about`, never a username. The default never breaks a tie, and the `hint` adds `platform=` when that leaves one. `credential status --where <tag>` is a dry run. With no name and no `--where`, `login` uses the default; several users and none the default exit 6. A name with `--where` exits 64, and an unsaved name exits 1. Every name `status` lists works with `login`, `status`, `describe` and `remove`, including `default`, which names only the user saved without a name. That is not always the user marked default: when the first user was saved under a name, it is the default but `default` does not reach it, so omit the name instead.

## Check the user

Exit 0 means `login` tapped submit, not that the app accepted the user. Trust the screen: `wait --any` for the signed-in screen or an error, then read which account it shows. `credential status <name>` reads that one Keychain item and adds its `username` to compare (macOS may ask first).

## Switch users

After `login` exits 0, Offsider records which user it submitted on that device and app. `status` shows each user's `signedIn` (`device`, `platform`, `since`). With `--device`, a top-level `signedInHere` names the user signed in there (null when none), and each listed user carries a `signedInHere` boolean. A record means Offsider submitted the form, not that the app accepted it, and selection ignores it.

1. Sign out in the app, with taps or one `batch`. Offsider never signs out.
2. `offsider credential signed-out --device <DEVICE_ID>` clears the record for the app in front (`--app` names another), and exits 0 even when there was none. It takes no name and always needs `--device`.
3. `offsider login --where role=member --device <DEVICE_ID>`.

The next `login` on that device and app replaces the record, and `credential remove` clears the user's records everywhere. A record stays after the device restarts, with `restarted: true`: the app may have kept or lost its session, so check the screen. When `login` finds no form and a record exists, the exit 2 message names the user last signed in and how to switch. An app that allows one session per account signs the user out elsewhere: put that in its `avoid`.

## Record what changed

When a test changes an account, record it: `offsider credential describe qa-admin --state 'Cart holds 3 items' --app com.example.app`, or `--untag credit` when a tag stops being true. `describe [name]` takes `--about` (access, and when to use the user), `--avoid` (tests it must not be used for), `--state` (what the account holds now, stamped `updated`), `--tag`, `--untag` and `--clear-tags`, and needs at least one. With no name it describes the default; `describe default` describes the user saved without a name. It never reads the password and needs no terminal. If macOS asks (offsider was rebuilt), it prints `Waiting for macOS` after 3 seconds: ask the user to answer.

Record only what you saw. Context is not secret: it sits in unencrypted Keychain attributes that any process running as you can read without a prompt. Never put a password, PIN, one-time code or anyone's personal details in it. A note is one line of at most 200 characters, and `""` clears it. A tag is a lowercase word or `key=value`, at most 16 per user, and `platform` takes only `ios` or `android`. Notes and tags refuse email-like text, control characters and bidi characters.

## Save a user

`offsider credential set --device <DEVICE_ID>` saves a username or email and a password for the app in front. On a terminal it asks for the username, the password twice (a dot per character), then, for a new user, an optional "What's it for" (Return skips it) and its tags only after an answer. `--stdin` reads the username and password as two lines, for a password manager. Both must be characters the keyboard can type: a username of 1 to 254, a password of 1 to 128. The password is never printed, logged or put in an argument. `set` takes the `describe` flags too.

`set` and `describe` also take three settings. `--devices virtual|any`: `virtual` (the default) is simulators and emulators only, and `any` also allows physical Android phones the user allowed. `--confirm`: `login` asks for Touch ID or the login password before it reads the password (on by default with `--devices any`). `--web-login`: `login` may type into a web view, together with `"webLogin": true` in `offsider.login.json`. Loosening (`--devices any`, `--no-confirm`, `--web-login`) needs a person at a terminal and Touch ID or their password, so ask the user to run it; tightening needs neither. `--devices any` turns `--confirm` on unless `--no-confirm` comes with it. `describe` with these flags rewrites the saved item, which may show a Keychain prompt.

The first user for an app is the default; a name saves another (`credential set qa-member`). `set default` saves the user without a name only while the app has no users, or replaces it with `--update`; beside named users it is refused before any password is read. With users saved, a terminal shows a menu to update one or add another, and asks before replacing a name. Without a terminal, pass `--update` to replace the default, a name to add one, or both to replace that one. Save test development credentials only: anything that can run commands as you can then type them into this app.

Items live in your login Keychain (service `com.mpalmes.offsider.login`, never synchronised). macOS asks once before a new or rebuilt offsider reads a password; `login` holds the device meanwhile, prints a note after 3 seconds, and after 5 minutes exits 1 with nothing typed. `credential status <name> --app <id>` raises that prompt without holding a device.

`credential join` links the app in front to another app's saved users, so a bundle id and a package share them. It is for a person only: it needs a terminal, shows both ids, asks Link or Cancel, then Touch ID or the password, and never reads the saved password. `--app` names the saved app, else a menu lists them. Never run it yourself; when `login` exits 1 with `person_required` naming it, ask the user to run that command in their own terminal. Browsers and system apps are never linked. `credential remove [name]` deletes the default or that user. Without `--app`, `set`, `status`, `describe`, `remove` and `signed-out` use the app in front on `--device` (or `OFFSIDER_DEVICE`); `--app <id>` names an app not in front, and then `set`, `status`, `describe` and `remove` need no `--device`. `join` always reads the app in front. `--json` is version 2: a user is named by `name`, only `set` and `status <name>` show `username`, and there is never a password field.

## Tags in OFFSIDER.md

Saved users live on each Mac. A repository's `OFFSIDER.md` maps flows to tags, never to accounts, and each person tags their own users to match:

```markdown
## Test users (com.example.app)
- Checkout: offsider login --where role=member --where credit --device <DEVICE_ID>
- Team settings: offsider login --where role=admin --where env=staging --device <DEVICE_ID>
```

## What login does

`login` fills the email or username field, then the password field, and taps the submit button once. It finds them itself, among elements in front (a point at the centre must land on it): the one text field whose label or id is an email or username, the one secure field, and a Log in, Sign in, Submit, Continue or Next button below the password, which may stay disabled until the fields are filled. Forgot, create, back, support and with (as in Continue with Google) are skipped. Words must be whole and ids split at capitals, so `signInButton` counts and Blog index does not. Zero matches exit 2, two exit 6, and nothing is typed.

It dismisses the software keyboard before submit with a tap on empty space (or on plain text), never a control: first above the topmost field, then up from the keys, and never on or just around a field. It tries up to three distinct points, reading the screen again after each. When the keys still cover the next control, it stops with `target_under_keyboard` and never presses Back.

`--timeout` (default 15 seconds) is how long it waits for submit to enable. `--json` prints one object: `ok`, the user's `name` and `tags`, `where` when passed, `turnstile` (`absent` or `passed`, null when it stopped before submit), `identity`, `password`, `submitted`, `exitCode` and `error`. `identity` and `password` are `filled` once login typed into the field and read it back, else `not_filled`, never the secret.

Once login reaches the email field, a failure still prints that object, with `ok: false`, `submitted: false` and the `error` object, even when the field never took focus (`identity: not_filled`), and the message ends "Both fields were filled." or "The email or username was filled." when that is so. A failure before then (no form, two matches, no saved user, `--where`) prints the standard error envelope instead, with `command` and no `identity`: nothing was touched. The exit code is the reason's either way.

## An app can pin its fields

`offsider.login.json`, found like `OFFSIDER.md` (`--project <path>` names where to search; a missing file is not an error), overrides detection for one app. It names the app with `bundleId`, `package` or both, and one must be the app in front, or nothing is typed. A pinned control is still hit-tested: covered is a refusal. `"webLogin": true` (default false) is half of the web view opt-in above; a `turnstile` key is ignored with a warning.

```json
{
  "bundleId": "com.example.app",
  "package": "com.example.android",
  "identity": { "id": "email-field" },
  "password": { "id": "password-field" },
  "submit": { "id": "login-button" }
}
```

## What exit 0 means

Exit 0 means the submit button was tapped, not that the server accepted the login. Hand back on exit 1 or 5. Do not loop on it.

| Reason | What happened | What to do |
| --- | --- | --- |
| `turnstile_required` | A Turnstile widget needs a person, found before typing, before submit or just after it; `submitted` says whether submit was tapped | Hand back; never tap it (`guide turnstile`) |
| `foreground_changed` | Another app came to the front before the password or before submit; nothing more was sent | Bring the app back, then run `login` again |
| `app_not_allowed` | A browser or system app is in front, or the password field is inside a web view | Bring the app under test to the front; web sign-in needs the user's opt-in |
| `person_required` | Touch ID or the password was cancelled or unavailable (plain ssh), or a link no person confirmed | Hand back; the message names the command for the user |
| `device_not_allowed` | A physical phone not allowed, or a user saved without `--devices any` | Ask the user; never loosen it yourself |
| `device_busy` (exit 8) | `record-video` is recording the device; nothing was typed | Stop the recording, then retry |

On an iOS simulator, iOS can offer to save the password a second or more after a sign-in. `describe-ui` then shows `# window: Save Password? (system)` without its buttons, and a selector `tap` under it refuses with `target_covered` (`evidence` `otherProcess`) rather than spend the tap dismissing it. Take a screenshot and tap Not Now by its coordinates (`tap -x <X> -y <Y>`), or tap its backdrop as the refusal says, then wait until the header has gone. Never tap Save.

## Where it refuses

A physical iPhone or iPad is refused; use a simulator or an Android emulator. A USB Android phone works only when the user named it, allowed it with `device-access allow`, and saved the user with `--devices any`. A `login` saved with `--confirm` needs the user at the Mac for Touch ID. For other secrets, such as a one-time code, use `type --stdin`: argument text into a password field exits 64 (`secure_field_argument`). `login` does not take `--app`. `credential` is refused on a physical iPhone or iPad when it would read the device: pass `--app` to save or describe a user without reading one.

```bash
offsider credential status --app com.example.app --json
offsider credential status --where role=admin --app com.example.app
offsider login --where role=admin --where env=staging --device <DEVICE_ID>
offsider credential signed-out --device <DEVICE_ID>
offsider credential describe qa-admin --state 'Cart holds 3 items' --app com.example.app
offsider credential set qa-member --device <DEVICE_ID>
```
