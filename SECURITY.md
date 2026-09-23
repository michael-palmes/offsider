# Security policy

## Supported versions

Only the latest release receives security fixes. Upgrade before reporting an issue you found on an older version.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: open the [Security tab](https://github.com/michael-palmes/offsider/security) of this repository and choose **Report a vulnerability**. Please do not open a public issue.

Include the Offsider version (`offsider --version`), your macOS and Xcode versions, and steps to reproduce. You will get an acknowledgement as soon as practical, and a fix or mitigation plan once the report is confirmed.

## What Offsider does and does not do

Offsider is a local command-line tool. It has no telemetry, no accounts, no update checks and makes no network requests.

It touches:

- Xcode's private simulator frameworks (CoreSimulator, SimulatorKit and related), loaded at runtime from the selected Xcode.
- Simulator HID input: touches, key presses, hardware buttons and text are sent to the simulator you name with `--udid`.
- A per-user Unix socket under `$TMPDIR/offsider-hid-<uid>` for its HID broker. The broker rejects connections from any other user.
- Files you ask for: screenshots and recordings are written to `--output` or to a default name in the current directory, and `type` and `batch` read the file you pass with `--file`.
- `offsider init`, which writes its skill to `~/.claude/skills/offsider`, `~/.agents/skills/offsider` or the directory you pass with `--dest`.

## Release integrity

Release binaries are signed with a Developer ID certificate, use the hardened runtime and are notarised by Apple. The hardened-runtime entitlements are the ones in [entitlements.plist](entitlements.plist); library validation is disabled so the bundled idb frameworks can load.

Each release ships a `SHA256SUMS` file and a GitHub build provenance attestation. The [README](README.md#verified-tarball) shows how to check both. The idb frameworks are built from the [michael-palmes/idb](https://github.com/michael-palmes/idb) mirror at a pinned revision that `scripts/build.sh` verifies before building.
