# Device state

Every setter here changes the device and it stays changed. Read the current value by omitting the argument, set state before launching the app, and set it back when done. `--json` on each prints one object with `version: 1`.

## Appearance and text size

- `offsider appearance light|dark --device <DEVICE_ID>` sets the appearance. On Android a reading can be `auto` or `custom` when night mode follows a schedule; setting light or dark replaces it. Apps with their own theme setting follow `appearance` only when that setting is on automatic.
- `offsider content-size <category>|reset` sets the text size: a Dynamic Type category on iOS, the matching font scale on Android; `reset` restores `large`.
- On a physical iPhone or iPad both go through `devicectl`, and `orientation` turns the screen only while the device is awake and unlocked. `permission`, `status-bar` and `biometric` are refused there: use a simulator.

## Orientation

- `offsider orientation portrait|landscape-left|landscape-right|portrait-upside-down` (or `--rotation 0|90|180|270`) waits until the screen has turned and prints the new size. A portrait-only app stays portrait and the command times out.
- It names the device turn, as Maestro does: `landscape-left` is turned anticlockwise, which UIKit and the app call interface orientation landscape-right. `orientation --json` prints `rotation`, the same number as `describe-ui` `screen.rotation`.
- On Android, Offsider turns auto-rotate off while the device is turned and restores it on `orientation portrait`: the first turn away from portrait records auto-rotate and `user_rotation` (for that boot), and portrait writes auto-rotate back. `--json` on Android adds `autoRotate {before, now, restored}` and `userRotation {before, now}` (null on iOS and when reading). Finish an Android run with `orientation portrait`. The iPhone Duo simulator refuses orientation changes.

## Permissions

- `offsider permission grant|revoke|reset <service>... --app <bundle id or package>` changes an app's permissions.
- `offsider permission services` lists the service names (`camera` and `notifications` are Android only, `photos-add`, `reminders` and `siri` iOS only); `permission show --app <id>` reads an Android app's runtime permissions.
- Android stops the app when a permission is revoked, so relaunch it.

## Status bar

`offsider status-bar override` sets a clean status bar (9:41, full battery and signal, or `--time`, `--battery`, `--wifi`, `--cellular` and more), `clear` removes it and `show` reads it.

## Biometrics

- `offsider biometric enrol|unenrol|match|no-match`. Send `match` or `no-match` only while the app shows its Face ID, Touch ID or fingerprint prompt, then check the screen: nothing confirms the app saw it.
- On iOS enrol first, and `unenrol` afterwards. On Android enrolment is manual (it needs a screen lock), and `biometric` is refused on a phone.

## Screen, stay awake and unlocking (Android)

`stay-awake`, `wake` and `unlock-code` refuse an iOS simulator or iPhone as `not_supported`: simulators never sleep or lock, and an iPhone or iPad is unlocked by hand.

- `offsider stay-awake --device <DEVICE_ID>` reads Developer options > Stay awake with the screen timeout; `on` keeps an awake screen on while the device charges (every power source) and `off` restores the timeout. It survives reboots. The output says when it has no effect: not charging, charging over a source it leaves out, or a device policy capping the timeout. Turn it on before a long run; it does not turn a dark screen on.
- `offsider wake --device <DEVICE_ID>` turns the screen on and dismisses a swipe lock screen, and sends nothing when the screen is already on and unlocked. A PIN, pattern or password lock screen stays up and exits 7 with `device_locked`: ask the user to unlock the device.
- After a boot, a device set up with a PIN, pattern or password stays locked until someone unlocks it once, and apps cannot start until then. `offsider boot <AVD>` checks this and exits 7 with `device_locked` naming the serial; `boot --json` reports `lock` (`type`, `savedCode`, `lastAttemptFailed`, `userUnlocked`, `screen`, `lockScreen`). Ask the user to unlock it, or run `wake --unlock` when `savedCode` is true and `lastAttemptFailed` false. `doctor --device <DEVICE_ID>` reports the same as `android-device.lock`, and the RAM the device sees as `android-device.memory`.
- `offsider wake --unlock --device <DEVICE_ID>` also types the PIN or password the user saved with `offsider unlock-code set --device <serial or AVD name>`, once, into the lock screen's own field only. If that code fails, Offsider will not type it again until the device is unlocked by hand or the code is saved again; never loop on it. Patterns are not supported.
- `offsider unlock-code status --device <serial or AVD name>` says whether a code is saved and whether its last attempt failed. Never run `unlock-code set` with a code you were given, and never ask for one: the user runs it in their own terminal, where typing is hidden.
- When a selector misses on an Android device whose screen is off or locked, the error says so and its hint is `offsider wake --device <DEVICE_ID>`, in `--json` errors too. A `--verify` that saw no change, `wait` and `assert` add a `Note:` line on stderr instead, so read stderr before retrying.
