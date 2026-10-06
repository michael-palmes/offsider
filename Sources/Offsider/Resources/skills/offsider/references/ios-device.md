# Physical iPhones and iPads

## Choosing and preparing the device

- Never choose a `physical` device yourself: drive an iPhone or iPad only when the user names its UDID, and pass that UDID to `--device`.
- USB only. A device on Wi-Fi exits 7 with `device_not_wired`: ask the user to connect its cable. Offsider never pairs a device or accepts a prompt on it.
- The user prepares the device once: unlock it and tap Trust, turn on Developer Mode (Settings > Privacy & Security), and for input turn on Settings > Developer > UI Automation.
- `offsider list-devices` shows the device with `kind` `physical`, `connection` `usb` or `network`, and a state: Booted (ready), Wireless, Untrusted, Developer Mode off, Preparing, Reconnecting or Unavailable. A hint on stderr says what to do for each problem state.
- Run `offsider doctor --device <UDID> --json` first. Its `ios-device.*` checks cover Xcode, CoreDevice, the listing, the connection, trust, Developer Mode, the developer disk image, the tunnel, the lock state, HID input (`hid` round-trips a barrier on the button socket), UI Automation, the session broker, usbmuxd and runner signing. `--fix` only mounts the developer disk image, on the device `--device` names or, without it, the one `OFFSIDER_DEVICE` names.
- iOS does not report UI Automation, so `ios-device.ui-automation` is a skip naming the Settings path: ask the user to check it. `ios-device.session` is a skip when no broker is running; doctor never starts one.
- The device must stay unlocked. A locked device refuses input with exit 7 `device_locked`: ask the user to unlock it. Offsider never types an iPhone passcode, and `wake`, `stay-awake` and `unlock-code` are Android only.
- Ask the user to set Settings > Display & Brightness > Auto-Lock to Never while you drive the device: once the screen dims, the next press may only brighten it.

## The session broker (Xcode 27)

- On an Xcode 27 host (CoreDevice 636 or later), the first screenshot or input on a device starts a session broker in the background, about 3 s. It holds the device's screen stream, its UniversalHID touchscreen and keyboard, and its hardware button socket, one broker per device.
- With it running: `tap` about 140 ms, `type` about 80 ms, `button home` about 160 ms, a 0.3 s `swipe` about 370 ms and `screenshot` about 230 ms.
- The device shows its screen-sharing indicator while the broker runs. It stops after `OFFSIDER_IOS_SESSION_IDLE` seconds without a command (default 300), or when the device goes.
- `offsider session status --device <UDID> --json` shows the broker and the runner without starting either. When you are done with the device, run `offsider session stop --device <UDID>`: it stops both and clears the indicator. `runner status` and `runner stop` cover the runner alone.
- The broker needs a logged-in desktop session on the Mac, not plain `ssh`. Without one, screenshots use `devicectl` (about 2.3 s, with a notice) and input falls back to the runner.
- Exit 1 `hid_broker_failed` means the broker failed and nothing was sent: retry once, then run `offsider session stop --device <UDID>` and retry. `input_outcome_unknown` means the broker stopped after the input was sent: check the screen before resending.

## What works where

| | Xcode 27, broker | Xcode 27, no broker | Xcode 26 |
| --- | --- | --- | --- |
| `list-devices`, `doctor`, `appearance`, `content-size`, `orientation` | yes | yes | yes |
| `screenshot` | stream | `devicectl` | `devicectl` |
| `describe-ui`, `wait`, `assert` (runner) | yes | yes | yes |
| Element and coordinate `tap`, `swipe`, `button home` | broker | runner | runner |
| Plain ASCII `type` | broker | runner | `xcode_too_old` |
| Non-ASCII `type`, `type --replace` | runner | runner | runner |
| `key`, `key-sequence`, `key-combo`, `touch`, `gesture`, `drag`, `lock`, `side-button`, `siri` | broker | refused | `xcode_too_old` |

- `xcode_too_old` exits 9; its hint is to install Xcode 27 for HID input. The device can run iOS or iPadOS 26 or 27.
- `apple-pay` is refused on a device: press `button side-button` twice instead.

## The runner and `--app`

