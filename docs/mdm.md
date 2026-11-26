# Managed Macs

A configuration profile sets a ceiling on which phones, iPhones and iPads Offsider may drive on a Mac, which apps, and what a person or an agent may loosen. It forces keys in the domain `com.mpalmes.offsider`, and Offsider honours a key only while macOS reports it forced (`CFPreferencesAppValueIsForced`), so a plain `defaults write` changes nothing. Unmanaged Macs see no difference.

## Two rules

- **Both must allow it.** The profile is a ceiling over each person's allow-list ([Physical devices](device-access.md)). A device or app the profile refuses stays refused whatever the list says; where the profile says nothing, the list decides as before.
- **Fail closed.** A forced key of the wrong type, or a forced key this build does not know, refuses every physical device, and `devices status` names the key. A ceiling of the wrong type also holds at its strictest value where no phone is named: a mistyped `forceMasks` keeps masks on. Keys starting `Payload`, which some MDM tools leave beside the settings, are ignored. A profile that is wrong never opens anything up.
- **Read where it applies.** A device key is read when a command names a phone, iPhone or iPad. A ceiling is read only by the flag or command it governs, so a simulator or emulator command that loosens nothing reads no managed key.

## When a key takes effect

Each command reads the policy once, so a profile installed or removed takes effect on the next command. A running iPhone or iPad session broker reads it again every 30 s, and when the device is no longer allowed it ends the screen stream, releases any held touch, key or button and stops.

## Keys

| Key | Type | When forced |
| --- | --- | --- |
| `allowPhysicalDevices` | boolean | `false` refuses every phone, iPhone and iPad. `true` sets no limit beyond each person's allow-list. |
| `allowedDeviceIDs` | array of strings | Only these devices: iPhone and iPad UDIDs (any case) and Android serials (exact). An empty array allows none. |
| `allowedBundleIDs` | array of strings | Apps on a physical device are limited to these exact ids: `devices add` offers no other, pins outside the list do nothing, and an "Any app" allowance reaches only these. An empty array allows none. |
| `deniedBundleIDs` | array of strings | Apps Offsider never signs in to on any platform (`login`, `credential`), and never drives on a phone, iPhone or iPad. An entry ending in `.` is a prefix (`com.example.vault.`). iOS ids match without case, Android ids exactly. The built-in deny-list names common apps, not categories: list any other messaging, banking or password manager app here. |
| `allowTestDevices` | boolean | While any key is forced, a test device is a plain "Any app" allowance unless this is `true`, and even then only while neither app list nor `requirePinnedApps` is forced. |
| `forceMasks` | boolean | `true` refuses, for a person and an agent alike, every way to drop a mask or redaction: `--no-mask-secure` and `OFFSIDER_MASK_SECURE=0` on `screenshot`, `batch` and a held touch's captures, `--unmasked` on `record-video` and `stream-video`, `describe-ui --raw-source`, and `--no-redact` on `logs` and `rn logbox`. |
| `maxAllowanceDays` | integer, 1 to 3650 | The longest an allowance lasts. `devices add` refuses a longer `--expires` and `never`, offers nothing longer, and saves a default at the cap. An allowance already saved ends that many days after it was added. |
| `allowSavedLogins` | boolean | `false` refuses `login`, and `credential add`, `describe` and `join`, on every device. `credential status`, `remove` and `signed-out` still run, and `devices add` no longer offers to save a login. |
| `allowFileInput` | boolean | `false` refuses `--allow-path` on `type --file` and `batch` for a file `--file` protects (`~/.ssh`, `.env` and the like). Other files are typed as before. |
| `allowMetroReverse` | boolean | `false` stops `rn open` setting an `adb reverse` on a phone, or using one it set earlier, and `devices add` refuses `--metro-port`. A reverse you set yourself is untouched. |
| `allowRunnerRegistration` | boolean | `false` refuses `runner build --register-device`, and every runner build drops `-allowProvisioningUpdates`, so Xcode creates no App ID, profile or device record: the build signs only with profiles already on the Mac. |
| `allowedTeamIDs` | array of strings | Only these Apple teams (any case) may sign the runner: `devices add` offers and accepts no other, and a build for another team, from the allowance or `OFFSIDER_IOS_TEAM_ID`, is refused. An empty array allows none. |
| `requirePinnedApps` | boolean | `true` limits each phone to named apps: `devices add` offers no "Any app" or "Any app and all logs" and refuses a test device, and an allowance that names no app is refused until a person adds it again with one. |
| `allowUnlockCodes` | boolean | `false` refuses `unlock-code set` and `wake --unlock`. `unlock-code status` and `remove` still run. |
| `allowPhonePermissionChanges` | boolean | `false` refuses `permission grant`, `revoke` and `reset` on a phone, iPhone or iPad. `permission show`, and simulators and emulators, are untouched. |

