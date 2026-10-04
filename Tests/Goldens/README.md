# Compatibility Goldens

Each child directory is one explicit Xcode/runtime matrix cell. The directory name must identify the selected Xcode and simulator runtime builds, for example `xcode-27.1-27A9269_ios-27.0-24A434`. No cells are checked in yet; the first one will be captured from a signed Offsider release payload.

Regenerate a cell with the exact release-shaped payload and a booted simulator containing OffsiderPlayground:

```bash
scripts/regenerate-goldens.sh \
  --offsider /absolute/path/to/offsider \
  --developer-dir /Applications/Xcode-27.1.0.app/Contents/Developer \
  --udid SIMULATOR_UDID \
  --matrix-id xcode-27.1-27A9269_ios-27.0-24A434 \
  --update
```

The script's own `--udid` picks the simulator for `simctl`; the Offsider commands it captures receive that ID as `--device`.

Use `--check` with the same arguments and the exact same Offsider payload to regenerate into a temporary directory and compare it with the checked-in cell. The payload must be byte-identical because provenance validation includes its SHA-256.

Each cell has three parts:

- `contract.json` records stable matrix identity: schema version, Xcode version/build, runtime build, and fixture.
- `stable/` records argv, stdout, stderr, stdin where applicable, and exit status. It covers help and unknown-option behaviour for every public subcommand, plus command-specific typed validation, stdin, output-path and rename-hint contracts. Hierarchy values are intentionally excluded because labels, frames, and identifiers can be fixture- or host-specific; `stable/hierarchy/schema-types.json` records the normalised JSON paths and types of the neutral describe-ui schema (`version`, `platform`, `device`, `screen`, `roots` and each node's neutral and `native` keys).
- `provenance.json` records volatile run identity: the exact payload SHA-256 (`offsider_payload_sha256`), simulator UDID/device name, and the SHA-256 of the stable contract. `--check` requires the supplied payload SHA-256 and generated stable contract SHA-256 to match this file, then compares `contract.json` and `stable/`. A different simulator does not create golden churn, but a rebuilt payload must be byte-identical.

Checked-in cells record configurations on which Offsider compatibility was validated. Their exact Xcode and runtime build identifiers are provenance, not build or release requirements. Add a new matrix directory when validating another supported configuration; do not replace an existing cell to broaden the claimed support range.

These cells are manually captured compatibility evidence, not general-purpose PR regression fixtures. Capture or update them only from a clean, release-shaped, versioned Offsider payload. The `version` case intentionally records that payload's exact reported version, so a dirty development build is invalid evidence even when the remaining command output is correct. Normal Swift tests run in CI; golden capture remains a deliberate validation step for the supported Xcode/runtime matrix.

## Tree goldens

`trees/` is not a matrix cell. It holds scrubbed accessibility trees of the React Native playground, one directory per screen at `trees/<platform>/<screen>/` (`<screen>@<state>` for a second state, such as `toolbar-picker-test@unread`), each with four files:

- `raw.json`: the platform's own reply before mapping (the idb accessibility JSON on iOS, the UiAutomation helper's dump on Android) beside the describe-ui `screen`, as the hidden `describe-ui --raw-source` prints it, stored as compact JSON with sorted keys. The Android dump's `timings`, `stats` and `eventSeq` change on every read and play no part in the mapping, so the capture and the refresh leave them out.
- `describe-ui.json`, `summary.txt` and `text.txt`: what the current mapping and renderer make of it as JSON, `--summary` and `--format text`.

`swift test` checks that each raw capture still maps to its committed files, that the JSON decodes and re-encodes byte for byte, and that no file holds a device UDID, an emulator serial, a home path, the user name, an email address, a host address or a readable secure value. A mapping or renderer change shows up as a reviewed diff: `OFFSIDER_GOLDENS_UPDATE=1 swift test --filter TreeGoldenRefresh` re-renders the derived files offline and rewrites each `raw.json` in the compact format.

`trees/budgets.json` gives each screen's `--summary` and `--format text` size in bytes, set at capture to the real size rounded up to the next 64 bytes. A rendering over its budget fails, and so does a budget more than 20 percent above the real size (or above its 64-byte rounding, for small outputs), so savings are kept. Raising a budget is a reviewed edit of `budgets.json`; the refresh only ever lowers one.

Recapture from a device with the React Native suite variables (`test-runner.sh --help` lists them) plus `OFFSIDER_GOLDENS_UPDATE=1`, filtering to `TreeGoldenCaptureTests`. iOS uses `OFFSIDER_RN_E2E=1`, `OFFSIDER_RN_IOS_APP` and `SIMULATOR_UDID` of an Offsider-tagged simulator (the iOS goldens come from an iPhone 18 Pro simulator on iOS 27.0, at 402 x 874 points); Android uses `OFFSIDER_ANDROID_E2E=1`, `OFFSIDER_ANDROID_DEVICE` and `OFFSIDER_ANDROID_APK`, and drives only the allowed AVDs (the Android goldens come from `Offsider_E2E_Pixel_9`, a Pixel 9 AVD on the Android 16 (API 36) Google APIs 16 KB page arm64-v8a image, build BE2A.250530.026.F3, at 411.4 x 923.4 points). The capture waits for two equal reads, scrubs ids, serials and home paths, sets the iOS `pid` to 1000 and refuses a secure field with a readable value. `rows-test` is captured with live updates paused, so only its download percentage changes between captures.
