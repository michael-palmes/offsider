# Sign in

## Test credentials only

`offsider credential set --device <DEVICE_ID>` saves a username or email and a password for the app in front. It asks for the username, then the password twice with typing hidden. `--stdin` reads those as two lines, so a password manager can pipe them in. The password is never printed, logged or put in an argument.

The first login saved for an app is the default. A tag such as `dev` or `qa` names another login for that same app: `offsider credential set qa --device <DEVICE_ID>`. When a login is already saved, a terminal asks whether to update one or create a new one and set a tag. Without a terminal, pass `--update` to replace the default, or a tag to add another. Pass `--update` with that tag to replace it. Nothing is overwritten by surprise.

Save test development credentials only. Anything that can run commands as you can then type them into this app.

`login` types a credential only into an app it was saved for, or into an app linked to that one. The items live in your login Keychain (service `com.mpalmes.offsider.login`, never synchronised). macOS asks once before a new or rebuilt offsider reads one. `login` holds the device while that prompt waits and prints a note after 3 seconds. The wait does not count as a hung device, but after 5 minutes without an answer login exits 1 and types nothing. `offsider credential status --app <id>` raises the same prompt without holding a device.

`offsider credential join --device <DEVICE_ID>` links the app in front to an app that already has saved logins. It does not ask for the password. When only one app has logins, that is the one. When several do, a terminal lists them, and otherwise pass `--app com.example.app`. A bundle id and a package can then share one set of logins, and `login` on either id uses them. An app that already has its own saved logins is not linked: remove those first. The link item stores no password.

`offsider credential status --device <DEVICE_ID>` prints the app, each tag and the username, never the password. The default is marked. With a tag it prints that one login. `offsider credential remove` deletes the default, and `offsider credential remove <tag>` deletes that tag. `--app com.example.app` addresses an app that is not in front for `set`, `status` and `remove`, and then `--device` is not required. `join` always reads the app in front. `--json` includes `username` and `saved`, and has no password field.

## What login does

`offsider login --device <DEVICE_ID>` fills the email or username field, fills the password field, and taps the submit button once, using the default login. `offsider login <tag>` uses that tag. One saved login is the default, including one saved earlier under a tag such as `dev`. When several logins are saved and none is the default, login exits 6 and lists the tags, not the usernames or passwords.

It finds the controls on its own. A candidate has to be in front: a point at its centre must land on it, so a screen mounted underneath does not count. The identity field is the one text field whose label or id is an email or a username. The password field is the one secure field. The submit button is a Log in, Sign in, Submit, Continue or Next button below the password, and it may be disabled until the fields are filled. Forgot, create, back and support are skipped, matching whole words, so a button named feedback is not treated as back. Zero matches exit 2 and two matches exit 6, and nothing is typed.

The software keyboard is dismissed before the submit button. When it still covers the next control, login stops (`target_under_keyboard`) and does not tap submit. It does not press Back.

`--timeout` (default 15 seconds) is how long login waits for the submit button to enable. `--wait-lock` waits while another command holds the device. `--json` prints one object. `identity` and `password` are the word `filled`, never the secret. `submitted` says whether the button was tapped.

## An app can pin its fields

`offsider.login.json`, found the same way as `OFFSIDER.md`, overrides detection for one app. `--project <path>` names the directory to search. Without it, a missing file is not an error. The file names the app with `bundleId`, `package` or both, so one file serves an iOS bundle id and an Android package that differ. One of them must be the app in front, or nothing is typed. A pinned id is still hit-tested: a covered control is a refusal, not a tap on whatever is in front of it.

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

Exit 0 means the submit button was tapped. It does not mean the server accepted the login.

Hand back on exit 1 or 5. Do not loop on it.

## Where it refuses

A physical iPhone or iPad is refused. Use a simulator, or an Android emulator or a USB phone the user names. `login` does not take `--app`. `credential` is refused on a physical iPhone or iPad when it would read the device. Pass `--app` to save a credential without reading one.

```bash
offsider credential set --device <DEVICE_ID>
offsider credential set dev --device <DEVICE_ID>
offsider credential join --device <DEVICE_ID>
offsider credential status --app com.example.app --json
offsider login --device <DEVICE_ID>
offsider login dev --device <DEVICE_ID>
```
