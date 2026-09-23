# Changelog

All notable changes to Offsider are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-23

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

[Unreleased]: https://github.com/michael-palmes/offsider/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/michael-palmes/offsider/releases/tag/v0.1.0
