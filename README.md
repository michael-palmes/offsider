# Offsider

A hand for your agent on the iOS Simulator.

[![CI](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml/badge.svg)](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/michael-palmes/offsider?sort=semver)](https://github.com/michael-palmes/offsider/releases/latest)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Offsider is a command-line tool that inspects and drives iOS Simulators: describe the UI through accessibility, tap, type, swipe, press buttons and capture screenshots or video. It is built for terminals, scripts and AI coding agents, and it runs entirely on your Mac.

Offsider is a fork of [AXe](https://github.com/cameroncooke/axe) v1.8.0 by Cameron Cooke, used under the MIT licence. It is not endorsed by AXe's author. See [Licensing and attribution](#licensing-and-attribution).

## Install

### Homebrew

```bash
brew install michael-palmes/tap/offsider
```

### Verified tarball

Each release publishes `offsider-<version>-arm64.tar.gz`, a `SHA256SUMS` file and a GitHub build provenance attestation from `.github/workflows/release.yml`. The binary is signed with a Developer ID certificate and notarised.

```bash
VERSION=0.1.0
gh release download "v${VERSION}" --repo michael-palmes/offsider \
  --pattern "offsider-${VERSION}-arm64.tar.gz" --pattern SHA256SUMS
shasum -a 256 -c SHA256SUMS
gh attestation verify "offsider-${VERSION}-arm64.tar.gz" --repo michael-palmes/offsider
mkdir -p ~/.local/offsider && tar -xzf "offsider-${VERSION}-arm64.tar.gz" -C ~/.local/offsider
codesign -dv --verbose=4 ~/.local/offsider/offsider
```

Keep the `offsider` binary beside its `Frameworks/` directory and resource bundle, then put a symlink on your `PATH` rather than moving the binary:

```bash
mkdir -p ~/.local/bin
ln -s ~/.local/offsider/offsider ~/.local/bin/offsider   # ~/.local/bin must be on your PATH
offsider --version
```

## Requirements

- Apple silicon (arm64). Intel Macs are not supported.
- macOS 15 or later.
- Xcode 26 or later, selected with `xcode-select` or `DEVELOPER_DIR`. Tested on Xcode 27, where simulators run under Device Hub and Simulator.app is not required.

## Quick start

```bash
# Find a booted simulator and keep its UDID
offsider list-simulators
export UDID=<UDID>

# Check Xcode, Device Hub and the simulator before driving it
offsider doctor --udid "$UDID"

# Inspect the current screen, or the element at one point
offsider describe-ui --udid "$UDID"
offsider describe-ui --point 200,400 --udid "$UDID"

# Interact
offsider tap -x 200 -y 400 --udid "$UDID"
offsider tap --id LoginButton --udid "$UDID"
offsider type 'Hello world' --udid "$UDID"
offsider screenshot --output ./screen.png --udid "$UDID"

# Install the Offsider skill for Claude Code
offsider init --client claude
```

Most input commands confirm that the event was dispatched to the simulator, not that the app acted on it. Check the outcome with `describe-ui` or `screenshot`. `slider` is the exception: it reads the value back and fails if it is out of tolerance. If input seems to be ignored, run `offsider doctor --udid "$UDID"`.

## Commands

Every simulator command takes `--udid <UDID>`. Run `offsider <command> --help` for the full list of options.

| Command | What it does |
| --- | --- |
| `list-simulators` | List available simulators and their UDIDs |
| `doctor` | Check Xcode, Device Hub, CoreSimulator, HID settings and booted simulators, and with `--udid` a simulator's state, Resize Mode, dtuhidd, HID transport and accessibility; `--json` prints one object, `--fix` applies safe fixes |
| `describe-ui` | Print the accessibility hierarchy of the screen, or only the element at `--point x,y` |
| `init` | Install the bundled agent skill (`--client auto\|claude\|agents`, `--dest`, `--force`, `--uninstall`, `--print`) |
| `tap` | Tap a point (`-x`, `-y`) or an element by `--id`, `--label` or `--value`; supports `--element-type`, `--wait-timeout`, `--tap-style` and delays |
| `slider` | Set a slider to `--value` 0 to 100 by `--id` or `--label`, then verify the result |
| `type` | Type US keyboard text from an argument, `--stdin` or `--file` |
| `swipe` | Swipe from `--start-x`/`--start-y` to `--end-x`/`--end-y`, with optional `--duration` and `--delta` |
| `drag` | Low-level point-to-point drag using explicit touch moves (`--duration`, `--steps`) |
| `gesture` | Run a preset: `scroll-up`, `scroll-down`, `scroll-left`, `scroll-right`, `swipe-from-left-edge`, `swipe-from-right-edge`, `swipe-from-top-edge`, `swipe-from-bottom-edge` |
| `touch` | Send touch down and/or up at `-x`/`-y` (`--down`, `--up`, `--delay`) |
| `button` | Press a hardware button: `home`, `lock`, `side-button`, `siri`, `apple-pay` (optional `--duration`) |
| `key` | Press one HID keycode (0 to 255), optionally held for `--duration` |
| `key-sequence` | Press comma-separated `--keycodes` in order, with an optional `--delay` |
| `key-combo` | Press `--key` while holding comma-separated `--modifiers` |
| `batch` | Run ordered steps in one simulator session from `--step`, `--file` or `--stdin`; supports `--wait-timeout`, `--ax-cache`, `--continue-on-error` and `sleep` steps |
| `screenshot` | Save a PNG of the simulator display (`--output`) |
| `record-video` | Record the display to an H.264 MP4 until Ctrl+C (`--output`, `--fps`, `--quality`, `--scale`) |
| `stream-video` | Stream frames to stdout as `mjpeg`, `raw`, `ffmpeg` or `bgra` (`--format`, `--fps`, `--quality`, `--scale`) |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success; for `doctor`, every check passed or was skipped |
| 1 | The command failed; the error is printed to stderr |
| 3 | `doctor` found warnings |
| 4 | `doctor` found failures |
| 64 | Invalid arguments or options |

## Privacy

Offsider has no telemetry, no accounts and makes no network requests. It talks to simulators on your Mac through Xcode's frameworks and writes only the files you ask for. See [SECURITY.md](SECURITY.md) for what it touches.

## Building from source

Building needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [jq](https://jqlang.org) (`brew install xcodegen jq`).

```bash
make frameworks   # clone the pinned idb revision and build its XCFrameworks
swift build       # build the offsider executable
swift test        # unit tests; simulator suites are skipped
make e2e          # rebuild everything and run the simulator end-to-end suites
```

The simulator frameworks come from [michael-palmes/idb](https://github.com/michael-palmes/idb), a mirror of facebook/idb with Cameron Cooke's Xcode 27 changes on the `offsider/xcode27` branch (tag `offsider-idb-v0.1.0`). `scripts/build.sh` pins the exact revision and verifies it before building.

## Contributing and security

Issues and pull requests are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first. Fixes that apply to AXe as well are best proposed upstream. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md). This project follows a [code of conduct](CODE_OF_CONDUCT.md).

## Licensing and attribution

Offsider is released under the [MIT licence](LICENSE).

- Copyright (c) 2025 Cameron Cooke (AXe, from which Offsider is forked)
- Copyright (c) 2026 Michael Palmes (Offsider changes)

[NOTICE.md](NOTICE.md) describes the fork and its dependencies. Third-party licence texts, including Meta's idb MIT licence and the Apache 2.0 licence for swift-argument-parser, are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Changes before the fork are recorded in [AXe's changelog](https://github.com/cameroncooke/axe/blob/v1.8.0/CHANGELOG.md).

## Trademarks and affiliation

Offsider is an independent project. It is not affiliated with, endorsed by or sponsored by Apple Inc. iOS, Xcode, macOS and Simulator are trademarks of Apple Inc.

Offsider is not endorsed by Cameron Cooke or the AXe project.

Carried over from AXe because of the shared lineage: AXe is an independent open-source iOS Simulator automation project and is not affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products. The same applies to Offsider.
