# Device state

Every setter here changes the device and it stays changed. Read the current value by omitting the argument, set state before launching the app, and set it back when done. On a USB phone the user allowed, the setters work too and change their phone: change only what the test needs, and always set it back. `--json` on each prints one object with `version: 1`.

A phone's `posture` override stays too: run `offsider posture reset --device <serial>` when done (`guide foldables`).

## Appearance and text size

- `offsider appearance light|dark --device <DEVICE_ID>` sets the appearance. On Android a reading can be `auto` or `custom` when night mode follows a schedule; setting light or dark replaces it. Apps with their own theme setting follow `appearance` only when that setting is on automatic.
- `offsider content-size <category>|reset` sets the text size: a Dynamic Type category on iOS, the matching font scale on Android; `reset` restores `large`. A running iOS app re-measures only some of its text (a header cut short, a sheet at its old height), so after a change with an app in front a stderr note names `offsider app launch --restart --app <id> --device <id>` (an Expo dev client: `rn open` again with `--restart`): restart it before you judge the layout. Android recreates the app's screen, so it needs none.
- On a physical iPhone or iPad both go through `devicectl`, and `orientation` turns the screen only while the device is awake and unlocked. `permission`, `status-bar` and `biometric` are refused there: use a simulator.

## Orientation

- `offsider orientation portrait|landscape-left|landscape-right|portrait-upside-down` (or `--rotation 0|90|180|270`) waits until the screen has turned and prints the new size. A portrait-only app stays portrait and the command times out.
- It names the device turn, as Maestro does: `landscape-left` is turned anticlockwise, which UIKit and the app call interface orientation landscape-right. `orientation --json` prints `rotation`, the same number as `describe-ui` `screen.rotation`.
- On Android, Offsider turns auto-rotate off while the device is turned and restores it on `orientation portrait`: the first turn in a boot, portrait included, records auto-rotate and `user_rotation` for that boot, and portrait writes auto-rotate back (and `user_rotation` when auto-rotate was on), even after a turn the app refused. When auto-rotate cannot be read or recorded, `orientation` fails before turning anything. `--json` on Android adds `autoRotate {before, now, restored}` and `userRotation {before, now}` (null on iOS and when reading). Finish an Android run with `orientation portrait`. On the iPhone Duo simulator `orientation` turns either display; the cover's home screen stays portrait.

## Permissions

- `offsider permission grant|revoke|reset <service>... --app <bundle id or package>` changes an app's permissions. Grant only the services the test names; ask before any other. On a phone, `all` is refused (exit 64), since it would reach SMS, the call log and location: name each service. There `--app` (also for `show`) must be an app the phone's allowance covers and not a browser or system app, else exit 1 `app_not_allowed` with nothing sent: ask the user to pin it in `devices add`.
- `offsider permission services` lists the service names (`camera` and `notifications` are Android only, `photos-add`, `reminders` and `siri` iOS only); `permission show --app <id>` reads an Android app's runtime permissions.
- Android stops the app when a permission is revoked, so relaunch it.

## Permission prompts

When the app raises the system's permission prompt, reads and taps with `--app` are refused, since the window in front is not the app. On a simulator, an emulator or an Android test device:

```bash
offsider alert show --app <id> --device <DEVICE_ID>
offsider alert deny --app <id> --device <DEVICE_ID>
offsider alert accept --app <id> --device <DEVICE_ID>
offsider alert choose "Only this time" --app <id> --device <DEVICE_ID>
```

- `show` prints the text and each button, marking what `accept` and `deny` would pick, and changes nothing. Accept only a permission the test names; ask before any other, and deny when unsure.
- `accept` picks the narrowest grant that lasts (While using the app, Allow While Using App, else Allow), never a broader one (All the time, Always Allow, Allow Full Access), a one-time one (Only this time, Allow Once) or a photo picker: name one of those with `choose "<label>"`, the button's whole text as `show` prints it. Exit 6 means it cannot tell which button grants or declines (on iOS: another language, or an alert that is not worded as a permission request): read `show` and use `choose`.
- Exit 2 `alert_not_shown`: no prompt for the app, so carry on. Exit 7 `system_prompt_in_front`: another app's prompt or some other system window, which `alert` never answers; pass on `error.ask`.
- `accept` and `choose` obey the app's guard rules (`guide guard`); a refusal there is final. `deny` always passes.
- A phone in personal use exits 1 `person_required` with nothing read: pass on `error.ask`. On an iPhone or iPad test device the runner reads and taps the alert itself.
- The answer stays: `offsider permission reset <service> --app <id>` makes the app ask again (on an iPhone, Settings or a reinstall of that app). In a run (`guide evidence`) each answer is a timeline line.
- On an Android, iPhone or iPad test device, `screenshot --app <id>` with that app's prompt in front captures the prompt alone (`maskUnproven: "prompt"`), the rest painted.

## Status bar

`offsider status-bar override` sets a clean status bar (9:41, full battery and signal, or `--time`, `--battery`, `--wifi`, `--cellular` and more), `clear` removes it and `show` reads it. On a phone, `override` and `stay-awake on` print a note that the setting stays, with the command that undoes it.

## Biometrics

