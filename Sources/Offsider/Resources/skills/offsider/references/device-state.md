# Device state

Every setter here changes the device and it stays changed. Read the current value by omitting the argument, set state before launching the app, and set it back when done. `--json` on each prints one object with `version: 1`.

## Appearance and text size

- `offsider appearance light|dark --device <DEVICE_ID>` sets the appearance. On Android a reading can be `auto` or `custom` when night mode follows a schedule; setting light or dark replaces it. Apps with their own theme setting follow `appearance` only when that setting is on automatic.
- `offsider content-size <category>|reset` sets the text size: a Dynamic Type category on iOS, the matching font scale on Android; `reset` restores `large`.

## Orientation

- `offsider orientation portrait|landscape-left|landscape-right|portrait-upside-down` (or `--rotation 0|90|180|270`) waits until the screen has turned and prints the new size. A portrait-only app stays portrait and the command times out.
- It names the device turn, as Maestro does: `landscape-left` is turned anticlockwise, which UIKit and the app call interface orientation landscape-right. `orientation --json` prints `rotation`, the same number as `describe-ui` `screen.rotation`.
- On Android it turns auto-rotate off. The iPhone Duo simulator refuses orientation changes.

## Permissions

- `offsider permission grant|revoke|reset <service>... --app <bundle id or package>` changes an app's permissions.
- `offsider permission services` lists the service names (`camera` and `notifications` are Android only, `photos-add`, `reminders` and `siri` iOS only); `permission show --app <id>` reads an Android app's runtime permissions.
- Android stops the app when a permission is revoked, so relaunch it.

## Status bar

`offsider status-bar override` sets a clean status bar (9:41, full battery and signal, or `--time`, `--battery`, `--wifi`, `--cellular` and more), `clear` removes it and `show` reads it.

## Biometrics

- `offsider biometric enrol|unenrol|match|no-match`. Send `match` or `no-match` only while the app shows its Face ID, Touch ID or fingerprint prompt, then check the screen: nothing confirms the app saw it.
- On iOS enrol first, and `unenrol` afterwards. On Android enrolment is manual (it needs a screen lock), and `biometric` is refused on a phone.