There is no separate switch for "no apps": force `allowedBundleIDs` to an empty array.

A JSON Schema of every key, for the custom schema field of Jamf Pro's Application and Custom Settings payload and tools that read the same format, is in [mdm/com.mpalmes.offsider.schema.json](mdm/com.mpalmes.offsider.schema.json).

## What a managed user sees

In a terminal, `offsider devices status` says `Managed policy blocks every device.` or `Managed policy blocks some devices.`, and lists the ceilings in force after `Your organisation sets:`. Piped, as an agent reads it (`offsider devices status | cat`), it starts with a `Managed policy:` line naming each forced key's limit, and `--json` has every key under `managed`, `null` when not forced. `offsider doctor` ends with `managed.policy`, which lists each forced key as `key=value` and fails on one Offsider cannot read or does not know.

A device the profile refuses exits 7 (`device_not_allowed`), and an app it refuses exits 1 (`app_not_allowed`), with nothing sent to the device either way. The message names your organisation and the key:

```text
Your organisation turns off phones on this Mac (allowPhysicalDevices).
Your organisation does not list this device (allowedDeviceIDs).
Your organisation does not list <app> (allowedBundleIDs).
Your organisation denies <app> (deniedBundleIDs).
Your organisation's setting could not be read, so Offsider refuses every phone (<key>).
Your organisation sets a setting this Offsider does not know, so it refuses every phone (<key>).
```

A ceiling's refusal exits 1 (`managed_policy`), for a person as for an agent, before anything is captured, read, saved or sent, and no Touch ID is asked for:

```text
Your organisation keeps masks and redaction on (forceMasks). Nothing was captured or read. Ask the administrator of this Mac.
Your organisation turns off saved logins on this Mac (allowSavedLogins). Nothing was saved. Ask the administrator of this Mac.
Your organisation limits an allowance to 7 days (maxAllowanceDays). Nothing was saved. Ask the administrator of this Mac.
Your organisation does not list team <team> (allowedTeamIDs). The runner was not built. Ask the administrator of this Mac.
```

An allowance the cap has ended, or one that names no app under `requirePinnedApps`, exits 7 (`device_not_allowed`) with the key, and a person lifts it by running `offsider devices add` again (`expired_by_policy` and `pins_required` in `devices status --json`).

A device refusal says to ask the administrator of this Mac, and an unknown key also says to update Offsider. `devices status --json --device <ID>` and `doctor --device <ID> --json` carry the refusal (`managed_off`, `managed_not_listed`, `managed_unreadable`, `managed_unknown_key`) and its `key`. The `devices add` app menu never offers an app the profile refuses.

On a test device the profile keeps from being driven whole, `devices status` and the commands that need a whole device (`alert`, and a guard rule that asks) name the key instead of calling the phone in personal use, and say to ask the administrator:

```text
Your organisation does not allow test devices (allowTestDevices).
Your organisation limits the apps on this Mac (allowedBundleIDs).
```

## What it does not cover