- `offsider biometric enrol|unenrol|match|no-match`. Send `match` or `no-match` only while the app shows its Face ID, Touch ID or fingerprint prompt, then check the screen: nothing confirms the app saw it.
- On iOS enrol first, and `unenrol` afterwards. On Android enrolment is manual (it needs a screen lock). On an allowed phone only `biometric status --device <serial>` works: read only, no lock. Never read `dumpsys fingerprint` yourself.

## Screen reader

- `offsider screen-reader on --device <DEVICE_ID>` turns a screen reader on for an app that shows, hides or regroups views for one; `off` puts it back, and no value reads it (`--json`: `screenReader`, `previous`, `service`, `resetBySessionStop`). Read the screen with `describe-ui` after turning it on: the tree can differ.
- It stays on across reboots. `session stop --device <DEVICE_ID>` and `shutdown` turn it off only if this command turned it on; `doctor --device` warns `device.screen-reader` while it is on.
- iOS simulator: apps are told VoiceOver is running, but a simulator never starts it. Nothing is spoken, and `tap`, `swipe`, `type` and every read work as usual. Do not double-tap to activate.
- Android emulator or test device: the real TalkBack runs, and Offsider's touches are injected past it, so `tap`, `swipe`, `type` and every read work as usual. Do not double-tap to activate.
- If TalkBack was already on, run `screen-reader on` once anyway, or an emulator's tap only selects.
- Refused (`not_supported`), with nothing sent: an iPhone or iPad, an Android phone that is not a test device, an emulator started with sound (start it with `offsider boot <AVD>`), and a device without TalkBack.

## Screen, stay awake and unlocking (Android)

`sleep` turns a screen off and `wake` turns it back on, on an Android device or an allowed iPhone or iPad (`guide ios-device`). `stay-awake`, `wake --unlock` and `unlock-code` refuse an iOS simulator or iPhone as `not_supported`, and `sleep` refuses a simulator: simulators never sleep or lock by themselves, and an iPhone or iPad is unlocked by hand. After `button lock` on a simulator, `offsider wake --device <UDID>` clears its lock screen: it reads SpringBoard's lock state, presses Home at most twice only while the lock screen is up, and checks it has gone. Never swipe up to unlock a simulator: that can freeze its display.

- `offsider stay-awake --device <DEVICE_ID>` reads Developer options > Stay awake with the screen timeout; `on` keeps an awake screen on while the device charges (every power source) and `off` restores the timeout. It survives reboots. The output says when it has no effect: not charging, charging over a source it leaves out, or a device policy capping the timeout. Turn it on before a long run; it does not turn a dark screen on.
- `offsider wake --device <DEVICE_ID>` turns the screen on and dismisses a swipe lock screen, and sends nothing when the screen is already on and unlocked. A PIN, pattern or password lock screen stays up and exits 7 with `device_locked`: with a code saved the message names `offsider wake --unlock --device <serial>`, otherwise ask the user to unlock the device or save its code. A failed read or tap on that lock screen names the same step.
- After a boot, a device set up with a PIN, pattern or password stays locked until someone unlocks it once, and apps cannot start until then. `offsider boot <AVD>` checks this and exits 7 with `device_locked` naming the serial; `boot --json` reports `lock` (`type`, `savedCode`, `lastAttemptFailed`, `lastAttempt`, `userUnlocked`, `screen`, `lockScreen`); `type` is null when Android 9 or older says a credential is set but not which; `unlock-code` takes a PIN or password only, so ask the user which lock it is, and with a pattern ask them to unlock it by hand. Ask the user to unlock it, or run `wake --unlock` when `savedCode` is true and `lastAttemptFailed` false. `doctor --device <DEVICE_ID>` reports the same as `android-device.lock`, which warns while a saved code is wrong or unconfirmed, and the RAM the device sees as `android-device.memory`. An emulator with full-disk encryption can read booted while it waits at "To start Android, enter your PIN", where app installs fail for lack of space: `doctor` fails `android-device.state` there. Ask the user `Can you enter the PIN on <device>?` (never type it), or use an AVD with no boot PIN.
- `offsider wake --unlock --device <DEVICE_ID>` also types the PIN or password the user saved with `offsider unlock-code set --device <serial or AVD name>`, once, into the lock screen's own field only, as key events through the UiAutomation helper (exit 9 `helper_unavailable`, nothing typed, when it cannot run). Ask the user before running it. It then says one of two things, and types nothing more until the user saves the code again; pass on its `Ask:` line (`error.ask`) word for word and never loop. `The saved PIN is wrong` (`lastAttempt.outcome` `rejected`): the lock screen stayed up after it was typed. `Offsider can't tell if the saved PIN is right` (`started`): no run saw a result, so it may be fine. Patterns are not supported.
- `offsider unlock-code status --device <serial or AVD name>` says whether a code is saved and whether it is wrong or unconfirmed. Never run `unlock-code set` with a code you were given, and never ask for one: the user runs it in their own terminal, where the code shows only as dots. Without a terminal, or with `--stdin` but no terminal to confirm on, it exits 1 `person_required`.
- When a selector misses on an Android device whose screen is off or locked, the error says so and its hint is `offsider wake --device <DEVICE_ID>`, in `--json` errors too. A `--verify` that saw no change, `wait` and `assert` add a `Note:` line on stderr instead, so read stderr before retrying.
