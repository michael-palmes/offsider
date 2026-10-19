![The Offsider wordmark beside three chevrons pointing at a target on a phone's screen, with a second phone behind it trailing a USB cable, over the tagline: a hand for your agent on iOS and Android, simulated or real.](docs/assets/hero.png)

# Offsider

A hand for your agent on iOS and Android, simulated or real.

[![CI](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml/badge.svg)](https://github.com/michael-palmes/offsider/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/michael-palmes/offsider?sort=semver)](https://github.com/michael-palmes/offsider/releases/latest)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Offsider gives your coding agent eyes and hands on a phone. It reads the screen, taps, types, swipes and takes screenshots on iOS Simulators, Android Emulators, and iPhones, iPads and Android phones over USB. One command-line tool, running entirely on your Mac. [offsidercli.com](https://offsidercli.com/)

## Why Offsider

![Chevrons send the same tap to an iOS Simulator and an Android Emulator on your Mac, and along USB cables to an iPhone and an Android phone, with the same target on all four screens.](docs/assets/devices.png)

- **One tool, every device.** The same commands drive simulators, emulators and real phones.
- **Reads screens the way agents do.** `describe-ui --summary` fits a screen in a few lines, and `--diff` shows only what changed.
- **Proves the tap worked.** `--verify` waits for the screen to change, and exits 5 if it didn't.
- **Won't tap the wrong thing.** A target that's covered, off screen or under the keyboard is refused, and nothing is sent.
- **Says what to do next.** Every error has a reason, an exit code and the next command to run.
- **Knows React Native.** LogBox, the dev menu and Metro, on both platforms.
- **[Fast](#fast), [secure](#secure) and [private](#private)** with nothing to set up.

## Install

```bash
brew install michael-palmes/tap/offsider
```

You need an Apple silicon Mac on macOS 26 or later and Xcode 26 or later, plus the Android SDK for Android. [Requirements and the verified tarball](docs/install.md).

## Test a feature now

**1. Teach your agent.** Run this once, in your own terminal:

```bash
offsider init      # adds the Offsider skill to Claude Code, Codex or both
offsider doctor    # checks Xcode, your simulators and the Android SDK
```

**2. Ask for what you want tested.** In Claude Code or Codex:

> Use Offsider to test the feature on this branch on the iPhone simulator and the Android emulator. Walk through it like a user, check each step worked, save numbered screenshots to ./evidence and tell me what broke.

Your agent installs the build with your usual tools, then uses Offsider to read each screen, tap by id or label, check every step and save the evidence.

**3. Or drive it yourself.** These are the commands your agent uses:

```bash
offsider list-devices                                     # simulators, emulators and AVDs
export OFFSIDER_DEVICE=$(offsider boot "iPhone 17 Pro")   # or an AVD, such as Pixel_9
offsider describe-ui --summary                            # what's on screen
offsider tap --id search                                  # tap by id, or --label "Search"
offsider type $'kettle\n'                                 # type, then press Return
offsider tap --label "Add to cart" --verify               # exits 5 if nothing changed
offsider assert --id cart-badge --has-value 1             # exits 0 if true, 5 if not
offsider screenshot --output cart.png                     # password fields masked
```

![A tap lands on a button, then two outcomes: when the screen changed the command exits 0, and when nothing changed it exits 5.](docs/assets/verify.png)

Real iPhones and Android phones work too, once you allow each one with `offsider device-access allow`. [Getting started](docs/getting-started.md) covers Android and real devices.

## Fast

![Bars of output size for one screen: describe-ui prints 145 KB of JSON, describe-ui --compact prints 31 KB, and describe-ui --summary prints 1.5 KB, about 1 percent of the JSON.](docs/assets/summary.png)

- **Straight to the emulator.** Taps, keys and screenshots go to the Android Emulator's own gRPC endpoint on loopback, not through `adb shell`: a tap lands in 85 ms and a screenshot in 0.14 s.
- **Straight to the simulator.** Offsider reads and drives the iOS Simulator through Xcode's own simulator frameworks, with nothing installed inside it: a screen read takes 0.44 s and a screenshot 0.29 s.
- **Small reads.** A `--summary` is about 1 percent of the full JSON, and `--diff` sends only what changed, so your agent spends fewer tokens on every screen.
- **One trip for a whole flow.** `batch` sets up once, then runs every step: five steps take a quarter of the time on Android, and a third to a half on iOS.
- **Warm sessions on real devices.** On a wired iPad, a session broker keeps the screen stream and touch open between commands: a tap in about 140 ms and a screenshot in about 230 ms.

| Median | iOS Simulator | Android Emulator |
| --- | --- | --- |
| Read the screen: `describe-ui --summary` | 0.44 s | 0.27 s |
| Tap a point: `tap -x -y` | 1.8 s | 0.09 s |
| Tap by id: `tap --id` | 1.8 s | 0.28 s |
| Tap and check it worked: `tap --id --verify` | 3.0 s | 0.75 s |
| Screenshot | 0.29 s | 0.14 s |
| Screenshot, password fields masked (the default) | 0.56 s | 0.34 s |
| Five steps in one `batch` | 2.3 to 3.3 s | 0.33 s |
| The same five steps as separate commands | 6.5 s | 1.4 s |

<sub>Offsider 0.12.0 on an Apple M1 Max with Xcode 27.0, driving the React Native playground on an iOS 27 simulator and an API 36 emulator: medians of 20 runs, or 10 for the five steps. On iOS, each input command spends about 1 s opening the simulator's input session, and a `batch` pays it once. The iPad figures were measured for 0.7.0.</sub>

## Secure

Built for the question your security team will ask: what can an agent do with this, and what can't it?

![Commands to a real phone stop at a wall with exit 7 and nothing sent, until a person allows it with a fingerprint; then they reach the phone over USB only, for chosen apps and a limited time.](docs/assets/device-gate.png)

| Risk | Control |
| --- | --- |
| [An agent drives a real phone](SECURITY.md#physical-devices-the-allow-list) | Refused, with nothing sent, until a person runs `offsider device-access allow` in their own terminal and confirms with Touch ID or their password. Then it's USB only, never inside a browser or system app, pinned to one app on an iPhone, and it expires (12 hours by default). A configuration profile can cap or ban it. |
| [An agent grants itself more](SECURITY.md#scope-and-threat-model) | Allowing a device, linking a saved login, loosening one or saving an unlock code needs a person at a terminal and Touch ID or their password. No flag or variable skips it. |
| [Screen text gives the agent orders](SECURITY.md#what-reaches-your-agent) | Screen, log and notification text is treated as data: control and bidi characters print as escapes, strings stop at 500 characters, and the skill tells the agent to stop and ask. |
| [Secrets end up in output](SECURITY.md#saved-secrets) | Password fields read as bullets and are masked in screenshots, logs are redacted, and typed text never prints. Test logins live in the login Keychain, never synced. |
| [Local tampering](SECURITY.md#on-the-mac) | A private 0700 folder of 0600 files, opened without following symlinks, and sockets that refuse other users. |
| [A tampered release](SECURITY.md#release-integrity) | Signed tags, a build job with no secrets, Developer ID signing with library validation, notarisation, `SHA256SUMS` and a provenance attestation. Bundled files are checked against digests in the binary. |
| [Data leaves the Mac](SECURITY.md#network) | No telemetry, accounts or update checks. Only Unix sockets and loopback to the adb server, the emulator, usbmuxd and Metro. |

![A signed tag is built in CI, signed with a Developer ID, notarised, hashed in SHA256SUMS and attested, then installed by Homebrew on your Mac.](docs/assets/release.png)

**Check it yourself:**

```bash
OFFSIDER=$(readlink -f "$(command -v offsider)")
codesign --verify --strict --verbose=2 "$OFFSIDER"      # valid on disk, unchanged
spctl --assess --type install --verbose=2 "$OFFSIDER"   # source=Notarized Developer ID
codesign -d --entitlements - "$OFFSIDER"                # empty, so library validation stays on
offsider doctor                                         # install.bundle: bundled files match the build
lsof -nP -iTCP -a -c offsider                           # while a command runs: 127.0.0.1 only
```

[SECURITY.md](SECURITY.md) is the full threat model and lists everything Offsider touches. To check a release tarball's checksum and attestation, see [Verified tarball](docs/install.md#verified-tarball). Report a vulnerability privately through the [Security tab](https://github.com/michael-palmes/offsider/security).

## Private

![Offsider inside your Mac reaches a simulator, which shows a password field as bullets, and an emulator; its only link out is a USB cable to a phone, and a path towards the network stops at the Mac's edge.](docs/assets/privacy.png)

- **Nothing leaves your Mac.** No telemetry, no accounts and no update checks. Building the iPhone runner uses `xcodebuild`, which talks to Apple for provisioning, as Xcode does.
- **Your agent sees what the screen shows,** and that reaches its model provider. On a real phone, turn on Do Not Disturb or a Focus first.
- **Passwords stay hidden.** Password fields read as bullets, screenshots paint them black, and video won't start while one is on screen.
- **Logs are redacted.** Tokens, keys, emails, card numbers and one-time codes read `[redacted]` by default.
- **Evidence stays out of git.** Evidence runs mask emails too, and their folder gets a `.gitignore` of `*`.

See [what Offsider keeps on your Mac](docs/privacy.md#what-offsider-keeps-on-your-mac).

## Docs

- **Use it:** [Getting started](docs/getting-started.md) · [Commands](docs/commands.md) · [Reading the screen](docs/reading-the-screen.md) · [Input and checks](docs/input.md) · [Screenshots, video and logs](docs/capture.md)
- **Devices:** [Android](docs/android.md) · [iPhones and iPads](docs/ios-devices.md) · [Device access](docs/device-access.md) · [Device state and foldables](docs/device-state.md)
- **Apps:** [Sign in](docs/sign-in.md) · [React Native](docs/react-native.md)
- **Agents:** [The skill, device locks and leases](docs/agents.md)
- **When it breaks:** [Troubleshooting](docs/troubleshooting.md) · [Exit codes and errors](docs/errors.md)
- **Hack on it:** [Building from source](docs/building.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## Licence and origin

Offsider is released under the [MIT licence](LICENSE).

- Copyright (c) 2025 Cameron Cooke (AXe, from which Offsider is forked)
- Copyright (c) 2026 Michael Palmes (Offsider changes)

Offsider began as a fork of [AXe](https://github.com/cameroncooke/axe) v1.8.0 by Cameron Cooke, an iOS Simulator automation tool, used under the MIT licence. It has been developed independently since, adding Android emulators and phones, physical iPhones and iPads, and its own build, signing and release tooling. It is not endorsed by Cameron Cooke or the AXe project. Changes before the fork are in [AXe's changelog](https://github.com/cameroncooke/axe/blob/v1.8.0/CHANGELOG.md). [NOTICE.md](NOTICE.md) describes the fork and its dependencies, and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) holds their licence texts, including Meta's idb MIT licence and the Apache 2.0 licence for swift-argument-parser, the gRPC Swift packages and the vendored Android Emulator proto.

Issues and pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first. This project follows a [code of conduct](CODE_OF_CONDUCT.md).

Offsider is an independent project. It is not affiliated with, endorsed by or sponsored by Apple Inc. or Google LLC. iOS, Xcode, macOS and Simulator are trademarks of Apple Inc. Android is a trademark of Google LLC. Neither AXe nor Offsider is affiliated with, endorsed by, or associated with Deque Systems or its axe® accessibility products.
