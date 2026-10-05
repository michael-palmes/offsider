# Coming from idb, Maestro or agent-device

Status: **same** (same name and meaning), **renamed** (exists under another name or shape), **missing** (not in Offsider) or **by design** (deliberately not Offsider's job). Every Offsider command below takes `--device <DEVICE_ID>`; the other tools' own options are described in words.

## idb

| idb | Offsider | Status |
| --- | --- | --- |
| `idb list-targets` | `list-devices` | renamed |
| `idb ui describe-all` | `describe-ui` (`--summary` for agents) | renamed |
| `idb ui describe-point X Y` | `describe-ui --point X,Y` | renamed |
| `idb ui tap X Y` | `tap -x X -y Y` | renamed |
| `idb ui tap X Y` with a hold duration | `touch -x X -y Y --down --up --delay S` | renamed |
| `idb ui swipe X1 Y1 X2 Y2` | `swipe --start-x X1 --start-y Y1 --end-x X2 --end-y Y2` | renamed |
| `idb ui text "..."` | `type '...'` | renamed |
| `idb ui key CODE` | `key CODE` | same |
| `idb ui key-sequence` | `key-sequence --keycodes` | same |
| `idb ui button HOME` | `button home` | renamed |
| `idb screenshot` | `screenshot` | same |
| `idb record video` | `record-video` | renamed |
| `idb video-stream` | `stream-video` | renamed |
| `idb log` | `logs` | renamed |
| `idb approve` | `permission grant <service> --app <id>` | renamed |
| `idb revoke` | `permission revoke <service> --app <id>` | renamed |
| `idb set-location` | none | missing |
| `idb install`, `launch`, `terminate`, `uninstall`, `list-apps` | `xcrun simctl` | by design |
| `idb open URL` | `xcrun simctl openurl` | by design |
| `idb boot` | `xcrun simctl boot` (Offsider `boot` starts Android emulators) | by design |
| `idb file`, `crash`, `xctest`, `instruments`, `contacts`, `clear-keychain` | Xcode and `simctl` tools | by design |
| `idb_companion` | none: Offsider links idb's frameworks in process | by design |

## Maestro

| Maestro | Offsider | Status |
| --- | --- | --- |
| `tapOn` by id or text | `tap --id <id>` or `tap --label '<text>'` (exact, with quote and space folding) | renamed |
| `longPressOn` | `touch -x X -y Y --down --up --delay S` | renamed |
| `inputText` | `type '<text>'` | renamed |
| `eraseText` | `type --replace ''` | renamed |
| `pressKey` | `key <code>`, `button home` or `button back`, or a trailing newline in `type` for Enter | renamed |
| `back` | `button back` (Android) | renamed |
| `hideKeyboard` | none | missing |
| `swipe` | `swipe`, or a `gesture` preset | same |
| `scroll` | `gesture scroll-up` | renamed |
| `assertVisible` | `assert --id <id>` or `wait --id <id>` | renamed |
| `extendedWaitUntil` | `wait` with `--timeout` | renamed |
| `waitForAnimationToEnd` | `wait --settled` | renamed |
| `takeScreenshot` | `screenshot` | renamed |
| `launchApp` | `xcrun simctl launch` or `adb shell am start` | by design |
| `openLink` | `xcrun simctl openurl` or `adb shell am start` | by design |

## agent-device

| agent-device | Offsider | Status |
| --- | --- | --- |
| `open`, `close` | `xcrun simctl` or `adb` | by design |
| `snapshot` | `describe-ui --summary` | renamed |
| `press` | `tap` | renamed |
| `fill` | `tap` on the field, then `type --replace '<text>'` | renamed |
| `screenshot` | `screenshot` | same |
| `doctor` | `doctor` | same |
| `@e` element refs | `--id`, `--label` and `--value` selectors: Offsider keeps no session state | by design |
| `mcp` | none: Offsider is a CLI any agent runs through its shell | by design |
| `device status`, `release` | none: the device lock is taken and released automatically | by design |
| iOS device runner over usbmux | `runner status`, `runner stop`: Offsider builds and signs its own runner, USB only | renamed |
