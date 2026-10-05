# Changelog

All notable changes to Offsider are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The Android helper (1.1.0, protocol 2) gains `inject`, which sends taps, swipes, touches, keys and text through UiAutomation, and `screenshot`, which returns the screen's raw pixels; `hello` lists the ops it serves.
- `OFFSIDER_ANDROID_INPUT=auto|helper|input` chooses how input reaches an Android phone, or an emulator without gRPC. `auto` uses the helper only when the command has already started it to read the screen (a selector tap, `type --replace`), and `input` otherwise; `helper` always uses it and fails with a hint when it cannot start; `input` never uses it. Separate `touch --down` and `touch --up` commands always use `input motionevent`.
- `OFFSIDER_ANDROID_CAPTURE=auto|screencap|raw|helper` chooses how such a device is captured. `auto` and `screencap` use `screencap -p`; `raw` reads `screencap`'s raw pixels and `helper` the helper's, both encoded as PNG on the Mac and both falling back to `screencap -p`.
- The defaults stay on `input` and `screencap -p` because, in medians on a Galaxy Z Fold3 and a moto g57, starting the helper costs 280 to 390 ms per command while an injected tap saves only 40 to 75 ms: through the helper a coordinate `tap` was 61% and 90% slower, `swipe` 40% and 52%, `type` 92% and 110% and `screenshot` 33% and 63%, while a selector tap with `--verify` was 2 to 5% faster under `auto`.
- `OFFSIDER_TIMINGS=1` adds the Android phases `helper-inject`, `helper-capture` and `capture-encode`.
- `OFFSIDER_ANDROID_PHONE=<serial>` with `./test-runner.sh --android-phone` (`make e2e-android-phone`) runs the `AndroidPhone*Tests` suites on that one USB phone, installing the React Native playground there and leaving it.
- `scripts/bench-ab.sh --phone --device <serial>` benchmarks a USB phone, with the scenarios `android-tap-xy`, `android-tap-xy-input`, `android-tap-xy-helper`, `android-tap-physical`, `android-swipe`, `android-type-ascii`, `android-type-ascii-helper`, `android-screenshot`, `android-screenshot-raw`, `android-screenshot-helper` and `android-batch-tap-5`; it never installs the playground and refuses when it is missing.
- Physical iPhones and iPads over USB, named by UDID with `--device`. A device on Wi-Fi is refused with `device_not_wired`, and Offsider never pairs one. The device must trust the Mac, have Developer Mode on and stay unlocked, and input needs Settings > Developer > UI Automation.
- On an Xcode 27 host (CoreDevice 636 or later), a session broker per device carries screenshots and input. The first command that needs it starts it detached (`offsider device-session serve`, a hidden command) from the Mac's desktop session, in about 3 s. It holds the device's CoreDevice screen stream, its UniversalHID service (touchscreen and keyboard) and its hardware button socket; listens only on a 0600 Unix socket in the private directory's `sessions/` and refuses other users; logs to `ios-devices/<UDID>/session.log`; and exits after `OFFSIDER_IOS_SESSION_IDLE` idle seconds (default 300), on `session stop`, or when the device goes. The device shows its screen-sharing indicator while it runs.
- Through the broker, taps, touches, swipes, gestures, drags, keys and US keyboard text are UniversalHID reports, and the `home`, `lock`, `side-button` and `siri` buttons are button events. Measured on an iPad Pro over USB with the broker running: `tap` 132 to 148 ms, `type` 69 to 84 ms, `button home` 151 to 164 ms and a 0.3 s `swipe` about 370 ms.
- `screenshot` on a device takes the broker's latest stream frame (about 230 ms), and uses `devicectl device capture screenshot` (about 2.3 s) with a one-line notice when the stream cannot start, for example over ssh with no desktop session; `appearance`, `content-size` and `orientation` use `devicectl`.
- When the broker cannot start, taps, swipes, `button home` and text go through the runner, and keys, touches, gestures and the other buttons are refused. On an Xcode 26 host, listing, `doctor`, screenshots, appearance, text size, orientation, the tree, `wait`, `assert`, element taps, coordinate `tap`, `swipe` and `button home` work through the runner, and the other input exits 9 with `xcode_too_old`. Non-ASCII text and `type --replace` go through the runner on both.
- An XCUITest runner reads the accessibility tree on a device. Offsider builds it from bundled source with `xcodebuild` on first use (about a minute), caches it under `~/Library/Caches/offsider/runner/`, signs it with `OFFSIDER_IOS_TEAM_ID` or the one team signed in to Xcode, and reaches it over usbmuxd with a per-session token. It stops after `OFFSIDER_IOS_RUNNER_IDLE` seconds idle (default 300).
- `runner status` and `runner stop` (`--device`, `--json`) show and stop runner sessions.
- `session status` and `session stop` (`--device`, `--json`) show and stop both of a device's background sessions, the runner and the session broker; stopping the broker ends the stream and clears the screen-sharing indicator.
- `--app <bundle-id>` on `describe-ui`, `tap`, `wait` and `assert` names the app a device's runner reads, and later commands remember it; simulators and Android ignore it.
- Element taps on an iPad app in a Stage Manager window are refused with `not_supported` and a hint to make the app full screen, since its frames are relative to the window; coordinate taps, screenshots and the tree still work.
- `list-devices` shows iPhones and iPads with `kind` `physical`, `connection` `usb` or `network`, and a state (Booted, Wireless, Untrusted, Developer Mode off, Preparing, Reconnecting or Unavailable), with a hint for each problem.
- `doctor --device <UDID>` runs the `ios-device.*` checks (`xcode`, `coredevice`, `listed`, `transport`, `pairing`, `developer-mode`, `ddi`, `tunnel`, `lock-state`, `hid`, `ui-automation`, `session`, `usbmuxd`, `runner-signing`); `--fix` only mounts the developer disk image. `ios-device.hid` opens the HID button socket and round-trips a barrier on it; `ios-device.ui-automation` is skipped with the Settings path, since iOS does not report it; `ios-device.session` reports the session broker and its stream, and is a skip when none runs, as doctor never starts one.
- `OFFSIDER_TIMINGS=1` adds the device phases `runner`, `accessibility`, `session` (connecting to or starting the broker), `stream-capture` and `capture` (a `devicectl` screenshot); the broker logs its `stream-open` and `stream-frame` phases to its `session.log`.
- New error reasons: `device_not_wired`, `device_untrusted`, `developer_mode_off`, `device_preparing` and `ui_automation_off` (exit 7), `xcode_too_old`, `team_missing` and `usbmux_unavailable` (exit 9), and `runner_build_failed` and `runner_unavailable` (exit 1). `device_locked` also covers a locked iPhone or iPad. `hid_broker_failed` also covers a device's session broker, and `input_outcome_unknown` input it may have sent before it stopped answering.
- `permission`, `status-bar`, `biometric`, `shake`, `posture`, `stream-video --format bgra`, `logs`, `rn prepare`, a lone `touch --down`, `boot`, `wake`, `stay-awake`, `unlock-code` and `button apple-pay` are refused on a device, most with a message naming the alternative.
- `OFFSIDER_IOS_DEVICE_E2E=1`, `OFFSIDER_IOS_DEVICE=<UDID>` and `OFFSIDER_IOS_TEAM_ID` with `./test-runner.sh --ios-device` (`make e2e-ios-device`) run the device suites on that one device.
- `offsider guide ios-device` covers physical iPhones and iPads.
- `scripts/build.sh runner [--check]` regenerates the runner's Xcode project from its `project.yml`, or compares it with the committed one.
- `OFFSIDER_DEVICE` is the default `--device`: a command without `--device` uses it when it is set and not blank, and an explicit `--device` wins. `doctor` prints the binding (`device.source` in `--json` is `option` or `environment`); `permission services` and the `runner` and `session` filters ignore it. A command with neither now exits 64 with `Missing --device <id>. Pass --device, or set OFFSIDER_DEVICE`.
- `boot --memory <MB>` (1024 to 16384), `--no-snapshot-load` and a repeatable `--emulator-arg <token>` add to the emulator launch, which always keeps `-no-metrics`. `--emulator-arg` refuses flags that open a listener or connect out, send metrics, or replace Offsider's own options, with exit 64 before anything starts. An AVD that is already running is not started again, and `boot` names the options it ignored.
- `boot --json` prints `{version, ok, avd, serial, alreadyRunning, grpc, logPath, memoryMB, ignored, lock, exitCode, error}` instead of the serial. After a boot, `boot` reads the user's unlock state and RAM in the same round trip as the screen: a device with a PIN, pattern or password that has not been unlocked since boot exits 7 with `device_locked` naming the serial, with a hint to save a code, run `wake --unlock`, or unlock it by hand; an unlocked device with its lock screen up gets a `Note:`, and less than about 2.75 GB of RAM a warning.
- `doctor --device` on Android adds `android-device.memory`, which warns when an emulator sees less than about 2.75 GB of RAM (phones always pass), and `android-device.lock`, which fails when a device with a PIN, pattern or password has not been unlocked since boot, with the same hints as `boot`. `doctor --json` `device` gains `lock`, as in `boot --json`, null on iOS.
- `list-devices --json` rows gain `avd` (a running emulator's or shut-down AVD's name) and `bootedBy` (`{pid, startedAt}` of the emulator process), null otherwise, and `boot --json` gains `bootedBy`; the version stays 1, as keys may be added within a version, and the table is unchanged.
- `list-devices` names the Offsider command holding each device's lock: `heldBy {pid, command, startedAt}` in `--json` and one line per held device on stderr. A command now empties its lock record when it lets go, and a record whose pid has gone, is not `offsider`, or started after the lock was taken never counts.

