# Physical iPhones and iPads

## Choosing and preparing the device

- Never choose a `physical` device yourself: drive an iPhone or iPad only when the user names its UDID, and pass that UDID to `--device`.
- USB only. A device on Wi-Fi exits 7 with `device_not_wired`: ask the user to connect its cable. Offsider never pairs a device or accepts a prompt on it.
- The user prepares the device once: unlock it and tap Trust, turn on Developer Mode (Settings > Privacy & Security), and for input turn on Settings > Developer > UI Automation.
- `offsider list-devices` shows the device with `kind` `physical`, `connection` `usb` or `network`, and a state: Booted (ready), Wireless, Untrusted, Developer Mode off, Preparing, Reconnecting or Unavailable. A hint on stderr says what to do for each problem state.
- Run `offsider doctor --device <UDID> --json` first. Its `ios-device.*` checks cover Xcode, CoreDevice, the listing, the connection, trust, Developer Mode, the developer disk image, the tunnel, the lock state, HID input, UI Automation, usbmuxd and runner signing. `--fix` only mounts the developer disk image.
- A locked device refuses input with exit 7 `device_locked`: ask the user to unlock it. Offsider never types an iPhone passcode, and `wake`, `stay-awake` and `unlock-code` are Android only.

## What the Mac's Xcode allows

- Xcode 27 (CoreDevice 636 or later): every input command through CoreDevice HID, including `key`, `touch`, `gesture`, `drag`, plain `type` and the `home`, `lock`, `side-button` and `siri` buttons.
- Xcode 26: listing, `doctor`, `screenshot`, `appearance`, `content-size`, `orientation`, and through the runner the tree, `wait`, `assert`, element taps, coordinate `tap`, `swipe` and `button home`. `key`, `touch`, `gesture`, `drag`, the other buttons and plain ASCII `type` exit 9 with `xcode_too_old`; its hint is to install Xcode 27 for HID input.
- On both, non-ASCII text and `type --replace` go through the runner. The device can run iOS or iPadOS 26 or 27.
- `apple-pay` is refused on a device: press `button side-button` twice instead.

## The runner and `--app`

- The accessibility tree comes from a small XCUITest runner app. On first use Offsider builds it with `xcodebuild` (about a minute, with a line on stderr) and caches it under `~/Library/Caches/offsider/runner/`.
- It is signed with the team in `OFFSIDER_IOS_TEAM_ID`, or with the one team signed in to Xcode. With none, or several, the command exits 9 with `team_missing`: ask the user for the team ID. A build that fails exits 1 with `runner_build_failed`, and its hint names the build log.
- The runner keeps running in the background, reached over USB through usbmuxd with a per-session token, and stops after `OFFSIDER_IOS_RUNNER_IDLE` seconds without a request (default 300). `offsider runner status --device <UDID>` shows it and `offsider runner stop --device <UDID>` stops it.
- XCTest reads one named app at a time. `describe-ui`, `tap`, `wait` and `assert` take `--app <bundle-id>` on a device; later commands remember it. Without it the runner reads the app in front when it can tell which that is, else the Home Screen. An `--app` that is not in front fails: open the app, or leave out `--app`.

```bash
offsider describe-ui --summary --app <BUNDLE_ID> --device <UDID>
offsider tap --id <identifier> --app <BUNDLE_ID> --verify --device <UDID>
offsider runner status --device <UDID> --json
```

## Screenshots and settings

- `screenshot` uses `devicectl device capture screenshot`, usually under a second. `--verify` may take several captures, so it is slower than on a simulator; prefer `wait` or `assert` when the tree shows the effect.
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

## End-to-end tests

`make e2e-ios-device`, with `OFFSIDER_IOS_DEVICE_E2E=1`, `OFFSIDER_IOS_DEVICE=<UDID>` and `OFFSIDER_IOS_TEAM_ID` set, runs the device suites on that one device, which must be on its cable, unlocked and with UI Automation on. Run it only when the user asks, on the device they name.
