# Android emulators and phones

## Devices

- `offsider list-devices` shows running emulators and USB phones by serial and shut-down AVDs by name; `--json` prints `{"version": 1, "devices": [{id, platform, state, name, osVersion, deviceType, kind, connection}]}`, where `kind` is `simulator`, `emulator`, `avd` or `physical` and `connection` is `usb` for a phone, else null.
- Start an emulator with `DEVICE=$(offsider boot <AVD>)`; add `--headless` to hide the window. Never start emulators with `emulator -port` or `-grpc` yourself: Offsider then falls back to slower adb-only input.
- `export OFFSIDER_DEVICE=<serial or AVD name>` binds the shell's commands to one device; `--device` still wins, and `doctor` prints the binding.
- Coordinates, frames and `--delta` are in dp; take them from `describe-ui` as usual.

## USB phones

- Never choose a `physical` device yourself: drive a phone only when the user names its serial.
- An `Unauthorised` phone needs the user to unlock it and accept the "Allow USB debugging?" prompt; never try to automate that. `Unsupported` rows are Wi-Fi or TCP adb connections, which Offsider refuses.
- On a phone everything runs over adb. `boot`, setting a `posture`, `stream-video --format bgra` and non-ASCII plain `type` are emulator-only: use `type --replace` for non-ASCII text and `--format mjpeg` for streams. `biometric` is refused on a phone.
- On a phone, input goes through `input` unless the command already started the helper to read the screen (a selector tap, `type --replace`); screenshots use `screencap -p`. Starting the helper costs 0.3 to 0.4 s, more than it saves on plain input, so these defaults are the fast path; do not set the variables below to speed a phone up.
- `OFFSIDER_ANDROID_INPUT=helper` forces input through the helper (an error, with a hint, when it cannot start) and `input` never uses it. `OFFSIDER_ANDROID_CAPTURE=raw` or `helper` encodes raw pixels on the Mac, falling back to `screencap -p`; `screencap` is the default. Both apply to an emulator without gRPC too.
- While the helper carries input, the phone reports an accessibility service as enabled for that command, as it does for screen reads. Separate `touch --down` and `touch --up` commands always use `input motionevent`.
- Offsider never sets `adb reverse` on a phone; ask the user before running it.
- A phone's screen sleeps and locks when it times out. For long runs ask the user before running `offsider stay-awake on --device <serial>`; after a reboot or unplug it needs unlocking again (`guide device-state`).

## The helper

- Screen reads (`describe-ui`, selectors, `--wait-timeout`, `--verify`, `slider`, `type --replace`) go through a small UiAutomation helper that Offsider starts on the device for one command (input and screenshots start it only when `OFFSIDER_ANDROID_INPUT` or `OFFSIDER_ANDROID_CAPTURE` is `helper`): about 0.3 s per `describe-ui` and 1 to 1.5 s per verified tap on a quiet Mac, slower when the Mac is busy. Poll and verify as on iOS.
- While a command reads the screen, the device reports an accessibility service as enabled, which some apps react to.
- A "found no window" error while an activity starts is retried by `--wait-timeout` and `tap --verify`.
- With `OFFSIDER_TIMINGS=1`, stderr shows where a command spent its time (`helper-launch`, `helper-dump`, `helper-inject`, `helper-capture`, `capture-encode`, `adb-shell`, `grpc-call` and more), one `offsider timing: <phase> <n> ms` line per phase.
- "Another UiAutomation client is connected" means Appium, Maestro, `uiautomator`, an instrumentation test or Layout Inspector holds Android's single UiAutomation connection. Offsider never reads around it: ask the user to stop that client, then retry.
- "An earlier Offsider helper (pid N) still holds UiAutomation" usually means another Offsider command is still running on the same emulator. Run commands on one emulator one at a time; the helper exits within 10 s, or run the `adb -s <serial> shell kill <pid>` command the message gives.
- A `Warning:` that the UiAutomation helper is unavailable means Offsider fell back to `uiautomator`: reads take about 2 s, the tree has no keyboard root and no slider values, and `slider` fails. Pass the reason in the warning on to the user.

## The tree

- The app window is the `application` root, labelled with its window title (such as `Settings`); while the keyboard is up, a second root with role `keyboard` follows it. Status and navigation bars are not in the tree, and nodes the user cannot see are left out.
- Sliders and progress bars report `value` as a percentage of their range (`"25%"`, `"39.95%"`), and a partly checked checkbox reports `"2"`. A Jetpack Compose `testTag` is the `id` when the node has no resource id.
- Alerts show upper-case button text (`DELETE`, `CANCEL`) with ids `android:id/button1` and `android:id/button2`; `--id button1` matches through the `:id/` suffix.
- `# the device stopped listing nodes at its limit` at the end of `describe-ui --summary` means the tree itself is incomplete.

## Input

- `slider` sets the value through the accessibility progress action, falling back to a drag. A control with coarse steps stops at the nearest step and says so, for example `Slider set to 78 (the nearest step to 78.25)`. Apps that act only when a drag ends (React Native `onSlidingComplete`) may miss the change: then `drag` on the track and read the app's own readout with `describe-ui`.
- `type` sends ASCII as key events; text with any other character is pasted through the emulator's clipboard, which Offsider restores afterwards. On an emulator without gRPC, `type` accepts ASCII only. Type non-ASCII secrets with `type --replace`.
- `type --replace` sets the focused field's text in one accessibility action: any Unicode works, even without gRPC, but key handlers such as `onKeyPress` do not run. A single trailing newline is pressed as Return afterwards; other newlines become line breaks. "type --replace needs a focused text field" means nothing has input focus: tap the field first. A `Warning:` that Offsider clears the field with Ctrl+A and Delete means it could not set the text in one step; it then clears the field with keys and types the text as `type` would.
- `offsider button back` presses the hardware back button. Android buttons are `back`, `app-switch`, `home`, `lock` (the power key), `volume-up` and `volume-down`.
- `stream-video --format bgra` sends a frame only when the screen changes.