### Changed

- When the helper carries Android input, a key or button can stay held across other input, which `input` refuses; Android reports an accessibility service as enabled for that command, as it does for screen reads.
- An Android input failure now asks you to check that the device is still connected, not that the emulator is running.
- A physical iPhone or iPad UDID now routes to the device instead of failing as an unknown Android device name.
- `orientation` on a physical device that does not turn in time says the screen follows only while the device is awake and unlocked and the app in front supports the orientation.
- The bundled skill's router is shorter: `type` and `button` detail, the full `list-devices --json` shape and the Turnstile detail now live in the `selectors`, `android` and `turnstile` guide topics.
- `wait --timeout` and `wait --seconds` accept up to 900 seconds (was 300), so a wait can outlast a cold React Native bundle; the error names the cap.
- `stay-awake --json` and `wake --json` report `credential` as `none` when lock settings say no credential is set, instead of null.

### Fixed

- `screenshot` on an Android phone with several displays, such as the Galaxy Z Fold3, no longer fails when `screencap` prints a warning before the image.
- Android input through the UiAutomation helper is never sent twice: when the helper stops before it answers, the command fails with `dispatched` `unknown` instead of resending the tap, key or text.
- Long `type` text through the Android helper no longer times out after 5 s: each request carries at most 256 characters and its timeout grows with its keys.
- After the Android helper refuses a touch, closing the command no longer warns that it could not lift a finger the helper had already cancelled.
- On a physical device, `key --duration`, `button --duration` and a long press (`touch --down --up --delay`, also as a `batch` step) hold for their whole time: the device session times each hold and its release in one request, so a held key or touch no longer lifts at once, and a command killed mid-hold never leaves a button, key or touch down. A `batch` touch or key left down at the end of its step is refused with `not_supported`, as a lone `touch --down` is.
- A physical device's session broker keeps serving input while its screen stream recovers: input never waits behind a stream re-open, input whose command has disconnected or given up is dropped unsent (so a retried tap no longer lands twice), and a stream that keeps failing (an app using the camera, a locked device) is retried with back-off while screenshots use `devicectl`, instead of ending the broker.
- One failed UniversalHID open no longer sends a device's touches to the runner and refuses its keys for the broker's whole life: the next input at least 2 s later retries it.
- The device screen stream takes video only from the device's own tunnel address.
- On a physical iPad with Display Zoom set to More Space, taps, swipes and `describe-ui` screen sizes use the UI's real point size, so input lands where `describe-ui` frames say.
- `describe-ui` reports a landscape-native iPad's screen as landscape.
- On a physical device, touches after the screen turns land where the turned screen's frames say: the device session reads the display again before a touch when its last read started over a second earlier, and `orientation` makes it read again at once.
- Element taps on an iPad app in Split View are no longer refused as if it were in a Stage Manager window.
- `--verify` on a physical device in landscape can now exit 5: the status bar band, where the screen-sharing indicator pulses while the session streams, is left out of its screen comparison in every orientation, as it is for `screenshot --baseline` and `wait` screen checks. Simulators and Android are unchanged.
- Two commands starting a device's runner or session broker at once can no longer both take its start lock, which a command that crashes now releases at once.
- A device's session broker lists the device again before it reopens a touch or button link, and stops once the device is off USB, so input never goes over a Wi-Fi tunnel after a cable pull.
- After a device session loses a reply, the command's next input reconnects instead of failing unsent; the input whose reply was lost is never resent.
- When a device's session broker fails to start, the rest of the command no longer waits for it again: screenshots go straight to `devicectl` and `button home` to the runner.
- Long `type` text on a device goes to the session in requests of at most 256 characters, so it no longer fails as possibly sent; a request too large for the session is refused unsent.
- `boot` no longer fails to start an AVD whose earlier emulator crashed: when `hardware-qemu.ini.lock` or `multiinstance.lock` names only processes that are gone, it removes both before the launch, says so, and names them if the launch still fails.
- `doctor` no longer says an Android screen with stay awake off turns off "after never without input": with a screen timeout of never, `android-device.stay-awake` passes with "Off: the screen never turns off on its own".