- **Driving simulators and emulators.** `deniedBundleIDs` reaches them on `login` and `credential`, and `forceMasks`, `allowSavedLogins`, `allowFileInput` and `allowUnlockCodes` hold on every device. No key turns simulators or emulators off.
- **The agent itself.** Its permission rules and its harness's managed settings stay with your agent's vendor. [Managed harnesses](agents.md#managed-harnesses) has the fragments that keep Offsider's rules in a locked-down Claude Code or Codex.
- **Installing Offsider.** Use your endpoint tool to allow or block the `offsider` binary.
- **`alert` on a test device.** It answers a system permission prompt whatever `allowPhonePermissionChanges` says; leave `allowTestDevices` unset to keep test devices off.
- **`screen-reader on` on a test device.** It grants TalkBack its notification permission whatever `allowPhonePermissionChanges` says, and `off` puts it back; leave `allowTestDevices` unset to keep test devices off.
- **A reverse or login from before the profile.** `offsider session stop --device <ID>` removes a reverse Offsider set, and `offsider credential remove` a saved login; the ceiling stops new ones and stops Offsider using the old.

## A sample profile

This one allows physical devices for one app, denies a family of apps by prefix, keeps masks on, caps an allowance at seven days, limits the runner to one Apple team and turns saved unlock codes off. Install it through your MDM's custom settings payload for `com.mpalmes.offsider` (Jamf, Kandji, Mosyle and the rest deliver one), or double-click it on a test Mac. Replace the UUIDs with your own (`uuidgen`).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>com.apple.ManagedClient.preferences</string>
      <key>PayloadIdentifier</key>
      <string>com.example.offsider.settings</string>
      <key>PayloadUUID</key>
      <string>00000000-0000-0000-0000-000000000001</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadContent</key>
      <dict>
        <key>com.mpalmes.offsider</key>
        <dict>
          <key>Forced</key>
          <array>
            <dict>
              <key>mcx_preference_settings</key>
              <dict>
                <key>allowPhysicalDevices</key>
                <true/>
                <key>allowedBundleIDs</key>
                <array>
                  <string>com.example.app</string>
                </array>
                <key>deniedBundleIDs</key>
                <array>
                  <string>com.example.vault.</string>
                </array>
                <key>forceMasks</key>
                <true/>
                <key>maxAllowanceDays</key>
                <integer>7</integer>
                <key>allowedTeamIDs</key>
                <array>
                  <string>ABCDE12345</string>
                </array>
                <key>allowUnlockCodes</key>
                <false/>
              </dict>
            </dict>
          </array>
        </dict>
      </dict>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>Offsider policy</string>
  <key>PayloadIdentifier</key>
  <string>com.example.offsider</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>00000000-0000-0000-0000-000000000002</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadScope</key>
  <string>System</string>
</dict>
</plist>
```

For "no phones at all", set `allowPhysicalDevices` to `<false/>` and drop the rest.

## Verify it

1. `defaults read com.mpalmes.offsider` prints the forced keys: `defaults` composes managed values into what it shows.
2. `offsider devices status | cat` starts with `Managed policy:` and names each one.
3. `offsider devices status --json | jq .managed` shows `"present": true` and each forced key.
4. On a device the profile does not allow, `offsider doctor --device <ID>` fails `device.policy` with the refusal above, and any device command exits 7 with nothing sent.
5. The negative check: on a Mac with no profile, `defaults write com.mpalmes.offsider allowPhysicalDevices -bool false`, then `offsider devices status | cat` still says `Managed policy: none.`, because the key is set but not forced. Then `defaults delete com.mpalmes.offsider allowPhysicalDevices`.
6. The wrong-type check: a profile forcing `allowPhysicalDevices` as a string makes `offsider devices status | cat` say `allowPhysicalDevices unreadable, so every physical device is refused`.
7. `forceMasks`: on any booted simulator, `offsider screenshot --no-mask-secure --device <ID>` exits 1 with `Your organisation keeps masks and redaction on (forceMasks).` and writes no file, from your own terminal too; without the flag the screenshot is taken as before.
8. `maxAllowanceDays`: `offsider devices status | cat` names it (`allowances last at most 7 days`), each allowed device shows an end no later than seven days after it was added, and, with a phone plugged in, `offsider devices add --device <ID> --expires never` stops with `Your organisation limits an allowance to 7 days (maxAllowanceDays).` before Touch ID.
9. `offsider doctor --json | jq '.checks[] | select(.id == "managed.policy")'` lists every forced key as `key=value`.

### Without an MDM, on a test Mac

macOS composes managed preferences from `/Library/Managed Preferences/<user>/<domain>.plist`, so a forced key can be laid down there for a quick check, as root. This route has not been checked against Offsider yet: if `devices status` still says `Managed policy: none.`, use a profile.

```bash
sudo defaults write "/Library/Managed Preferences/$USER/com.mpalmes.offsider" allowPhysicalDevices -bool false
```

```bash
sudo killall cfprefsd
```

```bash
offsider devices status
```

Remove the file to lift it, then run `sudo killall cfprefsd` again:

```bash
sudo rm "/Library/Managed Preferences/$USER/com.mpalmes.offsider.plist"
```

## For contributors

- The keys are read in `Sources/OffsiderCore/Policy/ManagedDevicePolicy.swift`, only as forced values; the ceilings and the gate that reads one key at a time are in `ManagedCeilings.swift` beside it.
- The decisions (both must allow, fail closed, what a test device may do) are in `Sources/OffsiderCore/Policy/PhysicalDevicePolicy.swift`.
- The built-in deny-list and `deniedBundleIDs` matching are in `Sources/OffsiderCore/Login/SystemAppDenyList.swift`.
- A new key adds a field and a parse arm in `ManagedDevicePolicy` or `ManagedCeilings`, its decision or gate, a `devices status` line, a row in the table above, a property in `docs/mdm/com.mpalmes.offsider.schema.json` and a test. `Tests/ManagedDocsTests.swift` fails when a key Offsider reads is missing from this page or the schema, or typed differently there.
