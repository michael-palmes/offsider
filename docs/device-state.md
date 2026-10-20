# Device state

`appearance`, `content-size` and `orientation` change the device for every later screen, and `permission`, `status-bar`, `biometric` and `stay-awake` change state that outlives the command; each has a reset, so set them back when done. Setting a value already in place succeeds and says it changed nothing where the platform can read it. Set state before launching the app.

<details>
<summary>Services and the permissions each maps to</summary>

| Service | iOS (`simctl privacy`) | Android runtime permissions |
| --- | --- | --- |
| `all` | `all` | every runtime permission the app requests |
| `calendar` | yes | `READ_CALENDAR`, `WRITE_CALENDAR` |
| `camera` | not offered | `CAMERA` |
| `contacts` | yes | `READ_CONTACTS`, `WRITE_CONTACTS`, `GET_ACCOUNTS` |
| `contacts-limited` | yes | not offered |
| `location` | yes | `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` |
| `location-always` | yes | the above plus `ACCESS_BACKGROUND_LOCATION` |
| `media-library` | yes | `READ_MEDIA_AUDIO` |
| `microphone` | yes | `RECORD_AUDIO` |
| `motion` | yes | `ACTIVITY_RECOGNITION` |
| `notifications` | not offered | `POST_NOTIFICATIONS` |
| `photos` | yes | `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_VISUAL_USER_SELECTED` |
| `photos-add`, `reminders`, `siri` | yes | not offered |
| `bluetooth` | not offered | `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` |
| `phone` | not offered | `READ_PHONE_STATE`, `CALL_PHONE`, `READ_CALL_LOG`, `WRITE_CALL_LOG` |
| `sms` | not offered | `SEND_SMS`, `RECEIVE_SMS`, `READ_SMS` |
| `body-sensors` | not offered | `BODY_SENSORS` |

</details>

- `permission` always needs `--app`; Offsider never changes every app's permissions at once. On Android it reads `dumpsys package` first, grants or revokes only what is not already in place, and also takes a literal `android.permission.NAME`. A service the app requests none of fails naming the manifest entries it needs; one it requests only some of applies to those and adds a note. `reset` revokes and clears the user-set and user-fixed flags so the app asks again (`reset all` also resets the app's app ops); before Android 13 `pm` cannot clear those flags, so there `reset` only revokes and adds a note when a permission stays user-fixed. It never runs `pm reset-permissions`, which resets every app. Android stops an app when one of its permissions is revoked, and the output says so. iOS simulators offer no read, so `show` is Android only and iOS reports earlier values as unknown.
- `status-bar` uses `simctl status_bar` on iOS. On Android it uses System UI demo mode in one adb round trip: `override` sets `sysui_demo_allowed` to 1 and sends the demo broadcasts, and `clear` exits demo mode and deletes the setting (the override's `--json` reports its earlier value, so a caller can restore it). Android cannot report whether demo mode is showing, and some vendor builds ignore it.
- `biometric` on iOS posts the BiometricKit notifications behind the simulator's Face ID and Touch ID menus: Face ID, or Touch ID on the iPhone SE and iPads other than iPad Pro (`--modality` overrides). On an Android emulator `match` touches the fingerprint sensor with finger 1 and `no-match` with finger 10 through the emulator console (`adb emu finger`, `--finger-id` overrides). `match` and `no-match` are events: nothing confirms the app saw them, so check its screen. Enrolling a fingerprint on Android needs a screen lock, which Offsider does not set, so `enrol` there explains how to do it in Settings.
- `permission`, `status-bar`, `stay-awake`, `wake`, `unlock-code`, `appearance`, `content-size` and `orientation` work on an allowed USB phone and change the phone itself; `biometric` is refused there. On a phone, `permission --app` (`show` included) must name an allowed app that is not a browser or system app, else exit 1 `app_not_allowed` with nothing sent, and `permission grant|revoke|reset all` exits 64: name the services, since `all` reaches SMS, the call log and location and outlives the run. `status-bar override` and `stay-awake on` print a note that the setting stays, with the command that undoes it. Location simulation is not offered.

## Orientation

`orientation` reads or sets the device orientation, waiting until the device has turned: `portrait`, `landscape-left`, `landscape-right`, `portrait-upside-down`, or `--rotation 0|90|180|270` in degrees anticlockwise. The names say how the device is turned, as Maestro and devicectl name them: `landscape-left` is turned 90 degrees anticlockwise, home edge on the right, which React Native's and UIKit's interface orientation call `landscape-right`. `describe-ui` and `screenshot --json` report the shape as `orientation` and the turn as `rotation`.

`--json` on Android also reports `autoRotate {before, now, restored}` and `userRotation {before, now}` (null on iOS). On Android, `orientation` turns auto-rotate off while the device is turned: the first turn in a boot, to any orientation, records auto-rotate and `user_rotation` in the private directory's `orientation/` (one 0600 file per serial, naming the boot by the emulator's start time or a phone's kernel boot id), and `orientation portrait` writes auto-rotate back and removes the record. When auto-rotate cannot be read or recorded, `orientation` fails before turning, so auto-rotate is never left off without a record.

## Foldables

A foldable has a `cover` and an `inner` display, and one of them is active at a time; `main` names the only display of a device with one, so `--display main` on a foldable exits 64 with `unknown_display`. `offsider displays` lists both and marks the active one, and `offsider posture` reads the posture (`closed` uses the cover display, `open` the inner one). `describe-ui`, `tap` and the other input commands use the active display, and `screenshot` captures it unless `--display` names the other one. `describe-ui --display inner` fails with a hint while the inner display is not active, so a script can check it is reading the screen it expects.

- iOS: `posture` folds and unfolds the iPhone Duo simulator by driving its hinge the way Device Hub does (a private CoreDevice path, best effort on Xcode 27.1; where the runtime has no hinge service the command says so and exits 1). Folded, the cover display is 466 x 678 pt; unfolded in portrait, the inner display is 951 x 669 pt (landscape-shaped, rotation 0: `screen.rotation` is the device's turn from portrait, as `orientation --json` reports it, not the UI's turn on the panel). The Duo refuses orientation changes.
- Android: `offsider posture open` (or `closed`, `half-opened`) folds the emulator through its gRPC endpoint, or `cmd device_state` over adb, and waits until the device reports it. A Pixel 9 Pro Fold emulator's inner display is about 852 x 883 dp and its cover display about 443 x 994 dp. Folding it shows "Swipe up to continue" on the cover, over the app, which keeps running: swipe up from the bottom edge to use it.
- Android phones: a foldable phone such as a Samsung foldable lists `cover` and `inner` like the emulator, and `posture` reads One UI's `CLOSE`, `HALF_FOLDED` and `OPEN` states as `closed`, `half-opened` and `open`. Fold and unfold it by hand: setting a posture is emulator-only, and the hints for a display that is off or not active say so.
