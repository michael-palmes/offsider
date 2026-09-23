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

Use `--check` with the same arguments and the exact same Offsider payload to regenerate into a temporary directory and compare it with the checked-in cell. The payload must be byte-identical because provenance validation includes its SHA-256.

Each cell has three parts:

- `contract.json` records stable matrix identity: schema version, Xcode version/build, runtime build, and fixture.
- `stable/` records argv, stdout, stderr, stdin where applicable, and exit status. It covers help and unknown-option behaviour for every public subcommand, plus command-specific typed validation, stdin, and output-path contracts. Hierarchy values are intentionally excluded because labels, frames, and identifiers can be fixture- or host-specific; `stable/hierarchy/schema-types.json` records normalised JSON paths and types.
- `provenance.json` records volatile run identity: the exact payload SHA-256 (`offsider_payload_sha256`), simulator UDID/device name, and the SHA-256 of the stable contract. `--check` requires the supplied payload SHA-256 and generated stable contract SHA-256 to match this file, then compares `contract.json` and `stable/`. A different simulator does not create golden churn, but a rebuilt payload must be byte-identical.

Checked-in cells record configurations on which Offsider compatibility was validated. Their exact Xcode and runtime build identifiers are provenance, not build or release requirements. Add a new matrix directory when validating another supported configuration; do not replace an existing cell to broaden the claimed support range.

These cells are manually captured compatibility evidence, not general-purpose PR regression fixtures. Capture or update them only from a clean, release-shaped, versioned Offsider payload. The `version` case intentionally records that payload's exact reported version, so a dirty development build is invalid evidence even when the remaining command output is correct. Normal Swift tests run in CI; golden capture remains a deliberate validation step for the supported Xcode/runtime matrix.
