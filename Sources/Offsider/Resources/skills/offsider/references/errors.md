# Errors, the device lock and doctor

## Exit codes

- 0: done.
- 1: anything else. Read `dispatched`: `no` is safe to resend, `unknown` means check with `describe-ui` first, and never resend `type` text without checking the field.
- 2: the selector matched nothing. Read `candidates`, fix the selector or wait for the element.
- 3 and 4: `doctor` found warnings or failures.
- 5: the input was sent but nothing changed, or a `wait`, `assert` or compare condition was not met. Check the screen before sending again.
- 6: the selector matched several elements. Pick from `candidates`, add `--element-type` or use `--id`.
- 7: the device was not found or is not booted. Run `offsider list-devices`, or `offsider boot <AVD>` on Android. With `device_locked`, a PIN, pattern or password lock screen stayed up after `wake`, `boot` found a device waiting for its first unlock since boot, or an iPhone or iPad is locked: ask the user to unlock the device (`guide device-state`). On an iPhone or iPad, `device_not_wired`, `device_untrusted`, `developer_mode_off`, `device_preparing` and `ui_automation_off` each need the user to act on the device (`guide ios-device`).
- 8: the device is busy (see below).
- 9: Xcode, adb or the Android SDK is missing. Fix the setup; retrying will not help. For an iPhone or iPad, `xcode_too_old` means the command needs Xcode 27, `team_missing` that no signing team was found for the runner, and `usbmux_unavailable` that usbmuxd is not answering.
- 64: bad arguments. `--udid` and `list-simulators` were renamed to `--device` and `list-devices` in 0.3.0 and now exit 64 with a hint.

Resending a single command is safe after 2, 6, 7, 8, 9 and 64: nothing was sent. A batch is different, since its earlier steps may have run: exit 2 or 6 alone does not make a batch resend safe. Check the summary line's `dispatched` first (`Dispatched:` in the text output): resend the whole batch only when it is `no`; otherwise check the screen and resend from the failed step.

## Reasons to act on

- `turnstile_challenge` (exit 1): Cloudflare showed a visual challenge. Hand back to a person; never retry `turnstile` in a loop (`guide turnstile`).
- `verify_target_present` (exit 1, nothing sent): the `--verify-id` element was already on screen, so its appearing could not show the input worked. Pick an id that only the next screen has.

## JSON errors

With `--json`, every failure prints one object on stdout: `exitCode` and `error` with `reason`, `message`, `hint` (the next command), `dispatched` and `candidates`. The README lists every `reason`.

## The device lock

- One agent per device: input commands, setters (`permission`, `status-bar` and `biometric` too, but not their `show` or `status`) and `batch` lock the device for their run (on Android, so do commands that read the screen). Reads on iOS never lock.
- `--wait-lock` exists only on commands that can lock; `logs`, `displays`, `stream-video` and `record-video` reject it with exit 64.
- Exit 8 with `device_busy` means another Offsider command holds the device, and the message names its pid and command. Wait for it to finish, or rerun with `--wait-lock <seconds>` (`OFFSIDER_WAIT_LOCK` sets a default). Never resend in a loop, and never kill the holder. `offsider list-devices --json` shows each device's holder as `heldBy`.
- Exit 8 with `device_leased` comes from `lease set`: another session leased the device (`offsider lease show`). Choose another device; use `--force` only when the user says that lease is stale. Leases are advisory: other commands still run, so check `list-devices` for a `lease` before you start, and `export OFFSIDER_LEASE='<label>'` after your own `lease set` so `doctor` passes `device.lease`.
- Keep a held touch in one command (`touch --down --up`) or one `batch`: separate `touch --down` and `touch --up` commands are not protected from another agent acting in between.

## doctor

- `offsider doctor --device <DEVICE_ID> --json` checks iOS simulators and Android emulators alike. Exit 0 means every check passed, 3 means warnings and 4 means failures; read each check's `status` and follow its `hint`.
- `--fix` opens Device Hub or the device window and removes a stale HID broker directory on iOS, mounts the developer disk image on an iPhone or iPad, or starts an absent adb server on Android, then checks again.
- On an iPhone or iPad it runs the `ios-device.*` checks: Xcode, CoreDevice, the connection, trust, Developer Mode, the developer disk image, the lock state, HID input, UI Automation, the session broker, usbmuxd and runner signing. Exit 1 `hid_broker_failed` there means the session broker failed: retry once, then run `offsider session stop --device <UDID>` and retry (`guide ios-device`).
- On Android it checks the SDK, the adb server, the emulator, the screen and lock screen, stay awake, its gRPC endpoint, the UiAutomation slot and one helper start, which holds UiAutomation for about half a second; do not run it while another command drives the same emulator. On a phone it also checks whether adb authorisation lapses and whether automatic system updates can restart it.
- Every report ends with `host.load`, `host.disk` and `host.sessions`. A load warning or several other Offsider commands explain slow commands and timeouts: run one device at a time, close other emulators or builds, or give waits longer timeouts. A disk failure means boots and snapshots will fail: ask the user to free space.
- If a simulator shows repeated "quit unexpectedly" dialogs, run `offsider doctor --device <UDID>`. When `simulator.crash-loop` fails, ask the user before erasing it with the printed command, which removes its apps and settings.
- Offsider uses the Xcode that `DEVELOPER_DIR` or `xcode-select` selects, and doctor prints which. When the project builds with a different Xcode from the selected one, set the same `DEVELOPER_DIR` on every `offsider` call. If doctor reports Simulator.app running from another Xcode, follow its `DEVELOPER_DIR=...` hint before quitting anything.
