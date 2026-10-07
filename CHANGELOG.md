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
- `--app <bundle-id>` on `describe-ui`, `tap`, `type`, `wait` and `assert`, and on those `batch` steps, names the app a device's runner reads, and later commands and steps remember it; simulators and Android ignore it. On `type` it applies to the field `--into-id`, `--into-label` and `--require-focus-id` find, `--verify-id` reads and the text the runner types.
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
- `boot --memory <MB>` (1024 to 16384), `--no-snapshot-load` and a repeatable `--emulator-arg <token>` add to the emulator launch, which always keeps `-no-metrics`. `--emulator-arg` takes only an allow-list of flags that shape the device or its rendering, and refuses anything else with exit 64 before anything starts. An AVD that is already running is not started again, and `boot` names the options it ignored.
- `boot --json` prints `{version, ok, avd, serial, alreadyRunning, grpc, logPath, memoryMB, ignored, lock, exitCode, error}` instead of the serial. After a boot, `boot` reads the user's unlock state and RAM in the same round trip as the screen: a device with a PIN, pattern or password that has not been unlocked since boot exits 7 with `device_locked` naming the serial, with a hint to save a code, run `wake --unlock`, or unlock it by hand; an unlocked device with its lock screen up gets a `Note:`, and less than about 2.75 GB of RAM a warning.
- `doctor --device` on Android adds `android-device.memory`, which warns when an emulator sees less than about 2.75 GB of RAM (phones always pass), and `android-device.lock`, which fails when a device with a PIN, pattern or password has not been unlocked since boot, with the same hints as `boot`. `doctor --json` `device` gains `lock`, as in `boot --json`, null on iOS.
- `list-devices --json` rows gain `avd` (a running emulator's or shut-down AVD's name) and `bootedBy` (`{pid, startedAt}` of the emulator process), null otherwise, and `boot --json` gains `bootedBy`; the version stays 1, as keys may be added within a version, and the table is unchanged.
- `list-devices` names the Offsider command holding each device's lock: `heldBy {pid, command, startedAt}` in `--json` and one line per held device on stderr. Only commands that take the lock show (input commands and setters on both platforms, and Android tree reads); an iOS `wait`, `assert` or `describe-ui` reads without locking, so `heldBy` stays null while one polls a simulator. A command now empties its lock record when it lets go, and a record whose pid has gone, is not `offsider`, or started after the lock was taken never counts.
- `lease set|release|show` keeps an advisory lease on a device under its AVD name, phone serial or UDID (`--label`, `--ttl` 1 to 1440 minutes, default 240, `--force`, `--json`), so agents sharing devices can see which session uses one; a shut-down AVD can be leased by name. Another label's live lease fails with the new reason `device_leased` (exit 8) unless `--force`, and the same label renews it. Input commands never read leases. `list-devices` shows `lease {label, since, expiresAt}` with a note on stderr, and `doctor --device` adds `device.lease`, which warns about another session's lease unless `OFFSIDER_LEASE` matches its label and names any command holding the device.
- `doctor` reports the host on every run: `host.load` warns when the 1-minute load passes 4 per CPU, `host.disk` warns under 10 GB free and fails under 2 GB, and `host.sessions` lists your other running Offsider commands by subcommand and device only (never typed text or other arguments). `--json` adds a top-level `host` object (`loadAverage`, `cpuCount`, `memoryGB`, `diskFreeGB`, `diskPath`, `sessions`), and the text report a `Host:` line.
- `screenshot --mask-id`, `--mask-label`, `--mask-text <regex>` and `--mask-emails` paint the elements they match black from one tree read, and `--mask-region x,y,w,h` paints a rectangle in points before any `--region` crop without reading the tree; each takes several values, and `batch` screenshot steps take them too. `--json` adds `maskedBy` (rectangles per kind asked for) and `maskUnmatched` (selectors that matched nothing, also warned on stderr; the image is still written). `offsider guide evidence` covers them.
- `screenshot --compare` counts the changed pixels as well as its tiles: `--json` adds `changedPixels`, `comparedPixels` and `changedBounds` after `changedFraction`, and the summary ends `, N pixels`. `--diff-output <png>` writes the capture faded to white with changed pixels in magenta and the excluded bands grey, and adds `diffPath`; the exit code still follows the tiles.
- `logs --json` entries gain `raw`, after `message`: the whole logcat line on Android (a continuation line its own), or the iOS event message with its colour codes kept; null when there is none.
- `run start <dir>`, `run stop` and `run status` keep an evidence run for the calling session (the agent or terminal found through its parent processes): every later `screenshot`, `logs` and batch screenshot step from that session also writes `NNN-<command>-<HH.MM.SS>.<ext>` (mode 0600) into the folder (created 0700; an existing folder keeps its mode, with a warning when other users can write to it) and a line to its `manifest.ndjson`, failures included. `run start` takes `--label` and `--mask-secure`, `--mask-emails` and `--mask-id`, which every capture in the run adds to its own masks; `run stop --summary` prints the timeline and `--json` the same as one object; `run status --all` lists every run of the user and ends those whose session has exited. A screenshot without `--output` is written only into the run, and `--json` adds `runFile`. `OFFSIDER_RUN=off` records nothing and `OFFSIDER_RUN=<dir>` records into that folder. New error reasons `run_active` and `run_unavailable` (exit 1).
- `guide --project <path>` prints a repository's own `OFFSIDER.md`, found in the path or its parents up to the repository root, the home directory or `/` (at most 256 KiB of UTF-8); it exits 1 when there is none and 64 with a topic. Plain `guide` names the file when one is found from the current directory, and the bundled skill tells agents to read it first.
- `touch --fingers 2 --hold <ms>` holds two fingers `--spread` points apart (default 60) around `-x`/`-y` and lifts both, for app menus behind a two-finger hold. It works on a simulator's main display and Android emulators, over gRPC or through the UiAutomation helper when input goes over adb; `input` alone refuses it, as do physical iPhones and the iPhone Duo's inner display.
- `drag --hold-ms <ms>` (0 to 10000, default 50) holds before moving, and `gesture long-press-drag --x --y --to-x --to-y` (`--hold-ms` default 800, `--duration` default 0.6) presses, holds and drags, for items that move only after a long press.
- `wait --any` with two or more selectors (`--id`, `--label` and `--value` repeat) waits for the first one on screen, for an action with two possible outcomes; `--json` names it in a new `matched` key (`{by, text}`), which `wait`, `assert` and batch records now always carry (null otherwise).
- `--verify-id <id>` on `tap`, `type`, `key` and `button` verifies that an element of the next screen came on screen (`change` `element`, default `--retries 0` and `--verify-timeout 10`, no screenshot fallback), and refuses before sending anything with the new reason `verify_target_present` (exit 1) when it is already there. `--verify-ignore-text` verifies on added or removed elements and state changes only, so a ticking clock or timer no longer counts as a change.
- `turnstile --status` reads a Cloudflare Turnstile widget once without a tap and prints `checkbox`, `verifying`, `passed`, `challenge` or `absent` (`--json`: `{version, state, source, frame}`); a visual challenge now fails with the new reason `turnstile_challenge` (exit 1). The skill now tells agents testing sign-in to run `turnstile` themselves and hand back only after exit 1 or 5.
- `describe-ui` text output says what surrounds the elements after the device line, only when it applies: `# window: <title> (modal)` or `(system)` on Android, `# keyboard shown` (on an iOS 27 simulator, which lists no keyboard element, from the keyboard's key layout group, now role `keyboard`) and `# logbox: N logs`; JSON gains an always-present `context` object (`window`, `keyboard`, `logbox`), and the schema stays version 2.
- `rn logbox status` reads React Native LogBox toasts and the inspector without a tap, and `rn logbox dismiss` clears every log through each toast's clear button, or the inspector's Dismiss when that does nothing, exiting 5 (`not_verified`) when logs remain.
- `tap --nth <n>` taps the nth on-screen match in tree order, and `tap --topmost` the one drawn on top (the last on Android, the one a hit-test reaches on iOS), in single taps and batch steps; ambiguous-match candidates now carry `index`, `window` and `screen` in JSON and the message.
- `type --into-id <id>` (or `--into-label`) taps a field and waits up to 2 s for focus before typing, in one locked command and as a batch step; when focus never comes nothing is typed and it exits 5 with the new reason `focus_not_confirmed`. On an iOS simulator a keyboard already up before the tap cannot prove focus, so it taps, types and warns. A field the on-screen keyboard covers is refused before the tap from the same tree read, as `tap` refuses it (`target_under_keyboard`, exit 1). `type --require-focus-id <id>` types only into a field that already has focus and otherwise exits 2 with the new reason `focus_mismatch`.
- The Android helper 1.3.0 (still protocol 2) names the field's `inputType` in `setText` replies and refusals, and gains a `paste` op that pastes the clipboard over all of the focused field's text, refusing password fields, a field whose text it cannot select (`action-unsupported`, nothing pasted) and, given `expectClass` or `expectResourceId`, any other field (the new code `focus-moved`); `hello` lists it. Dumps mark an empty field showing its hint with `showingHint`.
- `rn open --port <n> --bundle-id <id>` checks that Metro answers on 127.0.0.1, sends an Expo dev client its link to that Metro (resending while its launcher shows, and answering an iOS simulator's `Open in` prompt), and waits until `--wait-id` is on screen or the screen is still (`--scheme`, `--timeout` 10 to 900, default 180, `--json`). New reasons: `metro_not_running` (exit 9) and `rn_load_failed` (exit 1).
- `rn devmenu [item]` opens a React Native debug build's dev menu (shake on an iOS simulator, the menu key on Android) and lists its items, or chooses `reload`, `home`, `inspector`, `perf-monitor`, `fast-refresh`, `debugger`, `close` or `--label <text>` and waits for the menu to close (`--json` prints one object either way); `rn tools off` turns off the element inspector and the performance monitor when they show.

### Changed

- When the helper carries Android input, a key or button can stay held across other input, which `input` refuses; Android reports an accessibility service as enabled for that command, as it does for screen reads.
- An Android input failure now asks you to check that the device is still connected, not that the emulator is running.
- A physical iPhone or iPad UDID now routes to the device instead of failing as an unknown Android device name.
- `orientation` on a physical device that does not turn in time says the screen follows only while the device is awake and unlocked and the app in front supports the orientation.
- The `--display` help names `main` as the display of a device with one, and `cover` or `inner` on a foldable; `--display main` on a foldable still exits 64 with `unknown_display`, now saying why.
- The bundled skill's router is shorter: `type` and `button` detail, the full `list-devices --json` shape and the Turnstile detail now live in the `selectors`, `android` and `turnstile` guide topics.
- `wait --timeout` and `wait --seconds` accept up to 900 seconds (was 300), so a wait can outlast a cold React Native bundle; the error names the cap.
- `stay-awake --json` and `wake --json` report `credential` as `none` when lock settings say no credential is set, instead of null.
- Documentation only: `offsider guide react-native` explains that airplane mode and `svc wifi|data disable` on an emulator also cut a debug build's route to Metro at `10.0.2.2` (an `adb reverse` the user set keeps working), that per-app network blocking also blocks loopback on API 35 and 36 and is missing on API 34, so Offsider has no `network` command, and that `logs --rn` keeps working.
- `screenshot --json` `masked` now counts every rectangle painted by any mask, not only password fields.
- `logs` redacts by default for every source: passwords, tokens, API keys, cookies, `Authorization` values, JWTs and email addresses read `[redacted]` in `message` and `raw`, `--json` adds `redacted` (the count) and stderr says how many with a pointer to `--no-redact`. `--grep` matches the text before redaction; `--raw` alone turns redaction off as before, and `--raw --redact` keeps colour codes and redacts.
- The `screenshots` and `react-native` guide topics point to the new `evidence` topic for masking secure fields and personal data, and for log windows, `--json` and redaction.
- `wait --gone` now needs the element to stay off screen on every read for 500 ms (when `--timeout` is at least 0.5 s), so a node that drops out of one tree read no longer counts as gone; `--stable-for <ms>` (0 to 60000) sets that hold on any selector wait, and `--stable-for 0` restores the old behaviour.
- `tap` on a target the on-screen keyboard covers now fails with `target_under_keyboard` (exit 1) and sends nothing, with or without `--fail-if-covered`, instead of warning and pressing a key; the message says to hide the keyboard (on Android, `offsider button back`) or scroll the target above it. On Android the keyboard's own keys and buttons, inside its window, decide: Gboard's root view, and in its floating toolbar mode its window too, span the screen, but touches outside its keys reach the app.
- On an Android tablet or foldable where Gboard shows its floating toolbar, `describe-ui`, selectors and `type --into-id` see the focused app again: Android marks the whole app as not visible to the user behind that keyboard's screen-wide window, and the helper (1.3.0) no longer drops those nodes for the focused app.
- On Android, when `type --replace` falls back to keys, the warning names the field's class, id and decoded `inputType`; when the field then reads empty (showing only its hint counts as empty) or shorter than the text, after set-text or keys, an emulator with gRPC pastes the text over that same field with the helper's `paste` (restoring the clipboard; never into a password field, a field focus moved to, or one whose text cannot all be selected), and anything but exactly the text afterwards exits 5 with the new reason `text_not_accepted`; a longer reading after set-text or keys, such as `1,000` for `1000`, counts as accepted.
- Documentation only: `doctor` acts on the device `OFFSIDER_DEVICE` names when `--device` is absent, so `doctor --fix` with it set to an iPhone or iPad's UDID mounts the developer disk image on that device; the README, the `ios-device` guide topic and the agent guide now say so.

### Fixed

- On Android, `describe-ui`, selectors and waits list the app elements the on-screen keyboard wholly covers, as `uiautomator` and iOS do, so `tap` and `type --into-id` on one refuse with `target_under_keyboard` instead of reporting no match, even when its centre lies over the navigation bar beneath the keyboard. Android marks such a node as not visible to the user once the keyboard (with the navigation bar, when it sits beneath) covers it, and the helper (1.3.0) now keeps it, still marked so.
- A device another Offsider command has just let go no longer refuses the next command with exit 8 (`device_busy`). Releasing only closed the lock file, so a process the holder was starting on another thread at that moment kept the lock for a few milliseconds (up to 28 ms under heavy load); the device lock and the iPhone start lock now unlock first.
- `screenshot` on an Android phone with several displays, such as the Galaxy Z Fold3, captures the active display and no longer fails when `screencap` prints a warning before the image. It keeps `screencap`'s own pick when that has the active display's size, and otherwise captures again with `screencap -d` and the active display's ID; later captures in the same command (`batch`, `wait`, `--verify` and `record-video` frames) keep `screencap`'s own pick, checked each time so a fold by hand partway through is followed, or pass `-d` straight away when it did not have the active display. A failed capture reports `screencap`'s own error instead of the first line of that warning.
- On a Samsung foldable, `describe-ui` and `screenshot --json` name the active display `inner` or `cover` instead of `main`, and `posture` reads One UI's `CLOSE`, `HALF_FOLDED` and `OPEN` states as `closed`, `half-opened` and `open` instead of `unknown`. One UI's `dumpsys display` does not say which panel logical display 0 shows, so Offsider takes the only panel that is on.
- On a foldable phone, the hints for a display that is off or not active say to fold or unfold the phone, instead of pointing to `offsider posture`, which only an emulator accepts.
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
- On a physical device, `--verify`, `wait` screen checks and `screenshot --compare` no longer count the screen stream's compression noise as a change, so a press that changed nothing exits 5: they compare the mean colour of 8 by 8 pixel blocks within a small tolerance. Simulators and Android still compare pixels exactly.
- A physical device's first screenshot after its session broker starts waits until the stream has run about 1.5 s past its first frame, whose coarser encoding read as a change against every later capture of the same screen.
- `--verify` keeps taking screenshots while the screen is still moving (one more, then more until the attempt's time is up, at most six), so a change whose transition its first screenshots catch midway, or a device stream shows a moment late, verifies on the first attempt instead of sending the input again.
- `--verify` without a readable tree no longer sends an input a second time when it starts continuous motion, such as a video, an autoplaying carousel or a looping animation, where a second tap could pause the video or advance the carousel. It then takes two screenshots before the input, about 350 ms apart, and an area still moving afterwards counts as a change when it was still in both and covers more than a tenth of the screen. Motion already on screen, a ticking countdown label, a blinking caret and a small spinner still read as no change, and an input that stops motion still verifies. With a tree, `--verify` keeps its single screenshot before the input (a second costs about 2.3 s through `devicectl`) and relies on the tree, so motion the tree does not show reads as no change there: use `--retries 0` for such a control.
- On a physical iPhone or iPad, `screenshot --compare` pixel counts, `changedBounds` and the `--diff-output` image (and an evidence run's diff) no longer mark most of the screen as changed because of the stream's compression noise: a pixel counts as changed only when the mean red, green or blue of its 8 by 8 block, the blocks the tile verdict compares, moved by more than that noise. Simulators and Android still count pixels exactly.
- `boot` no longer fails to start an AVD whose earlier emulator crashed: when `hardware-qemu.ini.lock` names a process that is gone, it removes that file before the launch, says so, and names it if the launch still fails. `multiinstance.lock` is left alone, since its lock ends with the emulator that held it.
- `doctor` and `stay-awake` no longer say an Android screen turns off "after never": with a screen timeout of never, `android-device.stay-awake` passes with stay awake off ("Off: the screen never turns off on its own") and with it on but not charging, and `stay-awake on` says the screen stays on anyway.
- `orientation` on Android no longer leaves auto-rotate off for good: the first turn in a boot, portrait included, records auto-rotate and `user_rotation` for that boot (an emulator's start time, a phone's kernel boot id), and `orientation portrait` restores auto-rotate, so a phone held in landscape with auto-rotate on keeps it on. When auto-rotate cannot be read or recorded, `orientation` fails before turning, and a failed restore warns. `orientation --json` adds `autoRotate {before, now, restored}` and `userRotation {before, now}`, null on iOS and when reading.
- `button home` on Android no longer reports success while an app stays in front: it checks the launcher came to the front within 2 s (or `--verify-timeout`) and, when the image ignored the key, sends the HOME intent once. Without `--verify` a launcher that never came up is a warning; with `--verify`, `change` is the new value `activity` (and `note` the new value `home_intent` when the intent was needed), and the command exits 5 when the app stayed in front. It refuses `--verify-id` and `--verify-ignore-text`, and `--retries` does not apply. Any activity of the launcher's package counts as the launcher, so a launcher whose HOME entry is an activity-alias is recognised, and when the foreground cannot be read the key is still sent, with a warning (exit 5 with `--verify`).
- A LogBox toast is now recognised by its place at the bottom of the screen as well as its `!, ` or `n, ` label, so a full-width button labelled like `10, AUD` is no longer treated as one in cover warnings.
- On Android a node Android reports as not visible to the user (an earlier page of a stack hidden beneath the current one), or one in a window beneath the target's (the app under a keyboard), no longer counts as covering the tap target.
- `boot --emulator-arg` takes only an allow-list of flags, each value checked: `-accel`, `-camera-back`, `-camera-front`, `-cores`, `-feature` (`Vulkan` or `GLESDynamicVersion`), `-gpu`, `-no-audio`, `-no-boot-anim`, `-no-cache`, `-no-snapshot`, `-no-snapshot-save`, `-noskin`, `-partition-size`, `-read-only`, `-skin`, `-verbose` and `-wipe-data`. It used to refuse only listed flags, so `-network-user-mode-options hostfwd=...` could open a port on every interface of the Mac, `-skip-adb-auth`, `-crash-report-mode` and `-netsim-args` passed, and an `@name` token started another AVD. Anything else, including a stray value, `--` and `flag=value`, exits 64 naming the allowed flags.
- An evidence run's masks add to every capture's own: mask flags on `screenshot` or a batch step, `batch --mask-secure` and `OFFSIDER_MASK_SECURE` no longer replace them, so `run start --mask-emails` then `screenshot --mask-secure` masks both. `run start` again on the session's active run (or the `OFFSIDER_RUN` folder) adds new masks to it instead of ignoring them and prints the masks now in force; it never removes one, so `run stop` and start again to drop a mask.
- `manifest.ndjson` records `--mask-text`, `--mask-label` and `--grep` values as `<N characters>`, in a capture's `args` and in batch step lines (and so in `batch --json` records), since they often spell the personal data they hide; `--mask-id` values (the app's own element ids) and `--mask-region` coordinates are kept.
- A run's `logs` copy is created new at mode 0600 and never through a link, so a file or symlink already at its name is neither replaced nor followed; the capture warns and stdout carries on.
- `screenshot --mask-region` with a huge value such as `0,0,1e19,40` no longer crashes: mask rectangles are clamped to the image before they become pixels, and a tree frame with a NaN coordinate withholds the image.
- `lease set` reads, checks and writes a device's lease under a per-device lock in `leases/`, so two agents setting a free device at once can no longer both get it, and removing an expired lease or `lease release` can no longer delete a fresh lease written in between.
- `type --into-id`, `--into-label` and `--require-focus-id` work on a physical iPhone or iPad: the device runner reports the field with keyboard focus (XCTest's `hasKeyboardFocus`, not the focus engine's `hasFocus`, which a tap leaves unset), and `describe-ui` shows it as `state.focused`. Each device rebuilds its runner on next use. Simulators are unchanged.
- `tap --verify-id` right after another input waits out a transition again, as a selector `tap` without `--verify` does, so a target still sliding in is tapped where it settles instead of where it was first found.
- `tap --topmost` on iOS hit-tests the matches of the tree it taps from, on every read while it waits, instead of an earlier read that could have none. Under `--verify`, `--nth` and `--topmost` keep their pick when the verifier finds the target moved before the tap.
- `type --into-id` checks that the simulator keyboard can type the text, and that a `--verify-id` element is not already on screen, before its focus tap, so either refusal sends nothing. When the focus tap itself brings the `--verify-id` element on screen, the refusal says only that tap was sent, as `dispatched` `yes` does.
- `rn devmenu` no longer takes an app screen with its own Reload and Close buttons for the dev menu: it needs Reload beside two other menu items, or under React Native's menu title. On a physical iPhone or iPad, where Offsider cannot open the menu, the error says to shake the device by hand or open the menu from the app and run it again, instead of suggesting a two-finger touch the device refuses.
- Input with a coordinate or time no device could act on (not finite, beyond ±100000, or a pause outside 0 to 3600 s), such as `tap -x 1e19`, is refused as a usage error before anything is sent, instead of crashing an Android integer conversion.
- `type --into-id` and `--into-label` right after another input wait out a transition before tapping the field, as a selector `tap` does, so a field still sliding in is focused where it settles.
- On an iPad with Stage Manager, where XCTest reports SpringBoard in front, a command without `--app` reads the app last named with `--app` while that app is still in front, instead of SpringBoard's app switcher.
- `boot` reads the pid in `hardware-qemu.ini.lock` as the emulator writes it (digits, then a NUL), so a second `boot` of an AVD whose emulator is still starting waits for it instead of launching another.
- `describe-ui` through the Android helper no longer reports an empty field's hint as its value or `text`: Android reports a field showing its hint with the hint as its text, and the helper now says when it does. The hint stays in `hint`.
- On a physical iPhone or iPad that usbmuxd stops listing while `devicectl` still sees it on its cable, a command that needs the runner exits 9 with `usbmux_unavailable` at once and says to unplug and replug the cable, instead of waiting 150 s and then blaming the lock or UI Automation. A recorded runner is kept rather than restarted, a starting runner fails 10 s after usbmuxd drops the device, and `doctor` fails `ios-device.usbmuxd` when usbmuxd does not list the device on USB.
- Starting the runner on a locked iPhone or iPad now exits 7 with `device_locked` as soon as `xcodebuild` says it is waiting for the device to be unlocked, and stops it, instead of waiting 150 s and failing with `runner_unavailable`. An `xcodebuild` that exits before the runner answers now says so, instead of claiming the runner did not start within 150 s.
- When iOS asks for the device passcode on behalf of XCTest (`Enter iPad Passcode for "XCTest"`) and nobody enters it, starting the runner now exits 7 with `ui_automation_off`, naming the prompt and asking for the passcode to be entered on the device, as soon as XCTest gives up enabling automation (about a minute), instead of a generic runner failure.

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
