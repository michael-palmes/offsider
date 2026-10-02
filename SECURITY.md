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
- A per-user Unix socket under `$TMPDIR/offsider-hid-<uid>` for its HID broker. The broker rejects connections from any other user.
- Files you ask for: screenshots and recordings are written to `--output` or to a default name in the current directory, and `type` and `batch` read the file you pass with `--file`.
- `offsider init`, which writes its skill to `~/.claude/skills/offsider`, `~/.agents/skills/offsider` or the directory you pass with `--dest`.

For Android emulators it also touches:

- The adb server, over loopback TCP (127.0.0.1, ::1) or a Unix socket; `ADB_SERVER_SOCKET` pointing anywhere else is refused. When no server is running, Offsider starts the SDK's adb with mDNS off (`ADB_MDNS=0`), and that server keeps running afterwards like any adb server.
- The emulator's gRPC endpoint on loopback, authenticated with the token from the emulator's discovery file or with a short-lived signing key that Offsider writes to the emulator's own `jwks` folder and deletes when the command ends, whether it succeeded or failed. A key still there when Offsider exits is removed then, and a key left by a killed command is removed by the next one.
- The emulator's clipboard while `type` pastes non-ASCII text; the previous contents are restored.
- A small helper, Offsider's own code built from the Java source in this repository and checked against the hash in its manifest. Offsider pushes it to `/data/local/tmp/offsider-helper-<hash>.dex` as a copy other users can only read (mode 644), deletes older copies when it pushes a new one, and runs it with `app_process` as the shell user for one command. The helper connects to Android's UiAutomation service, so the emulator reports an accessibility service as enabled while it runs. It listens on a randomly named local socket and accepts one connection, only from the shell or root user (adb) and only when the first message carries a random token that the helper prints only on the shell stream Offsider reads; it then stops listening. It exits when the command ends, when that connection or its shell closes, or after 10 s without a request.
- When the helper cannot run, a temporary `uiautomator` dump under `/data/local/tmp` on the emulator instead, deleted after each read.
- `offsider boot`, which starts the SDK's emulator with `-no-metrics` (never `-port` or `-grpc`) and appends its output to `$TMPDIR/offsider-boot-<avd>.log`. Offsider never uses Google's Android CLI.

## Release integrity

Release binaries are signed with a Developer ID certificate, use the hardened runtime and are notarised by Apple. The hardened-runtime entitlements are the ones in [entitlements.plist](entitlements.plist); library validation is disabled so the bundled idb frameworks can load.

Each release ships a `SHA256SUMS` file and a GitHub build provenance attestation. The [README](README.md#verified-tarball) shows how to check both. The idb frameworks are built from the [michael-palmes/idb](https://github.com/michael-palmes/idb) mirror at a pinned revision that `scripts/build.sh` verifies before building. The Android helper's dex is rebuilt from its source with a pinned toolchain and compared with the committed copy in CI, and release builds check the bundled dex against its manifest.
