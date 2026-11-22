# Managed Macs

A configuration profile sets a ceiling on which phones, iPhones and iPads Offsider may drive on a Mac, and which apps. It forces keys in the domain `com.mpalmes.offsider`, and Offsider honours a key only while macOS reports it forced (`CFPreferencesAppValueIsForced`), so a plain `defaults write` changes nothing. Unmanaged Macs see no difference.

## Two rules

- **Both must allow it.** The profile is a ceiling over each person's allow-list ([Physical devices](device-access.md)). A device or app the profile refuses stays refused whatever the list says; where the profile says nothing, the list decides as before.
- **Fail closed.** A forced key of the wrong type, or a forced key this build does not know, refuses every physical device, and `devices status` names the key. Keys starting `Payload`, which some MDM tools leave beside the settings, are ignored. A profile that is wrong never opens anything up.

## When a key takes effect

Each command reads the policy once, so a profile installed or removed takes effect on the next command. A running iPhone or iPad session broker reads it again every 30 s, and when the device is no longer allowed it ends the screen stream, releases any held touch, key or button and stops.

## Keys

| Key | Type | When forced |
| --- | --- | --- |
| `allowPhysicalDevices` | boolean | `false` refuses every phone, iPhone and iPad. `true` sets no limit beyond each person's allow-list. |
| `allowedDeviceIDs` | array of strings | Only these devices: iPhone and iPad UDIDs (any case) and Android serials (exact). An empty array allows none. |
| `allowedBundleIDs` | array of strings | Apps on a physical device are limited to these exact ids: `devices add` offers no other, pins outside the list do nothing, and an "Any app" allowance reaches only these. An empty array allows none. |
| `deniedBundleIDs` | array of strings | Apps Offsider never signs in to on any platform (`login`, `credential`), and never drives on a phone, iPhone or iPad. An entry ending in `.` is a prefix (`com.example.vault.`). iOS ids match without case, Android ids exactly. |
| `allowTestDevices` | boolean | While any key is forced, a test device is a plain "Any app" allowance unless this is `true`, and even then only while neither app list is forced. |

There is no separate switch for "no apps": force `allowedBundleIDs` to an empty array.

## What a managed user sees

In a terminal, `offsider devices status` says `Managed policy blocks every device.` or `Managed policy blocks some devices.` Piped, as an agent reads it (`offsider devices status | cat`), it starts with a `Managed policy:` line naming each forced key's limit, and `--json` has the same under `managed`.

A device the profile refuses exits 7 (`device_not_allowed`), and an app it refuses exits 1 (`app_not_allowed`), with nothing sent to the device either way. The message names your organisation and the key:

```text
Your organisation turns off phones on this Mac (allowPhysicalDevices).
Your organisation does not list this device (allowedDeviceIDs).
Your organisation does not list <app> (allowedBundleIDs).
Your organisation denies <app> (deniedBundleIDs).
Your organisation's setting could not be read, so Offsider refuses every phone (<key>).
Your organisation sets a setting this Offsider does not know, so it refuses every phone (<key>).
```

A device refusal says to ask the administrator of this Mac, and an unknown key also says to update Offsider. `devices status --json --device <ID>` and `doctor --device <ID> --json` carry the refusal (`managed_off`, `managed_not_listed`, `managed_unreadable`, `managed_unknown_key`) and its `key`. The `devices add` app menu never offers an app the profile refuses.

On a test device the profile keeps from being driven whole, `devices status` and the commands that need a whole device (`alert`, and a guard rule that asks) name the key instead of calling the phone in personal use, and say to ask the administrator:

```text
Your organisation does not allow test devices (allowTestDevices).
Your organisation limits the apps on this Mac (allowedBundleIDs).
```

## What it does not cover

- **Simulators and emulators.** Only `deniedBundleIDs` reaches them, on `login` and `credential`.
- **The agent itself.** Its own permission rules and its harness's managed settings stay with your agent's vendor.
- **Installing Offsider.** Use your endpoint tool to allow or block the `offsider` binary.
- **Masks and log redaction.** They are on by default. When an agent asks to turn one off, a person at the Mac confirms with Touch ID or the login password; a person at their own terminal is not asked.

## A sample profile

This one allows physical devices for one app and denies a family of apps by prefix. Install it through your MDM's custom settings payload for `com.mpalmes.offsider` (Jamf, Kandji, Mosyle and the rest deliver one), or double-click it on a test Mac. Replace the UUIDs with your own (`uuidgen`).

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

For "no phones at all", set `allowPhysicalDevices` to `<false/>` and drop the two arrays.

## Verify it

1. `defaults read com.mpalmes.offsider` prints the forced keys: `defaults` composes managed values into what it shows.
2. `offsider devices status | cat` starts with `Managed policy:` and names each one.
3. `offsider devices status --json | jq .managed` shows `"present": true` and each forced key.
4. On a device the profile does not allow, `offsider doctor --device <ID>` fails `device.policy` with the refusal above, and any device command exits 7 with nothing sent.
5. The negative check: on a Mac with no profile, `defaults write com.mpalmes.offsider allowPhysicalDevices -bool false`, then `offsider devices status | cat` still says `Managed policy: none.`, because the key is set but not forced. Then `defaults delete com.mpalmes.offsider allowPhysicalDevices`.
6. The wrong-type check: a profile forcing `allowPhysicalDevices` as a string makes `offsider devices status | cat` say `allowPhysicalDevices unreadable, so every physical device is refused`.

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

- The keys are read in `Sources/OffsiderCore/Policy/ManagedDevicePolicy.swift`, only as forced values.
- The decisions (both must allow, fail closed, what a test device may do) are in `Sources/OffsiderCore/Policy/PhysicalDevicePolicy.swift`.
- The built-in deny-list and `deniedBundleIDs` matching are in `Sources/OffsiderCore/Login/SystemAppDenyList.swift`.
- A new key adds a field and a parse arm in `ManagedDevicePolicy`, its decision, a `devices status` line, a row in the table above and a test. `Tests/ManagedDocsTests.swift` fails when a key `ManagedDevicePolicy` reads is missing from this page.