- The accessibility tree comes from a small XCUITest runner app. On first use Offsider builds it with `xcodebuild` (about a minute, with a line on stderr) and caches it under `~/Library/Caches/offsider/runner/`.
- It is signed with the team in `OFFSIDER_IOS_TEAM_ID`, or with the one team signed in to Xcode. With none, or several, the command exits 9 with `team_missing`: ask the user for the team ID. A build that fails exits 1 with `runner_build_failed`, and its hint names the build log.
- The runner keeps running in the background, reached over USB through usbmuxd with a per-session token, and stops after `OFFSIDER_IOS_RUNNER_IDLE` seconds without a request (default 300).
- XCTest reads one named app at a time. `describe-ui`, `tap`, `wait` and `assert` take `--app <bundle-id>` on a device; later commands remember it. Without it the runner reads the app in front when it can tell which that is, else the Home Screen. An `--app` that is not in front fails: open the app, or leave out `--app`.
- An iPad app in a Stage Manager window reports frames relative to its window, so element taps (`tap --id`, `tap --label`) exit 1 with `not_supported`: ask the user to make the app full screen. Coordinate taps, screenshots and the tree still work.

```bash
offsider describe-ui --summary --app <BUNDLE_ID> --device <UDID>
offsider tap --id <identifier> --app <BUNDLE_ID> --verify --device <UDID>
offsider session status --device <UDID> --json
offsider session stop --device <UDID>
```

## Screenshots and settings

- `screenshot` takes the broker's latest stream frame, about 230 ms; without the broker it uses `devicectl device capture screenshot`, about 2.3 s. The first one after the broker starts waits for the stream to settle, about 1.5 s more. `--verify` may take several screenshots, so prefer `wait` or `assert` when the tree shows the effect.
- Screen comparisons (`--verify`, `wait` screen checks, `screenshot --compare`) average 8 by 8 pixel blocks and ignore drifts of a few colour units, the stream's compression noise; a caret, a toggle or new text still counts as a change. `screenshot --compare` counts changed pixels, and `--diff-output` marks them, by those blocks too.
- `appearance` and `content-size` go through `devicectl`; set them back when done. `orientation` waits for the screen to turn, which needs the device awake and unlocked and an app that supports the orientation.

## Refused on a device

`permission`, `status-bar`, `biometric`, `shake`, `posture`, `stream-video --format bgra`, `logs`, `rn prepare`, `wake`, `stay-awake`, `unlock-code` and a `touch --down` without `--up` exit 1 with `not_supported`, most naming an alternative; `boot` and `button apple-pay` exit 64. Use an iOS simulator for permissions, the status bar, biometrics and logs, and install and launch apps with `xcrun devicectl`. `record-video` and the other `stream-video` formats build each frame from a screenshot, so their frame rate is low.

## Errors

| Reason | Exit | What to do |
| --- | --- | --- |
| `device_not_wired` | 7 | Ask the user to connect the cable |
| `device_untrusted` | 7 | Ask the user to unlock the device and tap Trust |
| `developer_mode_off` | 7 | Ask the user to turn on Developer Mode and restart |
| `device_preparing` | 7 | Wait for Xcode, then retry |
| `device_locked` | 7 | Ask the user to unlock the device |
| `ui_automation_off` | 7 | Ask the user to turn on Settings > Developer > UI Automation |
| `xcode_too_old` | 9 | The command needs Xcode 27; use a runner command or ask the user |
| `team_missing` | 9 | Ask for the team ID for `OFFSIDER_IOS_TEAM_ID` |
| `usbmux_unavailable` | 9 | Ask the user to reconnect the cable |
| `runner_build_failed` | 1 | Read the build log the hint names |
| `runner_unavailable` | 1 | Nothing was sent; retry once, then run `doctor` |
| `hid_broker_failed` | 1 | Nothing was sent; retry once, then `session stop` and retry |
| `input_outcome_unknown` | 1 | Check the screen before resending |

## End-to-end tests

`make e2e-ios-device`, with `OFFSIDER_IOS_DEVICE_E2E=1`, `OFFSIDER_IOS_DEVICE=<UDID>` and `OFFSIDER_IOS_TEAM_ID` set, runs the device suites on that one device, which must be on its cable, unlocked and with UI Automation on. Run it only when the user asks, on the device they name, and run `offsider session stop --device <UDID>` afterwards.
