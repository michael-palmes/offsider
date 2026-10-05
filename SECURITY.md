# Security policy

## Supported versions

Only the latest release receives security fixes. Upgrade before reporting an issue you found on an older version.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: open the [Security tab](https://github.com/michael-palmes/offsider/security) of this repository and choose **Report a vulnerability**. Please do not open a public issue.

Include the Offsider version (`offsider --version`), your macOS and Xcode versions, and steps to reproduce. You will get an acknowledgement as soon as practical, and a fix or mitigation plan once the report is confirmed.

## What Offsider does and does not do

Offsider is a local command-line tool. It has no telemetry, no accounts and no update checks. It never connects to non-loopback addresses, never resolves hostnames and never sends telemetry. It may use Unix sockets and loopback TCP to local developer daemons (the adb server and the Android Emulator); nothing leaves your Mac.

It touches:

- Xcode's private simulator frameworks (CoreSimulator, SimulatorKit and related), loaded at runtime from the selected Xcode.
- Simulator HID input: touches, key presses, hardware buttons and text are sent to the simulator you name with `--device`.
- A per-user Unix socket under `$TMPDIR/offsider-hid-<uid>` for its HID broker. The broker rejects connections from any other user before sending them anything.
- A private per-user directory, `offsider-<uid>/` under the per-user temp directory from `confstr(_CS_DARWIN_USER_TEMP_DIR)`, which ignores `TMPDIR` (falling back to `$TMPDIR/offsider-<uid>/` when it cannot be used). It is mode 0700, owned by the user and checked on every use, and holds `locks/`: one 0600 file per device driven, opened without following symlinks, recording only the holding command's pid, name and start time, never anything from the screen. The lock is advisory and is never inherited by the processes Offsider starts.
- A tree cache in the same directory, `trees/` (mode 0700): one 0600 file per device, named by the first 16 hex digits of a SHA-256 of the platform and device ID, so device names never reach a file name. Each holds the last accessibility tree an Offsider command read from that device, as `describe-ui` prints it but without the `native` attributes (so no process IDs or class names), with password values already masked as bullets, plus the writing command's name, timestamps, the screen's size, rotation, display and posture, and a boot marker (the start time of the simulator's `launchd_sim` or the emulator process). It is written to a fresh file and renamed into place, read only when it is a regular 0600 file owned by the user (never through a symlink), capped at 1 MB, overwritten by the next command and ignored once 10 minutes old or from an earlier boot of the device. It serves `describe-ui --diff`, verify change lists and the tap guard, and is never sent anywhere. `OFFSIDER_TREE_CACHE=off` stops Offsider reading or writing it; deleting the directory is always safe.
- Secure fields: password field values are masked as bullets before any output (`describe-ui`, selectors, `--verify`, `batch`), `type` logs only the number of characters it types, and `screenshot --mask-secure` paints password fields black before writing the image. Video is never masked.
- Files you ask for: screenshots and recordings are written to `--output` or to a default name in the current directory, and `type` and `batch` read the file you pass with `--file`.
- `offsider init`, which writes its skill to `~/.claude/skills/offsider`, `~/.agents/skills/offsider` or the directory you pass with `--dest`.

For Android emulators it also touches:

- The adb server, over loopback TCP (127.0.0.1, ::1) or a Unix socket; `ADB_SERVER_SOCKET` pointing anywhere else is refused. When no server is running, Offsider starts the SDK's adb with mDNS off (`ADB_MDNS=0`), and that server keeps running afterwards like any adb server.
- The emulator's gRPC endpoint on loopback, authenticated with the token from the emulator's discovery file or with a short-lived signing key that Offsider writes to the emulator's own `jwks` folder and deletes when the command ends, whether it succeeded or failed. A key still there when Offsider exits is removed then, and a key left by a killed command is removed by the next one.
- The emulator's clipboard while `type` pastes non-ASCII text; the previous contents are restored. A paste into a focused password field is refused; `type --replace` sets that field without the clipboard. Whether the emulator's clipboard sharing copies a paste to the Mac's pasteboard has not been checked.
- A small helper, Offsider's own code built from the Java source in this repository and checked against the hash in its manifest. Offsider pushes it to `/data/local/tmp/offsider-helper-<hash>.dex` as a copy other users can only read (mode 644), deletes older copies when it pushes a new one, and runs it with `app_process` as the shell user for one command. The helper connects to Android's UiAutomation service, so the emulator reports an accessibility service as enabled while it runs. It listens on a randomly named local socket and accepts one connection, only from the shell or root user (adb) and only when the first message carries a random token that the helper prints only on the shell stream Offsider reads; it then stops listening. It exits when the command ends, when that connection or its shell closes, or after 10 s without a request.
- When the helper cannot run, a temporary `uiautomator` dump under `/data/local/tmp` on the emulator instead, deleted after each read.
- `offsider boot`, which starts the SDK's emulator with `-no-metrics` (never `-port` or `-grpc`) and appends its output to `$TMPDIR/offsider-boot-<avd>.log`. Offsider never uses Google's Android CLI.
- `stay-awake`, which writes the device's `stay_on_while_plugged_in` global setting, and `wake`, which sends `KEYCODE_WAKEUP` and `wm dismiss-keyguard`.
- Unlock codes, only when you save one with `offsider unlock-code set`, which names a connected phone by reading its `ro.product.manufacturer` and adb's listed model: the PIN or password goes in your login Keychain as a generic password (service `com.mpalmes.offsider.unlock-code`, account the phone serial or AVD name, never synchronised) and nowhere else on the Mac. `wake --unlock` reads it and types it with `input text`, once, and only into a focused password field inside System UI's lock screen, so for that moment it is in the arguments of the `input` process on the device. It never appears in Offsider's output, errors, logs or timings. After a code fails, an empty `unlock/device-<id>.failed` file in the private directory stops Offsider typing it again until the device is unlocked by hand or the code is saved again.

## Release integrity

Release binaries are signed with a Developer ID certificate, use the hardened runtime and are notarised by Apple. The hardened-runtime entitlements are the ones in [entitlements.plist](entitlements.plist); library validation is disabled so the bundled idb frameworks can load.

Each release ships a `SHA256SUMS` file and a GitHub build provenance attestation. The [README](README.md#verified-tarball) shows how to check both. The idb frameworks are built from the [michael-palmes/idb](https://github.com/michael-palmes/idb) mirror at a pinned revision that `scripts/build.sh` verifies before building. The Android helper's dex is rebuilt from its source with a pinned toolchain and compared with the committed copy in CI, and release builds check the bundled dex against its manifest.