## [0.6.0] - 2026-10-05

### Added

- `turnstile` taps the checkbox square of a Cloudflare Turnstile widget and waits until it passes. The checkbox's accessibility frame includes the words beside the square, so a normal tap lands on the words. The tap sits a few points off the square's centre and stays inside it (`--jitter`, `--seed`). On iOS the web view leaves the checkbox out of the tree: the command reads a point in that web view, leaves a widget that already says Success, and otherwise taps the square where the green check sits. `--id` limits the search to one wrapper. Exits 5 when the checkbox remains, and 2 when no widget is on screen. A visual challenge fails with a message. It does not bypass Turnstile: the command only taps the checkbox, and the widget passes only when Cloudflare accepts the device. `offsider guide turnstile` is that note.
- `stay-awake [on|off]` reads or sets Developer options > Stay awake on Android emulators and named USB phones (the `stay_on_while_plugged_in` global setting, for every power source), with the screen timeout, and says when it has no effect: the device is not charging, charges over a source the setting leaves out, or a device policy caps the screen timeout.
- `wake` turns an Android screen on and dismisses its lock screen, and sends nothing when the screen is already on and unlocked. A PIN, pattern or password lock screen exits 7 with the new reason `device_locked`.
- `unlock-code set|status|remove` keeps a test device's PIN or password in the login Keychain under its phone serial or AVD name, asking twice with typing hidden or reading `--stdin`, and never prints it. `wake --unlock` types it once, only into a focused password field inside System UI's lock screen; after a code fails, Offsider does not type it again until the device is unlocked by hand or the code is saved again.
- `stay-awake`, `wake` and `unlock-code` refuse an iOS simulator as `not_supported`: simulators never sleep or lock.
- `stay-awake`, `wake`, `unlock-code` and their errors name a phone by maker and model, such as `Motorola moto g57 (ZY22FAKE01)`, and an emulator by its AVD name, from the state read these commands already make.
- `doctor --device` on Android adds `android-device.screen` and `android-device.stay-awake`, and on a phone `android-device.adb-expiry` (whether this Mac's adb authorisation lapses) and `android-device.system-updates`; it names a phone by maker and model.

### Changed

- When an Android command fails because a selector matched nothing, no window was found, `--verify` saw no change, or `wait`, `assert` or `screenshot --compare` was not met, and the screen is off or locked, the error names the device, says so and its hint becomes `offsider wake --device <id>`; the reason and exit code are unchanged. A `--verify --json` error carries it too; a `--verify` that saw no change, `wait`, `assert` and `screenshot --compare` add a `Note:` line on stderr. The check uses only what the failed command had already read, plus one state read.

## [0.5.0] - 2026-10-04

### Added

- `describe-ui --max-bytes <n>` cuts text output at whole lines and says how many nodes were left out; when the Android device stops listing nodes at its own limit, text output says the tree is incomplete.
- `screenshot --mask-secure` and `batch --mask-secure` paint password fields black before writing the image, and withhold it when a password field cannot be located. `OFFSIDER_MASK_SECURE=1` turns masking on by default. `screenshot --json` then adds `masked`, the number of fields painted.
- Every failure has a typed `reason` and a `hint`; with `--json` it prints one object on stdout with `exitCode` and `error` (`reason`, `message`, `hint`, `dispatched`, `candidates`). The README lists every reason.
- Not-found and ambiguous selector errors list up to five candidates with id, label, role, frame and on-screen state in JSON, and ambiguous errors name each candidate's label.
- Input commands and setters (including `permission`, `status-bar` and `biometric` when they change state), and Android commands that read the screen, lock the device for their run. A second command on the same device exits 8 (`device_busy`) naming the holder's pid; `--wait-lock <seconds>` or `OFFSIDER_WAIT_LOCK` waits instead. `batch` holds one lock for all its steps, and the wait never counts against the hung-device watchdog. Reads on iOS never lock. Locks live in a private per-user directory that ignores `TMPDIR`. `--wait-lock` exists only on commands that can lock.
- The `batch --json` summary line adds `dispatched` (`yes`, `no` or `unknown`), and a failed batch's text ends with `Dispatched: <state>`, so an agent can tell whether resending the batch is safe.
- `doctor --device` checks Android emulators, by serial or AVD name: the SDK and adb, the adb server and whether its mDNS discovery is off, the emulator package and the bundled helper, then the device's state and system image, the emulator gRPC endpoint and its auth mode (never the token), the UiAutomation slot and any accessibility service, one helper start with its times, and any Metro reverse. Plain `doctor` adds the Android host checks when an SDK is installed, and the JSON report adds `device` and `android` under version 1. `doctor --fix` starts an absent adb server with `ADB_MDNS=0` (not when `--device` names a simulator), and changes nothing else on Android.
- `OFFSIDER_TIMINGS=1` prints Android phases: `prepare`, `adb-devices`, `adb-shell`, `display-probe`, `helper-launch`, `dex-push`, `helper-hello`, `helper-dump`, `tree-map`, `helper-close`, `grpc-connect`, `grpc-call`, `input` and `capture`.
- USB-connected Android phones can be driven by passing their serial to `--device`; they are never chosen otherwise. `list-devices` shows them with model, connection and authorisation state, and prints the USB debugging prompt hint for an unauthorised phone. Network (Wi-Fi) adb devices are listed as unsupported and refused, and `boot`, setting a posture, `stream-video --format bgra` and non-ASCII plain `type` are refused on a phone with the alternative.
- `permission grant|revoke|reset <service>... --app <id>` sets an app's permissions on iOS simulators (`simctl privacy`) and Android (runtime permissions, idempotent, never `pm reset-permissions`), with `show` on Android and `services` listing the names each platform supports. It works on a named USB phone.
- `status-bar override|clear|show` sets a clean status bar: iOS `simctl status_bar`, Android System UI demo mode in one adb round trip. It works on a named USB phone.
- `biometric enrol|unenrol|match|no-match|status` drives Face ID and Touch ID on iOS simulators and the fingerprint sensor on Android emulators through the emulator console. Android enrolment needs a screen lock and is refused with instructions, as is `biometric` on a phone. `enroll` and `unenroll` are accepted too.
- `doctor --device <usb phone serial>` checks the phone instead of saying no device has that name, skipping the emulator gRPC check and saying why.
- The React Native playground has a `permission-state` screen (camera and notification permissions on Android), and the native playground a `device-state` screen (contacts and photos permissions, Face ID).
- `scripts/rn-playground.sh metro stop` removes the `adb reverse` it set on running emulators.
- `doctor --device <UDID>` adds `simulator.crash-loop`, which reads the last 10 minutes of crash reports for that simulator, warns at two to four crashes of one process, fails at five or more and prints the erase command without running it. Plain `doctor` adds `simulators.crash-loop`, listing every simulator in a crash loop by name. `test-runner.sh` refuses to start on a simulator in a crash loop.
- `scripts/bench-ab.sh` compares a base build with the branch on one Offsider device in paired, seeded runs, and reports medians, a bootstrap interval and a verdict.
- `describe-ui --diff` prints the nodes added, changed and removed since the previous command's tree for the device, `unchanged since <command> <n> ms ago` when nothing changed, or the full view when most of the screen changed.
- Selector `tap`, `slider` and batch tap steps wait out a transition the previous input started (up to 500 ms, 150 ms with no cached tree) and find the target again before acting; `--no-settle` turns this off.
- `--verify --json` reports up to 10 `changes`, a `changesTruncated` count and `note: "keyboard_closed"`.
- `OFFSIDER_TIMINGS=1` adds the `tree-cache`, `tree-diff` and `settle` phases.
- `offsider guide <topic>` prints one topic of the agent skill, matched to the installed version: `selectors`, `verify`, `errors`, `android`, `react-native`, `foldables`, `batch`, `screenshots`, `describe-ui`, `device-state` and `migrate`, which maps idb, Maestro and agent-device commands to Offsider. `offsider guide` lists the topics; an unknown topic exits 64.

### Changed

- The skill `offsider init` installs is a short router (under 10 KB, from 36 KB): the core loop, the rules, the exit codes and a topic table, with the depth printed on demand by `offsider guide`. `init` still installs `SKILL.md` only.
- Offsider keeps the last accessibility tree read from each device, with password values masked and platform attributes left out, in its private per-user directory for 10 minutes; `OFFSIDER_TREE_CACHE=off` turns it off.
- `tap --verify` reads the tree once fewer before tapping, and taps the target where the verifier's second read finds it.
- `describe-ui --summary` stops at 16384 bytes by default (`--max-bytes 0` lifts it).
- `describe-ui --summary` and `--format text` leave out labels a parent already shows, summarise nodes past an edge of the screen as `[off-screen below] N items` with `--on-screen`, and stop indenting at 10 levels; JSON is unchanged.
- Password fields read as bullets in `describe-ui`, selectors, `wait`, `assert` and `--verify` on both platforms, one per character. `--value` no longer matches them, and `assert --has-value` compares the bullets.
- A SwiftUI `SecureField`, which iOS reports as a text field with a secure subrole, now has the role `secureTextField`.
- On Android, non-ASCII text is no longer pasted into a focused password field; use `type --replace`.
- On iOS, React Native checkboxes, radio buttons, switches, tabs, tab lists, menu items, combo boxes and progress bars report their role instead of `other`, read from the words React Native writes into the accessibility value, with `state.checked` and a `value` of `1`, `0` or `2` for toggles, as on Android.
- iOS nodes report `state.selected` from the Selected trait when the tree carries traits.
- **Breaking:** new exit codes: 2 selector not found (also off screen), 6 ambiguous selector, 7 device not found or not booted, 8 device busy, 9 Xcode, adb or the Android SDK missing; malformed device IDs, unknown displays and unsupported keys exit 64. These exited 1 before.
- **Breaking:** `batch` exits with the code of its first step that failed to run, and a failed step's `error` is now an object.
- **Breaking:** two input commands on one device no longer run at once; the second exits 8.
- **Breaking:** `--verify --json` reports are version 2: `dispatched` is `yes`, `no` or `unknown`, `error` is an object and `exitCode` is new.
- `list-devices --json` adds `kind` (`simulator`, `emulator`, `avd` or `physical`) and `connection` to each row, under version 1.
- A `host:port` device ID now says Offsider drives phones over USB only, instead of that it is not a simulator UDID.
- `doctor --device <android>` no longer exits 64. With an Android device it runs Android checks only, so Xcode and simulator state cannot fail an Android session.

### Fixed

- On Android, a React Native mixed checkbox reads `value` `2` with no `state.checked`, and its label no longer ends in `, mixed`.
- `type` no longer writes the typed text to the system log, and an unsupported character is reported by position.
- `batch --json` and batch errors no longer print the text of a `type` step.
- `--verify` no longer quotes a password field's value.
- Android `biometric unenrol` no longer says removal needs a screen lock; it says unenrol is not supported and points to Settings > Security.
- A non-emulator serial could match an emulator discovery file that has no console port, and so be handed that emulator's gRPC connection.
- On Android, a password field's text no longer appears in `describe-ui --fields native` or in a clickable parent's label, and a password field showing its hint reads as empty.
- A failure while input was being sent no longer reports `dispatched: false`; it reports `unknown`.
- The HID broker now checks a client's user before sending its ready handshake.
- `--wait-timeout` no longer builds suggestions on every poll.

## [0.4.0] - 2026-10-04

### Added

- `describe-ui --summary` prints one line per on-screen node that has a label, id or value. `--flat`, `--on-screen`, `--labelled`, `--actionable`, `--fields`, `--format json|ndjson|text` and `--compact` shape the output; without them it is unchanged.
- `screenshot --scale points|<factor>`, `--region x,y,w,h` (in points), `--format png|jpeg`, `--quality` and `--json`.
- `screenshot --compare <baseline>` with `--threshold` reports how much of the capture changed and exits 0 when it changed, 5 when it did not.
- `wait` waits until an element is on screen or `--gone`, the screen is `--settled`, a `--region` is `--changed` or `--stable`, or `--seconds` pass, and exits 5 on timeout; `--settled` on a screen whose accessibility tree is never readable fails and suggests `--settle-by screen`. `assert` checks once and exits 5 when the element is not on screen, is not gone, or lacks `--has-value`.
- `batch` runs `wait`, `assert`, `screenshot` and `describe-ui` as steps, and `batch --json` prints one NDJSON line per step and a summary line. A batch whose only failures are unmet conditions exits 5.
- `tap` warns when another element may cover its target, and `--fail-if-covered` fails instead of tapping.
- `tap` treats a React Native LogBox banner as covering the strip beneath it on Android, where the accessibility tree cannot see its touch area.
- `logs` prints recent device log entries or collects live ones, with `--rn` for React Native output, `--app`, `--process`, `--predicate` (iOS), `--grep`, `--max-lines`, `--raw` and `--json`. Live output stops with an error when the device's log stream exits, for example on a bad `--predicate`.
- `appearance`, `content-size` and `orientation` read or set the device's appearance, text size and orientation on iOS and Android; `shake` sends the shake gesture on iOS. `orientation` names the device turn as Maestro and devicectl do: `landscape-left` is the device turned 90 degrees anticlockwise, home edge on the right (UIKit's interface orientation `landscape-right`), and `landscape-right` the reverse. On Android, `appearance` reads `auto` or `custom` when night mode follows a schedule, and setting light or dark replaces it.
- `rn prepare --bundle-id <id>` marks an Expo dev client's first-launch dev menu intro as seen and stops the menu opening at launch, so a fresh debug install opens straight into the app (iOS simulators; Android debuggable builds through `run-as`). It stops the app first if it is running, on both platforms.
- `--allow-offscreen` on `tap`, `slider` and batch tap steps resolves an element whose frame is outside the screen.
- When no `--label` or `--value` matches exactly, typographic quotes and unusual spaces are folded, so `--label "Don't Allow"` finds `Don’t Allow`. A selector that matches nothing suggests the closest labels.
- `doctor` names the Xcode a running Simulator.app belongs to and, when it is not the selected one, suggests `DEVELOPER_DIR` before quitting it.
- `OFFSIDER_TIMINGS=1` prints phase timings to stderr.
- `orientation --rotation 0|90|180|270` sets the orientation as the device's anticlockwise turn from portrait, and `orientation --json` prints `orientation`, `rotation`, `previous` and `screen`.
- `describe-ui` `screen` adds `rotation` (the device's anticlockwise turn from portrait in degrees, the number `orientation --json` prints, on a landscape-natural Android panel too), `display` (`{id, platformId}`: `main`, or `cover` or `inner` on a foldable) and `posture` (null unless the device folds); the `--summary` header adds the rotation, and the display and posture on a foldable. `screenshot --json` adds the same `rotation`, `display` and `posture`.
- `displays` lists a device's built-in displays with platform ID, size, scale, rotation and which one is active, then the posture; `--json`.
- `posture` reads a foldable's posture and active display, and sets `closed`, `half-opened` or `open`: on an Android emulator through the emulator, on the iPhone Duo simulator by driving its hinge (`--angle 0-180`), waiting until the display has swapped. Where an iOS runtime has no hinge service the command says so.
- On the iPhone Duo's inner display, `tap`, `swipe`, `drag` and `touch --down --up` reach the display through its own touchscreen; a detached `touch --down` or `--up` on it is refused with a message.
- `--display <id>` on `screenshot` captures one display of a foldable; on `describe-ui` it checks that the named display is the active one.
- Screenshots on the iPhone Duo simulator capture the active display: the cover display while folded, the inner display while open.
- A foldable E2E suite for the iPhone Duo simulator (`make e2e-foldable`, `OFFSIDER_FOLDABLE_E2E=1`) and one for a Pixel 9 Pro Fold emulator (`make e2e-android-fold`, `OFFSIDER_ANDROID_FOLD_E2E=1`).
- React Native playground screens for kept-mounted sheets, mounted stacks, overlays, unlabelled rows and environment readouts, with iOS suites (`make e2e-rn-ios`) and a typecheck in CI.

### Changed

- **Breaking:** `describe-ui` JSON `version` is now 2: `screen.orientation` and `screenshot --json` `orientation` are the shape, `portrait` or `landscape`, and `screen.rotation`, `screen.display` and `screen.posture` are new. In 0.3.0, `orientation` was `portrait`, `portraitUpsideDown`, `landscape` or `landscapeFlipped`; read `rotation` for the turn.
- `posture`, `wait`, `assert` and `batch` give routing and device preparation a 45 s watchdog allowance separate from `--timeout`, so a cold emulator's setup is not mistaken for a hang.
- Selectors prefer on-screen matches. A match whose frame lies outside the screen now fails with an error naming its frame, where `tap` used to report success, and `--wait-timeout` waits for it to come on screen. A duplicate label on a hidden view no longer counts as a second match. A partly visible element whose centre is off screen is tapped at the centre of its visible part.
- Every iOS landscape screenshot is now upright, with or without the new `screenshot` options.
- `batch` reads the screen again after any step that sends input or sleeps, so a selector step sees the screen its previous step opened. `--ax-cache none` is an alias of `perStep`.
- A multiple-match error lists each candidate's role, id and frame, and for a duplicated `--id` suggests `--element-type` or coordinates.
- A selector `tap` or `slider` that had to wait for its element also waits until the element stops moving, so a tap no longer lands on a sheet that is still sliding in.
- `tap --allow-offscreen` warns when its point is outside the screen.
- A `--wait-timeout` or `--poll-interval` on a batch tap step overrides the batch-level value for that step; it used to be ignored.
- `gesture` help says which way each scroll preset moves the content.
- `tap -x -y` outside the screen prints a warning, in batch steps too.
- `screenshot` prints the image size on its "saved" line.
- The React Native playground's Metro commands listen on loopback only: `pnpm start` passes `--localhost`, and `dev-ios`/`dev-android` run the background `metro start`, install a debug build and set the adb port reverse.
- Android commands that read the screen finish sooner: once the UiAutomation helper confirms `quit`, Offsider closes it without waiting up to 1 s for its exit or sending `kill`.
- Android `type --replace` no longer runs a `wm size`, `wm density` and `dumpsys input` shell before the helper sets the text. Input reads the display only when it first needs it, so `--verify` and `batch` reuse what the helper already measured.

### Fixed

- Screenshots on the iPhone Duo simulator captured the inactive inner display while it was folded.
- `wait`, `assert` and `orientation` stop with an error when the device does not answer, where a hung simulator used to hang the command.
- A HID broker that exits just after accepting a connection is replaced, where the client used to fail with a socket error.
- A selector `tap` or `slider` on iOS reads the accessibility tree once, not twice.
- A failed selector `tap` prints its error once.
- `logs --last` and `--since` refuse values beyond 8760 h or the year 9999 with a clear error instead of crashing.
- A batch `describe-ui --display` step refuses a display that is not active, as the standalone command does.
- `posture --angle` and `posture <name>` no longer move the iPhone Duo's hinge when it already reads the target angle and the matching display is active, so an open simulator is not closed and reopened, and a resend cannot refold a closed one; when the hinge reads the target but the other display is still showing, the hinge is swept from the far end so the panels swap.
- On the iPhone Duo's inner display, and on an Android tablet or other landscape-natural panel, `rotation` in `describe-ui`, `screenshot --json` and `displays` is the device's turn from portrait, matching `orientation --json`; it used to be the UI's turn on the panel, 90 or 270 degrees off.
- Polling the posture or orientation of a foldable simulator reads devicectl at most once a second instead of on every poll, and orientation retries no longer block the process.

## [0.3.0] - 2026-10-02

### Added

- `list-devices` command: one row per device with PLATFORM, STATE, ID, NAME and OS columns.
- `list-devices --json` prints `{"version": 1, "devices": [...]}`, each device with `id`, `platform`, `state`, `name`, `osVersion` and `deviceType` (null when unknown).
- `list-devices --platform ios|android` lists one platform.
- Android Emulator support: `list-devices`, `describe-ui` (in dp), `tap`, `swipe`, `drag`, `gesture`, `touch`, `type`, `key`, `key-sequence`, `key-combo`, `button`, `screenshot`, `record-video`, `stream-video`, `batch` and `--verify` work with an emulator serial or a running AVD name. Offsider talks to the adb server and the emulator's gRPC endpoint on loopback, starts the adb server with mDNS off when none is running, and falls back to adb for emulators without gRPC.
- `type` on Android pastes text with non-ASCII characters through the emulator's clipboard, then restores the clipboard.
- `boot <avd>` starts an Android emulator (windowed, or `--headless`) with `-no-metrics`, waits until Android and its gRPC endpoint are ready and prints the serial; an AVD that is already running is not started again.
- `button back`, `app-switch`, `volume-up` and `volume-down` for Android; `lock` is the power key there.
- `OFFSIDER_ANDROID_TRANSPORT` (`adb` or `grpc`) and `OFFSIDER_ANDROID_GRPC_AUTH` (`jwt`) for troubleshooting Android transports.
- Android screen reads (`describe-ui`, selectors, `--wait-timeout`, `--verify`, `gesture` presets, `slider` and `type --replace`) go through a small UiAutomation helper that Offsider pushes to the emulator and runs for one command, about 0.3 s per `describe-ui` on a quiet Mac. When another UiAutomation client, such as Appium, holds the connection, the command fails and says so; when the helper cannot run, Offsider reads the screen with `uiautomator` instead, with a warning.
- `OFFSIDER_ANDROID_TREE` (`helper` or `uiautomator`) for troubleshooting Android screen reads.
- `slider` works on Android emulators through the accessibility progress action, falling back to a drag; a control whose steps cannot show the requested value reports the nearest step it reached.
- `type --replace` replaces the focused field's text on both platforms, also in batch steps, and an empty text clears it. iOS selects all with Command-A and deletes, then types; Android sets the text in one accessibility action (any Unicode, no gRPC needed) and presses Return for a trailing newline, falling back to Ctrl+A, Delete and typing.
- `scripts/build.sh helper` (`make helper`) rebuilds the Android helper's committed dex from `AndroidHelper/` with a pinned JDK 17, build-tools 37.0.0 and android-37.0; `--check` (`make helper-check`) compares it with the committed dex in CI, and release builds check the bundled dex against its manifest.
- React Native playground (`OffsiderPlaygroundRN`) for shared iOS and Android fixtures.

### Changed

- `--device <id>` replaces `--udid` on every command, including `doctor`. Pass an ID from `offsider list-devices`. The `doctor --json` report keeps its `udid` key.
- Device IDs are case-insensitive: a lowercase simulator UDID now reaches the same simulator.
- An ID that is neither a simulator UDID nor an Android serial or AVD name fails with a hint to run `offsider list-devices`.
- Offsider requires macOS 26 or later.
- Batch steps reject `--device` (and `--udid`); set the device once on `batch`.
- `list-devices` lists iOS simulators (iPhone and iPad), not the watchOS, tvOS and visionOS ones `list-simulators` listed, plus Android emulators and AVDs.
- `describe-ui` prints a versioned, platform-neutral schema: `{"version": 1, "platform", "device", "screen", "roots"}`, each node with `role`, `id`, `label`, `value`, `frame`, `enabled`, `state`, `native` and `children`, and every key present with `null` when unknown. `AXUniqueId`, `AXLabel` and `AXValue` become `id`, `label` and `value`; the iOS `type`, `role`, `role_description` and other attributes move under `native` in camelCase. `--point` returns the same envelope with one root.
- `--element-type` on `tap`, `slider` and batch taps matches the describe-ui `role` in any case (`button`, `slider`) or the native type exactly (`RadioButton`, `TextEditor`). `--element-type Button` now also matches `PopUpButton` elements.
- Text areas (`TextView` and `TextEditor`, role `textArea`) are actionable: `tap --label` prefers them over plain text with the same label, as it does for text fields.
- `--verify` compares the neutral tree. iOS change summaries are unchanged; a checked state change without a value change reads "checked state of X changed".
- Selector help and errors say id, label and value instead of AXUniqueId, AXLabel and AXValue, and `slider` reports `value:`.
- `--id` also matches the part of an Android resource id after `:id/` when no id matches exactly.
- Android trees add the keyboard window as a `keyboard` root, label the application root with the window title, report slider and progress values as percentages and tri-state checkboxes as `2`, and fill `stateDescription`, `roleDescription` and `testTag` (a Compose `testTag` is the `id` when there is no resource id).
- `--verify` leaves each platform's system bars out of screenshot comparisons: the status bar on iOS as before, and on Android the status and navigation bars as the helper measures them. A command that changed nothing suggests `doctor` only for simulators.
- `--verify` on Android reads the screen again as soon as an accessibility event follows the action, instead of waiting out each 200 ms poll; events only prompt the read, never decide the result.
- A `button` that the device's platform does not have exits 64 before touching the device.
- Tap summaries round points to 0.01 and name the selector, for example `Tap on id=BackButton at (22.1, 76.2)`.
- `type` normalises text to Unicode NFC, so an `e` followed by a combining acute accent types as one `é`.
- `record-video` and `stream-video` call their source a device, and their frame errors no longer mention a simulator.
- Help for `describe-ui`, `key`, `key-combo`, `key-sequence`, `gesture` and `batch` names emulators as well as simulators, or the device, instead of only a simulator. `batch --tap-style` help describes the styles as `tap --tap-style` does, and `gesture` and `swipe` help and errors give `--screen-width`, `--screen-height` and `--delta` in points (dp on Android) instead of points or pixels.

### Fixed

- `gesture` presets, on their own and as batch steps, fit the device and orientation: they are sized to the foreground app's frame from the accessibility tree instead of a fixed 390 x 844 point screen, and translated like `swipe` coordinates, so they land correctly in landscape and on every screen size. `--screen-width` and `--screen-height` still override the size, now in points (dp on Android) as the screen is currently oriented.
- `stream-video` now emits JPEG frames in the `mjpeg`, `raw` and `ffmpeg` formats at the default `--scale` and `--quality`. Previously those frames were PNG, labelled `image/jpeg` in the `mjpeg` stream.
- `batch` step failures now include the underlying error, such as an unsupported step, an invalid argument or an input failure, with or without `--continue-on-error`. Previously many read "The operation couldn't be completed".
- `doctor` details and other messages that wrap an Offsider error, such as a missing developer directory, now show that error's text instead of "The operation couldn't be completed".

### Removed

- `list-simulators`. Use `list-devices`; the old name exits 64 with a rename hint.
- `--udid`. Use `--device`; the old flag exits 64 with a rename hint.

## [0.2.0] - 2026-09-24

### Added

- `doctor` command: checks Xcode, Device Hub, CoreSimulator, HID stabilisation, the HID broker directory and booted simulators, and with `--udid` a simulator's state, Resize Mode, dtuhidd state and readiness, HID transport and accessibility. `--json` prints one object; `--fix` opens Device Hub or the device window and removes a stale broker directory. Exits 3 on warnings and 4 on failures.
- `--verify`, `--verify-timeout`, `--retries` and `--json` on `tap`, `type`, `key` and `button`: wait for an accessibility or screen change, retry (tap switches style), and exit 5 when nothing changes. Batch steps reject these flags.

### Fixed

- Input events are no longer discarded on Xcode 27. The bundled idb frameworks now wait for the simulator's HID daemon to be ready before the first event, so taps and keys land without `--post-delay`.

## [0.1.0] - 2026-09-24

First release of Offsider, forked from [AXe](https://github.com/cameroncooke/axe) v1.8.0 by Cameron Cooke. Changes up to the fork are recorded in [AXe's changelog](https://github.com/cameroncooke/axe/blob/v1.8.0/CHANGELOG.md).

### Added

- XcodeGen project for the playground fixture app, so the simulator end-to-end suites run from a clean clone.
- Signed and notarised release tarball, `offsider-<version>-arm64.tar.gz`, with a `SHA256SUMS` file and a GitHub build provenance attestation.
- Homebrew formula in the `michael-palmes/tap` tap.

### Changed

- Renamed the tool, Swift package, targets and executable to `offsider`.
- Renamed bundle identifiers, the HID broker's runtime paths, environment variables (now `OFFSIDER_*`) and the bundled agent skill (now `offsider`).
- Builds for Apple silicon (arm64) only.
- Builds the idb frameworks from the [michael-palmes/idb](https://github.com/michael-palmes/idb) mirror at a pinned revision.

### Fixed

- Shortened HID broker socket names so they stay within the Unix socket path limit.
- Builds now honour an explicit `OFFSIDER_VERSION` when generating the version string.

[Unreleased]: https://github.com/michael-palmes/offsider/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/michael-palmes/offsider/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/michael-palmes/offsider/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/michael-palmes/offsider/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/michael-palmes/offsider/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/michael-palmes/offsider/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/michael-palmes/offsider/releases/tag/v0.1.0
