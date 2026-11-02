# Physical devices

A physical iPhone, iPad or Android phone is refused until a person at the Mac adds it. Simulators and emulators need nothing added.

```bash
offsider devices add       # one command and Touch ID; asks only what it cannot work out
offsider devices add --plan  # the full command for each connected phone; an agent can read it
offsider devices           # every device; an added phone shows "allowed"
offsider devices status    # what agents may drive, until when, and any managed policy
offsider devices remove    # pick one to withdraw; stops its runner and session broker
```

- `offsider devices add --plan` (`--json`) lists each connected phone with the complete command that adds it, as a test device or for one app, the teams on this Mac and any step only your hands can do. It changes nothing, reaches no phone and needs no terminal, so an agent can read it and hand you one line to run.
- A flag settles its question, and `--test-device` or `--app` settles the rest: one app lasts 7 days, a test device until removed, with no Metro port. So `offsider devices add --device <ID> --test-device` asks nothing on a Mac with one team.
- With no flags, `add` asks only what it cannot work out, each a menu with the right answer already chosen and its keys beside it (`2/4 How will you use it? (↑↓, Enter, Q quit)`), so nothing has to be looked up or pasted:
  - **Device:** the USB-connected iPhones, iPads and Android phones, by name and the last four characters of their ID. A Wi-Fi-only one is dim and cannot be chosen. R rescans, Q quits with nothing saved. One phone and nothing else connected needs no menu.
  - **Use:** One app (recommended), or Test device, for a phone with nothing personal on it ([Test devices](#test-devices)).
  - **Team** (iPhone or iPad): the code-signing identities in your login Keychain, or type a team ID. Each row shows the team's name, `Free` or `Paid` where Xcode's local preferences say, its ID, and the account's email when its development certificate's common name holds one. Free teams come last. The email is never saved. One team needs no menu.
  - **App:** the recommended app first and chosen (`offsider.login.json`'s app when installed, else on Android the app in front), then the other installed apps, then "Any app" (every app on the phone, banking and messages included) and, on Android, "Any app and all logs" (the phone's whole log too); browsers, home screens and system apps are never offered. When the list cannot be read, type an app ID. The installed apps, and on Android the app in front, are read before Touch ID.
  - **Metro** (Android phone): None (recommended), 8081, or type ports. `rn open` may set an `adb reverse` for a chosen port, which every app on the phone can reach while it is set ([Android](android.md)).
  - **How long:** 2 hours, 12 hours, 24 hours, 7 days, until removed, or type one. One app recommends 7 days, any app 12 hours.
- A step only your hands can do (Trust, USB debugging, Developer Mode, a cable) shows as a request naming the phone, and `add` watches its listing and carries on when it clears. Q stops. It stops waiting after 10 minutes with nothing saved.
- A one-line summary naming the device, its app, any Metro port and how long, then Touch ID or your login password. Each answer stays as a receipt line.
- That one Touch ID also covers an iPhone or iPad's setup: `add` then registers it with the team, builds the runner and starts it, asking by name for anything on the phone it waits on (the certificate under VPN & Device Management, UI Automation, an unlock) and trying again as you do them. It says `Ready` once the runner answers. If it cannot finish, the allowance stays and it names what stopped it; `--json` adds `ready` and `needs`. An Android phone has nothing to set up here, so it says `Allowed` and offers `doctor`. Then "Add a test login?" with Skip chosen: Add one picks the app when there is more than one, and asks for the username and password there, with no second command or Touch ID. On a one-app or any-app phone that login is saved for phones.
- A closing block shows the full ID only in its commands: `Withdraw` (`devices remove`), and `Next` (`offsider doctor --device <ID>`) when not yet proved ready. When another connected device is not yet allowed, it offers that one too (Q is Done). With `NO_COLOR`, `UI_ASCII=1` or a locale that is not UTF-8 it shows ASCII tags such as `[iPhone]` in place of emoji, and `NO_COLOR` also drops colour.
- `--device`, `--app`, `--team`, `--metro-port` (repeatable, or `none`), `--test-device` and `--expires` skip their steps (`offsider devices add --device <ID> --app com.example.app --expires 2h`). A device named with `--device` asks nothing more about its ID: the summary names it, and Touch ID is the confirmation.
- The device menu marks a device that is already allowed "allowed". Choose it to change it: each step starts on what it has now (`Keep ...`), since saving replaces the whole entry, and Touch ID still confirms it. A test device keeps its whole-device access only while managed policy allows it. `devices status` shows a person a 🔐 header counting the allowed devices, a row for each with its apps and expiry, and the commands to add another or withdraw one; an agent or a pipe gets plain text, and `--json` gets JSON, whatever the terminal.
- `add` needs a terminal on standard input: without one it exits 1 with `person_required` and writes nothing, so an agent cannot add a device. An agent reads `--plan` and gives the user the command to run. Nothing stops an agent reading `--help`: Offsider's own refusal is the gate, not a permission rule.
- The same look carries over to the `credential add`, `credential join`, `credential describe`, `unlock-code set` and `login` prompts, and to `init` on a terminal.
- `device-access` was the name before 0.13.0: `device-access allow`, `remove` and `status` exit 64 with a line naming `devices add`, `remove` or `status`.
- An allowance lasts `--expires` (`<n>m`, `<n>h` or `<n>d`, at most `30d`, or `never`), and expired entries are removed on the next write. `--app` (repeatable) pins the apps Offsider may drive there; a browser or system app is refused, and the app menu never offers one or an app outside a managed `allowedBundleIDs`. With no app pinned, each command drives only the app it names (`--app`, else `offsider.login.json`'s app), on every platform. For an iPhone or iPad, the team menu (or `--team <id>`) records the Apple development team that signs its runner (`OFFSIDER_IOS_TEAM_ID` naming another team exits 64); an older Offsider refuses a list holding a team or Metro ports, so after a downgrade run `add` again. An iPhone or iPad is always driven inside one app, as [Physical iPhones and iPads](ios-devices.md) says.
- Until a device is allowed, every command that names it exits 7 with `device_not_allowed` and sends it nothing: an iPhone is refused before any `devicectl` call, and a phone after reading only the adb server's own device list. `devices` leaves such rows out and says how many on stderr; `--physical` lists them for a person. `doctor --device` reports one failing `device.policy` check and runs no device checks. A USB device that reports an emulator's serial (`emulator-5554`) is refused too.
- A physical device must be named with `--device` on every command. `OFFSIDER_DEVICE` never names one: a command that would use it that way exits 64.
- Every command that drives an allowed device prints one line to stderr first. A person sees it dim: `🔐  Driving <name> · allowed until 15:13 · com.example.app only`. An agent, and any run with `--json`, reads the full line: `Offsider: driving physical iPhone or iPad "<name>" (<ID>), allowed until <time> ... offsider devices remove --device <ID> withdraws it.`
- `status` needs no terminal and prints JSON with `--json`, written after `status` or before it (`devices --json status`), as `add` and `remove` take theirs; with `--device` it exits 7 unless that device is allowed. `remove` needs no terminal, since it only takes access away: on a terminal it lists the allowed devices to choose from, and without one it needs `--device` (exit 64 otherwise). For an iPhone or iPad whose runner this Mac built, it asks on a terminal whether to uninstall the runner too, and otherwise prints the `session stop --clean` command. `add`, `remove` and `status` take none of the list's filters: `--platform`, `--physical` or `--booted` beside them, before or after their name, exits 64 with the `offsider devices` command that lists.
- The list is `~/.config/offsider/allowed-devices.json` (mode 0600 in a 0700 folder, written atomically under a lock), found from the password database, never `HOME` or `XDG_CONFIG_HOME`. A file that does not parse strictly counts as empty. The exception is an entry a newer Offsider wrote, with a key this build does not know: only that device is refused (`device_not_allowed`, `newer_entry` in `devices status --json` and `doctor`, saying to update Offsider), and every other device carries on. The key may be a limit this build cannot read, so the entry is never used without it, and `add` or `remove` for other devices writes it back as it came.
- `add` and `remove` seal the file: they store its SHA-256 in a login Keychain item (service `com.mpalmes.offsider.devices`, never synchronised). An edit made any other way refuses every device until a person runs `add` again. The seal turns a quiet file edit into a deliberate Keychain write; a hostile process running as you can still delete and re-add that item. Only managed preferences are beyond such a process.
- An administrator can set a ceiling with a configuration profile (MDM) in the domain `com.mpalmes.offsider`: `allowPhysicalDevices` (false refuses every physical device), `allowedDeviceIDs`, `allowedBundleIDs`, `deniedBundleIDs` (apps Offsider never signs in to or drives on any platform; an entry ending in `.` is a prefix, such as `com.example.vault.`) and `allowTestDevices` ([Test devices](#test-devices)). Offsider honours only forced (managed) values, so `defaults write` changes nothing, and a forced key of the wrong type refuses every physical device. The managed ceiling and your allow-list must both say yes.
- Offsider reads the list, the seal and managed preferences only when a command names a physical device, once per process. `credential add` on a terminal reads the list file alone (no seal, so no Keychain prompt) to decide whether to ask about phones; `login` still checks the sealed list.

## Test devices

For a phone or tablet kept only for testing, with no personal data and no personal account on it. A person can let agents drive all of it, so a hands-off run never stops at a permission prompt.

```bash
offsider devices add --device <ID> --test-device
```

Or choose "Test device: whole device" under "How will you use it?", then answer "Anything personal on it?" with "No, nothing personal". "Yes, stop" comes first and chosen, and saves nothing. It lasts until removed, and Touch ID or your password confirms as usual, its box saying nothing personal is on it. Nothing checks what is on the device: this is your word that it holds nothing of yours, so never choose it for a phone you use. Without a terminal, `add` exits 1 with `person_required`, so an agent cannot choose it.

What it changes:

- Any app may be driven: Safari, Settings, the home screen and the rest. `--app` is optional, and without it commands read and drive what is in front, so a system alert or sheet shows in `describe-ui` and can be tapped. On an Android phone, `--app` and `login` still hold their command to that app, so a saved password never reaches what comes up over it.
- There is no front-app check, so commands skip that round trip, and `logs` on an Android phone may read the whole log.
- On an iPhone or iPad the screen sleeps when the session goes idle or `session stop` ends it, and the next command wakes it ([Screen sleep and wake](ios-devices.md#screen-sleep-and-wake)).
- `./test-runner.sh --ios-device` and `--android-phone` accept it in place of a pinned playground.

What stays refused:

- Typing a passcode, pairing, tapping Trust, driving over Wi-Fi, and registering the device with a team. Offsider never does these on any device.
- `devices add`, `runner build --register-device`, `--no-mask-secure` and `describe-ui --raw-source` still need a person.
- `login` and `credential` still refuse browsers and system apps, so a saved login never goes into one.
- A saved login needs no `--devices any` and no Touch ID here, on an iPhone, iPad or Android phone: `--confirm` is not asked on a test device either. `wake --unlock` asks for no Touch ID here. On any other phone both ask each time.
- `permission` on an iPhone or iPad, which iOS offers no way to do: tap the prompt instead.

It shows on every command: `🔐  Driving <name> · allowed until you remove it · test device, whole device`, and in full for an agent. `devices status` marks its row with 🧪, and `--json` adds `"testDevice": true`.

On a Mac with any forced key in `com.mpalmes.offsider`, a test device is a plain Any app allowance until an administrator forces `allowTestDevices` to true. A forced `allowedBundleIDs` or `deniedBundleIDs` turns it off even then, so a list always wins. `devices status` says why (`testDeviceOff` in `--json`), the menu does not offer the row, and `--test-device` exits 1 with `app_not_allowed`.

An Offsider older than this one refuses a list holding a test device, as it does any key it does not know. To go back, run `devices add --device <ID>` and choose an app, which replaces the entry.
