# Exit codes and errors

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success; for `doctor`, every check passed or was skipped |
| 1 | The command failed for any other reason; the error is printed to stderr |
| 2 | The selector matched nothing, or only elements off screen, or no saved user has every `--where` tag |
| 3 | `doctor` found warnings |
| 4 | `doctor` found failures |
| 5 | A condition was not met: `--verify` saw no change after the input, `wait` timed out, `assert` failed, `screenshot --compare` found no change (or a change with `--expect unchanged`), or a `batch` had only such failures |
| 6 | The selector matched more than one element, or several saved users match `--where`, or several are saved and none is the default |
| 7 | The device was not found or is not booted, its lock screen stayed up, or it is a physical device no person has allowed |
| 8 | The device is busy: another Offsider command holds it (see [Device lock and leases](agents.md#device-lock-and-leases)), or another UiAutomation client holds an Android emulator |
| 9 | Xcode, adb or the Android SDK is missing or unusable |
| 64 | Invalid arguments or options, including the renamed `--udid` and `list-simulators`, an option the command lacks but a sibling has (`wait --wait-timeout`, `assert --timeout`, `tap --timeout`; the message names the right one and nothing is run), a malformed device ID, an unknown display, a key or `button` the device's platform lacks and `boot`'s emulator options with a simulator |

## JSON errors

With `--json`, a failure prints one object on stdout, where the success output goes, and the `Error:` line still goes to stderr. `describe-ui` does the same when its output is JSON or NDJSON and `--format` or `--compact` was given or stdout is not a terminal:

```json
{"version":1,"ok":false,"command":"screenshot","exitCode":7,"error":{"reason":"device_not_found","message":"No device with ID 5E1B... was found. Run `offsider devices` to see available devices.","hint":"offsider devices","dispatched":null,"candidates":[]}}
```

`--verify --json` reports (version 2), [input `--json` lines](input.md#json-results), `batch --json` step lines and a `login --json` that stopped after it began typing carry the same `error` object in place of their own envelope.

- `hint` is the next command to run and never repeats typed text. Without `--json`, stderr prints it on a `Try:` line under the `Error:` line, unless the message already quotes it; `<DEVICE_ID>` in it becomes the `--device` value. A person at a terminal sees ❌ instead of `Error:`, the cause in bold red, the rest of the message under it and `Try  <command>`; an agent's lines are never styled, and its hints never say `export`.
- `command` is the command's name: `devices` also when run as `list-devices`.
- `message` and `hint` show at most 4,096 characters, ending `…(+N)`. Screen text inside a message is double-quoted, while your own selector keeps single quotes. When a message or a candidate holds text from the device, the object ends with `untrusted`, listing those paths: `error.message`, `error.candidates[].id`, `label`, `window` and `screen`, `error.coveredBy.id`, `label`, `screen` and `process`, and `error.users[].tags` and `about`.
- A refusal only a person can lift (`device_not_allowed`, `app_not_allowed`, `metro_port_not_allowed`, `team_missing`, a `login` link no person confirmed, and `doctor`'s policy and team hints) asks an agent to fetch the user, naming what to choose. A person at a terminal, without `--json`, gets the same message without that sentence, and the `Try:` line names `offsider devices add`.
- `candidates` lists up to five elements (`id`, `label`, `role`, `frame`, `onScreen`, `index`, `window`, `screen` and `beneath`, never a value) for selector errors, and `target_covered` adds `coveredBy`, the element the tap would have reached. `user_not_found` and `user_ambiguous` add `users`, up to 20 saved users as `name`, `tags` and `about`, never a username.
- `dispatched` says whether input may have reached the device: `no` (nothing was sent, so resending is safe), `unknown` (a send began and failed, so check the screen first) or `yes`; it is null for commands that send no input.
- A `--json` that is itself the mistake, such as `guide --json`, prints only the usage error.

## Verify reports

A `--verify --json` report also carries `ignored` (`{node, reason}` entries left out of the check, `reason` `live`, `volatile` or `toast`), `elapsedMs` from the command's start and `phasesMs` (`settle`, `resolve`, `baseline`, `dispatch`, `verify`), and `note` is `logbox_opened` when the React Native LogBox inspector opened over the app. For an [agent](agents.md#what-a-person-and-an-agent-see), the text change summaries quote ids (`Button#"save"`); a person sees them bare. JSON values such as `changes[].node` and `ignored[].node` stay bare on both, and the `untrusted` list names them. A verified report also lists what changed: `changes` holds up to 10 entries, value and state changes first, then added, removed and moved nodes, each as `{"kind": "changed", "node": "text \"State\" id=state", "field": "value", "old": "All", "new": "Unread"}` (`kind` is `added`, `removed` or `changed`; `field`, `old` and `new` are null where they do not apply). `changesTruncated` counts the entries left out, and `note` is `keyboard_closed` when the keyboard left and nothing outside it changed except frames: the input may have been spent closing the keyboard, so repeat it if the control shows no effect. A change seen only in the screenshot gives `changes: []`. Android's `button home --verify` values (`change` `activity`, `note` `home_intent`) are additions within version 2.

## Error reasons

<details>
<summary>Every reason, with its exit code and what to do</summary>

| Reason | Exit | When | What to do |
| --- | --- | --- | --- |
| `selector_not_found` | 2 | No element matched the selector | Read `candidates` (each with its `closeness`: `case`, `prefix`, `contains` or `similar`), fix the selector (the message names the `--label-contains` text that matches a `prefix` or `contains` label), or wait with `--wait-timeout` |
| `selector_filtered_by_type` | 2 | Elements matched, but none of the `--element-type` | Drop or change `--element-type`; `candidates` shows the roles |
| `target_off_screen` | 2 | Every match is off screen, or above or below what its scroll view shows | Scroll it into view, wait, or pass `--allow-offscreen`; for `rn devmenu`, run the `hint`'s `swipe`, then choose again |
| `user_not_found` | 2 | `login --where` or `credential status --where` found no saved user with every tag; nothing was typed | Read `users` (each saved user's `name`, `tags` and `about`, never a username), then pass another `--where` or a name, or ask for a user with the access the test needs |
| `selector_ambiguous` | 6 | Several elements matched | Pick from `candidates`: use `--id`, add `--element-type` or tap by coordinates |
| `selector_ambiguous_switch` | 6 | The match holds several switches | Target the switch with `--id` or coordinates |
| `user_ambiguous` | 6 | Several saved users match `--where`, or several are saved and none is the default; nothing was typed | Read `users`, then add a `--where` tag only one has (the `hint` adds `platform=` when that is enough) or pass its name |
| `device_not_found` | 7 | No device has that ID | `offsider devices` |
| `device_not_booted` | 7 | The device exists but is not running | `offsider boot <ID>` |
| `device_not_ready` | 7 | The emulator is offline or still booting | Wait, or `offsider boot <AVD>` |
| `device_unauthorised` | 7 | adb is not authorised for the emulator | Accept the prompt, or restart it with `offsider boot` |
| `device_locked` | 7 | A PIN, pattern or password lock screen stayed up after `wake`, or its saved code did not unlock it, or an iPhone or iPad is locked, so it refused input or Xcode could not start the runner | Unlock it on the device, or on Android `offsider wake --unlock` with a code saved by `offsider unlock-code set` |
| `device_ambiguous` | 7 | An AVD name matches more than one running emulator, names both a phone and an AVD, or `boot` names a simulator several share | Pass one serial or UDID |
| `avd_not_found` | 7 | No AVD has that name | Run the `hint` when it names the closest AVD; else check the name in Android Studio's Device Manager |
| `device_not_wired` | 7 | The iPhone or iPad is connected over Wi-Fi, and Offsider drives it over USB only | Connect its cable |
| `device_untrusted` | 7 | The iPhone or iPad has not trusted this Mac | Unlock it and tap Trust |
| `developer_mode_off` | 7 | Developer Mode is off on the iPhone or iPad | Turn it on in Settings > Privacy & Security, then restart the device |
| `device_preparing` | 7 | Xcode is still preparing the iPhone or iPad for development | Wait for Xcode to finish, then retry; `offsider doctor --device <UDID>` shows progress |
| `ui_automation_off` | 7 | UI Automation is off on the iPhone or iPad, or XCTest could not enable it because the device's `Enter Passcode for "XCTest"` prompt went unanswered | Enter the passcode on the device if it asks, else turn on UI Automation in Settings > Developer |
| `device_not_allowed` | 7 | The command names a physical iPhone, iPad or Android phone that no person has allowed on this Mac, or that managed policy blocks; nothing was sent to it | Ask the user to run `offsider devices add` in their own terminal and choose this device by name; never try to allow it yourself |
| `device_busy` | 8 | Another Offsider command holds the device, `record-video` met `login`, `wake` or `type` holding it, or `login`, `wake --unlock` or `type --stdin` with a password field on screen found a recording running; the message names its pid | Wait and retry, or follow the `hint`: add `--wait-lock 30` to the same command |
| `device_leased` | 8 | `lease set` or `lease check` found another session's live lease on the device | Choose another device; `offsider lease show`, or `--force` when that lease is stale |
| `uiautomation_busy` | 8 | Another UiAutomation client holds the emulator | Stop that client, or run the `hint`, then retry |
| `xcode_missing` | 9 | No usable Xcode is selected | Run the `hint`, `sudo xcode-select -s` with the newest Apple-signed Xcode in `/Applications` other than the one refused; without sudo, `export DEVELOPER_DIR=` that developer folder (an agent is told to run each command as `DEVELOPER_DIR=<dir> offsider …`). With none left, install Xcode 26 or later |
| `xcode_unusable` | 9 | The selected Xcode cannot load simulator support, `DEVELOPER_DIR` points outside an Apple-signed Xcode, or a private method Offsider calls has changed | Select an Apple-signed Xcode 26 or later as for `xcode_missing`, or update Offsider |
| `android_sdk_missing` | 9 | No Android SDK or adb was found | Install Platform-Tools or set `ANDROID_HOME` |
| `adb_server_unavailable` | 9 | The adb server is not running or not answering | Run the command again: Offsider starts one with `ADB_MDNS=0`. When one runs but does not answer, stop it first with the `hint` (the SDK's `adb kill-server`) |
| `adb_server_misconfigured` | 9 | The adb server settings point off this Mac or cannot be read, or its Unix socket belongs to another user | Fix or unset the adb server variables |
| `emulator_missing` | 9 | The Android Emulator is not installed | Run the `hint`: the SDK's `cmdline-tools/latest/bin/sdkmanager emulator` |
| `emulator_grpc_required` | 9 | The command needs the emulator's gRPC endpoint and it is not reachable | Restart the emulator with `offsider boot` |
| `helper_unavailable` | 9 | The UiAutomation helper cannot run on this device, including when a password or unlock code needs it; nothing was typed | Unset `OFFSIDER_ANDROID_TREE` or `OFFSIDER_ANDROID_INPUT`, or use another image |
| `xcode_too_old` | 9 | The selected Xcode cannot drive this feature on an iPhone or iPad | Run the `hint`: it selects an installed Xcode 27 and runs its first launch, which updates CoreDevice, or says to install Xcode 27 or later |
| `team_missing` | 9 | No signing team was chosen for the iPhone runner; Xcode's signed-in team is never used on its own | Ask the user to run `offsider devices add` and choose a team from its menu, or set `OFFSIDER_IOS_TEAM_ID` |
| `usbmux_unavailable` | 9 | usbmuxd, which reaches iPhones over USB, is not answering, or does not list the device on USB | Unplug and replug the cable; restart the Mac if it persists |
| `usage` | 64 | Invalid arguments or options, including `OFFSIDER_DEVICE` naming a physical device and an iPhone or iPad command with no app to pin | Fix the command line; see `--help` |
| `invalid_device_id` | 64 | The device ID is empty or not a device ID | `offsider devices` |
| `invalid_setting` | 64 | An `OFFSIDER_` variable has a value Offsider cannot read | Fix or unset it |
| `unsupported_button` | 64 | The device's platform has no such button | Use a button the platform has |
| `unsupported_key` | 64 | The key has no equivalent on the device | Use a supported key |
| `unknown_display` | 64 | `--display` names no display on the device | `offsider displays --device <ID>` |
| `legacy_argument` | 64 | A renamed option or command, such as `--udid` | Use the new name in the message |
| `secure_field_argument` | 64 | `type` or a batch `type` step aimed text from the command line at a password field | Sign in with `login` and a saved test user, or pass the text with `--stdin` |
| `input_file_refused` | 64 | `type --file` or `batch --file` named a file Offsider will not read: not a regular file, over 64 KiB, or under a credentials folder such as `~/.ssh` | Pass a regular text file; `--allow-path` reads a refused location once a person confirms it |
| `not_verified` | 5 | `--verify` saw no change after the input (reports only) | Check the screen before sending again |
| `condition_not_met` | 5 | A `wait`, `assert`, `login`, `notifications --wait` or `screenshot --compare` condition was not met | Read the message. For `login`, the submit button stayed disabled |
| `command_failed` | 1 | Any failure without a more specific reason | Read `message` |
| `internal_error` | 1 | Offsider reached a state it should not | Report it |
| `input_failed` | 1 | Sending input failed | Read `dispatched` before resending |
| `input_outcome_unknown` | 1 | The input request was lost on the way and not replayed | Check the screen before resending |
| `target_covered` | 1 | A hit-test, Android's drawing order or a LogBox toast's touch area found another element over the selector's target, such as a page's control or a tab bar's padding (or `--fail-if-covered` a guessed one), or on an iOS simulator another process's prompt; nothing was sent, and `coveredBy` names it. On a simulator a target partly showing beside the cover is tapped there instead | Close the cover or wait for it with `--wait-timeout`, or answer the prompt, then retry; `--allow-covered` taps anyway |
| `target_under_keyboard` | 1 | `tap`, `type --into-id` or `login` found the keyboard over the target, still there after a second look up to 1 s later; nothing further was sent | For `tap` or `type`, hide the keyboard (on Android, `button back`) or scroll the target above it, then retry. `login` stops and does not press Back |
| `target_has_no_frame` | 1 | The match has no usable frame | Target another element |
| `target_moved` | 1 | The slider changed while it was being set | Retry when the screen is still |
| `not_a_slider` | 1 | `slider` matched something that is not a slider | Use `--element-type slider` or a narrower selector |
| `slider_unreadable` | 1 | The slider exposes no numeric value | Use `tap` or `drag` instead |
| `slider_unverified` | 1 | The slider did not reach the value | Retry, or read its value with `describe-ui` |
| `no_focused_field` | 1 | `type` (`--replace` too) or a `key-sequence` of letters, digits or punctuation found no text field with focus, or focus on something that takes no text, such as an app's own keypad; nothing was sent | Tap the field first, or use `type --into-id`; tap an app keypad's keys |
| `field_not_editable` | 1 | The focused element is not a text field | Tap the text field first |
| `unsupported_text` | 1 | The text has characters the device cannot type | Remove them, or use `type --replace` on Android |
| `secure_paste_refused` | 1 | Typing into a password field would use the clipboard | Use `type --replace` |
| `mask_unproven` | 1 | `--mask-secure` could not locate every password field, or a video's first frame could not place `--mask-region` | Retry when the screen is still |
| `tree_read_failed` | 1 | The accessibility tree could not be read | Retry; on iOS run `offsider doctor --device <ID>` |
| `no_window` | 1 | The device shows no window | Unlock it and bring an app to the front; with an app already in front, the error is `app_not_responding` |
| `screen_not_idle` | 1 | The screen did not settle for uiautomator | Retry when the screen is still |
| `screenshot_failed` | 1 | The screen could not be captured, or `--output` names something other than an image file you own | Retry, check the path, or check the device with `offsider devices` |
| `baseline_unreadable` | 1 | The `--compare` baseline cannot be read | Check the path, or capture a new baseline |
| `baseline_mismatch` | 1 | The baseline and the capture differ in size | Capture both with the same `--region` and `--scale` |
| `display_unreadable` | 1 | The display size or turn could not be read | Retry, or check the device |
| `display_off` | 1 | The requested display is off | Fold or unfold the device with `offsider posture` |
| `not_supported` | 1 | The device or platform does not support the command or option, such as a network adb device or an emulator-only feature on a phone | Use another device or option |
| `posture_failed` | 1 | The posture could not be set | Check it with `offsider posture --device <ID>` |
| `state_not_reached` | 1 | The posture or orientation did not take effect in time | Check the device, then retry |
| `orientation_unknown` | 1 | The device did not report its orientation | Check it with `describe-ui` |
| `device_restarted` | 1 | The simulator restarted while Offsider connected | Retry |
| `device_unresponsive` | 1 | The device stopped answering | `offsider doctor --device <ID>`, or restart the device |
| `device_control_failed` | 1 | A device setting could not be read or changed | Check the device is booted |
| `app_not_installed` | 1 | `logs --app`, an `app` command or an Android permission command names an app that is not installed | Install it (the `hint` names the SDK's `adb -s <serial> install <path-to-apk>` on Android), or drop `--app` |
| `link_not_handled` | 1 | `app open` sent a link no screen of the app takes (Android resolved no activity in the package, or on a simulator no app or another app claimed it) | Check the link's scheme and host against the app's URL types or intent filters, or send the app's own scheme |
| `log_stream_failed` | 1 | The device's log could not be read | Retry |
| `video_failed` | 1 | Recording or streaming video failed, `--output` names something other than a video file you own, the device could not be marked as recording, or a stop came before the first frame, so nothing was recorded | Check the output path and the private directory, then retry |
| `video_unmasked` | 1 | `record-video` or `stream-video` was asked for tree masks, the evidence run masks emails or ids, or a password field is on screen (or the screen could not be read) as it starts | Use `screenshot` for masked evidence, or pass `--unmasked` to record anyway |
| `helper_failed` | 1 | The UiAutomation helper stopped or failed | Retry; the `hint` names the log to read |
| `helper_timed_out` | 1 | The UiAutomation helper did not answer in time | Retry when the emulator responds |
| `adb_command_failed` | 1 | An adb command failed on the device, or printed more than 64 MB | Read `message` |
| `adb_protocol_error` | 1 | The adb server sent a reply Offsider could not read | Stop it with the `hint` (the SDK's `adb kill-server`), then run the command again |
| `emulator_grpc_unavailable` | 1 | The emulator's gRPC endpoint did not answer | Check the emulator is still running |
| `emulator_grpc_auth_failed` | 1 | The emulator rejected Offsider's gRPC credentials | Restart it with `offsider boot` |
| `emulator_grpc_failed` | 1 | A gRPC call to the emulator failed | Retry |
| `emulator_timed_out` | 1 | The emulator did not answer a gRPC call in time | Retry when it responds |
| `emulator_launch_failed` | 1 | The emulator could not start or exited during start-up | Read the log the message names |
| `boot_timed_out` | 1 | The emulator did not finish booting in time | Run `offsider boot` again to keep waiting |
| `hid_broker_failed` | 1 | The HID broker that sends iOS input, or an iPhone or iPad's session broker, failed | `offsider doctor --device <ID>`; on a device, `offsider session stop --device <UDID>` restarts the broker |
| `private_directory_unsafe` | 1 | The HID broker directory is not private to this user | `offsider doctor --device <ID> --fix` |
| `timed_out` | 1 | A helper process did not finish in time | Retry |
| `init_failed` | 1 | `init` could not install or remove the skill, or `guide` could not read a bundled topic | Read `message` |
| `device_list_failed` | 1 | Devices could not be listed | Read `message` for each platform |
| `expo_dev_client_failed` | 1 | `rn prepare` could not prepare the Expo dev client | Read `message` |
| `runner_build_failed` | 1 | The iPhone runner could not be built or signed, its bundled source does not match this build, its products are not signed by the team, or the device is not registered with the team | Read `message`; a person runs `offsider runner build --device <UDID> --register-device` when the hint names it |
| `runner_unavailable` | 1 | The iPhone runner did not answer; no input was sent | Retry; `offsider doctor --device <UDID>` |
| `run_active` | 1 | `run start` named another folder while this session's run is active | `offsider run stop`, then start the new run |
| `run_unavailable` | 1 | The run folder cannot be written and it would hold the only copy, the recorded folder is no longer a private directory of yours holding its `run.json`, `OFFSIDER_RUN` names an unusable folder or is `off`, or the session cannot be found | Fix the folder, `offsider run status`, or set `OFFSIDER_RUN=<dir>` |
| `focus_not_confirmed` | 5 | `type --into-id` tapped the field but it never took focus; no text was sent. On an iOS simulator the message says when no keyboard appeared, as with its hardware keyboard connected | Check the field with `describe-ui`, then retry |
| `text_not_accepted` | 5 | `type --replace` on Android left the field empty or shorter than the text, or a paste did not leave exactly the text: the app filters it, or focus moved | Check the field with `describe-ui`; type what it accepts |
| `focus_mismatch` | 2 | `type --require-focus-id` found another field (or none) focused; no text was sent | Tap the field, or use `--into-id` |
| `metro_port_not_allowed` | 7 | `rn open` found no `adb reverse` for `--port` on a USB phone, and the phone's allowance lists no such Metro port, so it set none | Ask the user to run `offsider devices add` and choose that phone and the port under Metro |
| `metro_not_running` | 9 | `rn open` found no Metro answering on 127.0.0.1 at `--port`, or, before setting a phone's adb reverse, one that does not run as this user | Start Metro on that port, then retry |
| `rn_load_failed` | 1 | `rn open` saw the app's load error or red box | Read `logs --rn` and Metro's output |
| `app_crashed` | 1 | `rn open` saw the app's process stop while it waited (the message names the crash report or the exception) | Read the report, or `logs --rn`, then open the app again |
| `app_not_responding` | 1 | On Android, the app in front on an unlocked screen has no window the tree can read, as when its main thread is stuck; `rn open` reports it after 10 s | Close the app and open it again (`rn open --restart` for a dev client), then retry |
| `logbox_inspector_open` | 1 | A `wait` or `assert` selector matched nothing while React Native's LogBox inspector, open in its own window, hid the app (on Android), for 1.5 s or on the last read | Close the inspector with `tap --label Minimize` (or `rn logbox dismiss`), then retry |
| `verify_target_present` | 1 | The `--verify-id` element was already on screen before the input, so nothing was sent (with `type --into-id`, only the tap that focused the field, when that tap brought it on screen) | Pass an id only the next screen has, or use `--verify` |
| `app_not_allowed` | 1 | The app in front is a browser or system app, the password field sits inside a web view, the app is not the one pinned for this physical device, or a phone's `logs` or `permission` named an app it may not reach; nothing was typed | Bring the app under test to the front, or ask the user to opt the app in |
| `person_required` | 1 | The step needs a person at the Mac: a terminal, Touch ID or the login password, which was missing, cancelled or unavailable over ssh; an agent turning off the password mask, `--allow-path` or a new runner prefix asks for one; `rn open` found a system prompt over the app, which it never answers; `rn devmenu perf-monitor` on Android needs the app allowed to display over other apps | Hand back to the user; do not retry |
| `turnstile_required` | 1 | `login` found a Cloudflare Turnstile widget on screen, which only a person may tick; the message says whether the form was submitted | Hand back to the user; never tap the widget or retry |
| `foreground_changed` | 1 | `login` saw a different app in front just before typing the password or tapping submit; nothing further was typed | Bring the app under test back to the front, then run `login` again |
| `install_damaged` | 1 | A file bundled with Offsider does not match this build | Reinstall Offsider: `brew reinstall offsider` |

</details>
