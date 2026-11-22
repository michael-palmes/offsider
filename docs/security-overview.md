# Offsider for security teams

One page to forward. It describes the version on the first line of [SECURITY.md](../SECURITY.md), which holds the engineering detail and the file behind each control; [Privacy](privacy.md) says the same in plain words.

## In one minute

| Question | Answer | Proof |
| --- | --- | --- |
| What is it? | A command-line tool on a developer's Mac that reads and drives iOS Simulators, Android Emulators and USB iPhones, iPads and Android phones for an AI agent. No service, no account, MIT licence. | [README](../README.md), [LICENSE](../LICENSE) |
| What leaves the Mac? | Nothing from Offsider. Apple's `xcodebuild` reaches Apple to build the iPhone runner, and your agent sends what it reads to its model provider. | [What leaves the Mac](#what-leaves-the-mac); `lsof -nP -i -a -c offsider` while a command runs |
| Can an agent reach a real phone? | Not until a person adds it in their own terminal and confirms with Touch ID. Then USB only, for the apps and time that person chose. | `offsider devices add < /dev/null` exits 1, `person_required` |
| Can we lock it down? | Yes. A configuration profile turns phones off, or limits them to listed devices and apps. | [Managed Macs](mdm.md) |
| Is the release what is on GitHub? | Built from a signed tag with no secrets in reach, signed with Developer ID, notarised, attested and published as an immutable release. | [Verify an install](../SECURITY.md#verify-an-install) |
| Who maintains it? | One maintainer. Private reports through GitHub's Security tab, acknowledged within 7 days. Fixes go to the latest release only. | [Report a problem](#report-a-problem) |

## What leaves the Mac

Offsider talks only to this Mac and to devices on its USB cable. Its own code resolves no hostnames and sends no telemetry.

| Path | When | Destination | Off switch |
| --- | --- | --- | --- |
| adb server | Any Android command | 127.0.0.1 or ::1, or a Unix socket | Run no Android command |
| Emulator gRPC | Input and screenshots on an emulator | 127.0.0.1, else ::1 | `OFFSIDER_ANDROID_TRANSPORT=adb` |
| usbmuxd | Any iPhone or iPad command | `/var/run/usbmuxd`, then the USB cable | Run no iPhone or iPad command |
| CoreDevice screen stream and input | An iPhone or iPad session | The device's CoreDevice tunnel, which macOS carries over USB | `session stop` |
| Metro | `rn open` | 127.0.0.1, then [::1] only to explain a Metro bound there | Run no `rn open` |
| `xcodebuild` (Apple's tool) | Building the iPhone runner | Apple's developer services | Build no runner |
| Developer disk image (Apple's CoreDevice) | An iPhone's first command, when none is mounted, or `doctor --fix` | May reach Apple to personalise it, as Xcode does (not yet checked) | Mount it once from Xcode |
| Homebrew | `brew install` | GitHub and Homebrew's own analytics | `brew analytics off`, or the [verified tarball](install.md#verified-tarball) |
| Your agent | Whenever it runs Offsider | Its model provider | Your agent's settings |

What goes on each path, and the file that enforces it: [SECURITY.md, Network](../SECURITY.md#network).

## What an agent can do alone, and what needs a person

"A person" means someone at the Mac's terminal who confirms with Touch ID or the login password. No flag or variable stands in for them.

| Action | Agent alone | Needs a person | Try it |
| --- | --- | --- | --- |
| Read and drive a simulator or emulator | Yes | No | `offsider devices` |
| Tap a control an approved [guard](guard.md) marks `ask` | No | Yes, Touch ID at the Mac each time | `offsider guard status` |
| Add a phone, iPhone or iPad | No | Yes | `offsider devices add < /dev/null` exits 1, `person_required` |
| Drive an added phone | Inside its allowance: the apps and time the person chose | To widen it | `offsider devices status` |
| Save a test login for simulators and emulators | Yes | No | `offsider credential status` lists them |
| Let a saved login reach phones, or link it to another app | No | Yes | `offsider credential join --device <ID> < /dev/null` exits 1, `person_required` |
| Turn off the password mask, read the raw tree, or read unredacted logs or unmasked video | No | Yes | `OFFSIDER_OUTPUT=agent offsider screenshot --device <ID> --no-mask-secure --output a.png < /dev/null` exits 1, `person_required` |
| Save an Android unlock code | No | Yes | `offsider unlock-code set` needs a terminal |
| Type a saved unlock code | On an emulator or a test device | On any other phone, Touch ID each time | `offsider wake --unlock --device <ID>` |
| Register a device with your Apple team | No | Yes, in `devices add` with a team chosen, or `runner build --register-device` | `offsider runner build --device <UDID> --register-device < /dev/null` exits 1, `person_required` |
| Pair a device, tap Trust, type a passcode or connect over Wi-Fi | Never | Never | Offsider does none of these, for anyone |

A test device is a phone a person marked as holding nothing personal. On one, an agent may drive any app, browsers and Settings included, with no front-app check, and answer an app's permission prompts with `alert` ([Test devices](device-access.md#test-devices)). A configuration profile can turn test devices off.

## What stays on the Mac

| Where | Holds | Clear it |
| --- | --- | --- |
| A private 0700 folder in the per-user temp directory | Device locks, the last screen tree (masked, deleted by the next command once 10 minutes old), broker records and logs | `offsider session stop`, then delete the folder |
| `~/.config/offsider/allowed-devices.json` | The devices a person allowed, each with its expiry | `offsider devices remove` |
| `~/.config/offsider/guards.json` | The app guard rules a person approved | No command yet: delete it and its Keychain seal together |
| The login Keychain, never synced | Test logins, unlock codes, and the seals of the allow-list and the guard approvals | `offsider credential remove`, `offsider unlock-code remove` |
| `~/Library/Caches/offsider/runner/` | The iPhone runner's build | `offsider session stop --device <UDID> --clean` |
| The agent's skill folder and permission rules | What `offsider init` installed | `offsider init --uninstall` (the rules stay until you delete them) |

Every store, with where it lives and how long it lasts: [Privacy, What Offsider keeps](privacy.md#what-offsider-keeps-on-your-mac).

## What it puts on a device and in your Apple team

| Where | What | Removed by |
| --- | --- | --- |
| Android device | A helper dex in `/data/local/tmp`, Offsider's own code, checked by SHA-256 on every start | A newer helper replaces it; `adb -s <serial> shell rm /data/local/tmp/offsider-helper-*.dex` removes it |
| Android device | Settings a command changed (status bar, stay awake, permissions, airplane mode, posture) | Each command's reset; `session stop` and `devices remove` undo the airplane mode and posture Offsider set |
| Android phone | An `adb reverse` for a Metro port a person chose | `session stop`, `devices remove`, or unplugging it |
| iPhone or iPad | Two runner apps, `<prefix>.runner` and `<prefix>.runner.uitests.xctrunner` | `offsider session stop --device <UDID> --clean` |
| iPhone or iPad | A developer disk image mount, as Xcode makes | The device, when it restarts |
| Your Apple team | The runner's App IDs and provisioning profiles; a device registration only if a person chose a team in `devices add` or ran `--register-device` | Only the Apple developer site (Certificates, Identifiers & Profiles) |

`OFFSIDER_IOS_RUNNER_PREFIX` puts the runner's App IDs under your own prefix.

## Managed Macs

A configuration profile in the domain `com.mpalmes.offsider` sets a ceiling over every person's allow-list: phones off, listed devices only, listed apps only, or apps denied. Offsider reads only forced values and fails closed on a bad one. [Managed Macs](mdm.md) has the five keys, a sample profile and how to verify it.

## How a release is built and proved

- A release starts only from a tag on `main` signed by a key in `.github/allowed_signers`.
- A build job with no secrets builds an unsigned payload and its SHA-256.
- A signing job in the protected `release` environment signs it with Developer ID and notarises it, and never builds or runs it.
- A verify job on a fresh runner checks the signatures, notarisation and library validation, and runs the Homebrew gate.
- The release is published immutable with `SHA256SUMS` and a GitHub build provenance attestation; the Homebrew tap updates only through its own checked pull request.

Every job of the 0.17.0 release ran on a GitHub-hosted runner. To check a copy yourself: [Verify an install](../SECURITY.md#verify-an-install).

## What it is built from

| Component | Pinned by | Proof |
| --- | --- | --- |
| idb's simulator and device frameworks | The [michael-palmes/idb](https://github.com/michael-palmes/idb) fork of facebook/idb, at a commit `scripts/build.sh` verifies | `DEFAULT_IDB_GIT_REF` in [scripts/build.sh](../scripts/build.sh) |
| Swift packages (swift-argument-parser, grpc-swift-2 and theirs) | Exact revisions, resolved strictly | [Package.resolved](../Package.resolved) |
| The Android helper | Built from [AndroidHelper/src](../AndroidHelper/src) with a pinned JDK and build tools; CI rebuilds it and compares | `ci.yml`, "Android helper (rebuild and compare)" |
| Xcode's private frameworks | Never shipped: loaded at run time from the user's own Xcode, which must be Apple-signed | `xcode.trust` in `offsider doctor` |
| adb and the Android Emulator | Never bundled: the user's own Android SDK | `offsider doctor` |

Licences: [NOTICE.md](../NOTICE.md) and [THIRD_PARTY_LICENSES](../THIRD_PARTY_LICENSES). An SBOM is not published yet.

## Known limits and Not yet

Accepted by design (all of them: [Known limits](../SECURITY.md#known-limits)):

- A hostile process already running as you is out of scope; Touch ID is the gate.
- Masks cover what the accessibility tree describes; web views, canvases and images can still show.
- Log redaction works by pattern.
- A test device is a person's word that it holds nothing personal.
- Builds let Xcode create and renew the runner's App IDs and profiles in your team.

Deferred work (all of it: [Not yet](../SECURITY.md#not-yet)):

- An SBOM and build record in each release.
- A second reviewer on releases, and a hardware-backed tag signing key.
- Dependency scanning for Swift packages, OpenSSF Scorecard and CodeQL.
- Strict memory safety beyond the core module, and coverage-guided fuzzing.
- An audit trail of device commands.

## For your intake ticket

### OWASP Top 10 for Agentic Applications

| Item | Offsider's control | Gap |
| --- | --- | --- |
| ASI01 Agent Goal Hijack | Screen, log and notification text is escaped, capped and marked `untrusted` in JSON; the skill tells the agent to stop and ask when it asks for anything | Offsider cannot stop an agent obeying screen text; it limits what that agent can reach |
| ASI02 Tool Misuse and Exploitation | A real device needs a person's allowance, pinned to apps and a time; selector taps refuse covered targets; device locks stop two agents interleaving input; an approved `offsider.guard.json` asks before, or refuses, a costly control | No audit trail of device commands yet; no rate limit; raw `adb` or `devicectl` goes around the guard |
| ASI03 Identity and Privilege Abuse | Allowances are narrow and expire (one app for 7 days by default); widening any of them needs Touch ID; test logins stay in the login Keychain, never synced | A test device lifts the per-app limits, by a person's choice |
| ASI04 Agentic Supply Chain Vulnerabilities | Signed tags, a build with no secrets, Developer ID, notarisation, attestation, immutable releases; pinned idb fork and Swift packages; bundled files checked by digest | No SBOM yet; Swift packages are not watched for advisories |
| ASI05 Unexpected Code Execution | Offsider runs nothing a device or app sends it: no plug-ins, and `batch` files are steps, not scripts; child processes get an allow-listed environment | The agent's own shell is its harness's to limit |
| ASI06 Memory and Context Poisoning | Notes saved with test users are marked `untrusted` and refuse control and bidi characters; the screen cache is masked and swept after 10 minutes | Notes an agent writes reach later sessions, as data |
| ASI07 Insecure Inter-Agent Communication | Its brokers admit only the same user and the same Offsider build, checked by code signature; the Android helper takes one connection, with a random token | A release admits older releases signed by the same team |
| ASI08 Cascading Failures | Device locks and leases; every failure has a reason and an exit code; brokers cap request sizes and times | No circuit breaker after repeated refusals |
| ASI09 Human-Agent Trust Exploitation | The Touch ID box names the device, a whole-device reach and any team registration; `devices add` shows a summary first and never preselects "Any app" | The terminal check is a speed bump a pseudo-terminal passes; Touch ID is the gate |
| ASI10 Rogue Agents | `devices remove`, `session stop` and a profile's `allowPhysicalDevices` set to false end access; the iPhone session re-reads policy every 30 s | No signed audit trail yet |

### Questionnaire answers

```text
Telemetry: none. No telemetry, accounts or update checks. Check: lsof -nP -i -a -c offsider while a command runs shows loopback only; an iPhone session adds its sockets on the CoreDevice tunnel, which macOS carries over USB.
Data leaving the Mac: none from Offsider. Apple's xcodebuild reaches Apple to build the iPhone runner. The AI agent sends what it reads to its model provider.
Hosting: none. Offsider is a local command-line tool with no service.
Data at rest: test logins and unlock codes in the macOS login Keychain, never synced; other state in a private 0700 folder per user, ~/.config/offsider and ~/Library/Caches/offsider.
SOC 2 or ISO 27001: not applicable. There is no service to audit.
Third-party security audit: none. A read-only review of the code in October 2026 produced the changes 0.12.0 to 0.14.0 shipped.
Maintainers: one.
Licence: MIT.
Vulnerability reports: GitHub private reporting, acknowledged within 7 days; fixes for the latest release only.
Release integrity: signed tag, Developer ID signature, Apple notarisation, GitHub build provenance attestation, SHA256SUMS, immutable release.
Administrator controls: a configuration profile (domain com.mpalmes.offsider) turns phones off or limits devices and apps.
```

## Report a problem

Report a vulnerability privately through the [Security tab](https://github.com/michael-palmes/offsider/security) (**Report a vulnerability**), with `offsider --version`, your macOS and Xcode versions and steps to reproduce. One maintainer aims to acknowledge within 7 days and to have a fix or a plan within 30 days of confirming it ([Reporting a vulnerability](../SECURITY.md#reporting-a-vulnerability)).
