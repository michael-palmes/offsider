# Getting started

```bash
offsider devices --booted                 # booted simulators and emulators, then a Next line
offsider boot <simulator name or UDID>    # none booted? boot one; prints its UDID
export OFFSIDER_DEVICE=<ID>               # later commands drive it; --device <ID> overrides
offsider doctor                           # check Xcode, Device Hub and the simulator

offsider describe-ui --summary            # read the screen
offsider describe-ui --point 200,400      # or the element at one point
offsider tap -x 200 -y 400
offsider tap --id LoginButton --verify    # exits 5 if nothing changes
offsider type 'Hello world'
offsider screenshot --output ./screen.png

offsider init --client claude             # install the agent skill for Claude Code
offsider guide                            # list the skill's topics; guide <topic> prints one
```

On Android, `boot` starts an emulator and prints its serial once Android has booted; then use the same commands:

```bash
offsider devices --platform android               # emulators and phones by serial, AVDs by name
export OFFSIDER_DEVICE=$(offsider boot Pixel_9)   # --headless hides the window
offsider tap --id LoginButton --verify
offsider type 'héllo'
offsider button back
```

On a physical iPhone or iPad, connected by cable, allow it once from your own terminal, then pass its UDID and name the app to drive:

```bash
# A person picks the device, signing team, app and how long from menus, then Touch ID or your password
offsider device-access allow
# Check trust, Developer Mode, UI Automation and signing (allow prints this line with the UDID)
offsider doctor --device <UDID>
# Read the app's screen; the first read builds the runner
offsider describe-ui --summary --app com.example.app --device <UDID>
```

## First run

`offsider` on its own prints where to start:

```text
📱  Offsider                                       0.13.0
─────────────────────────────────────────────────────────

  Get started
    offsider devices     See devices and their IDs
    offsider doctor      Check this Mac is ready
    offsider init        Teach your agent to use Offsider

  Go further
    offsider boot <AVD>  Start an emulator or simulator
    offsider guide       Read a topic in depth
    offsider --help      Every command and option
```

An agent gets the same six commands as plain lines, `offsider devices` first. [What a person and an agent see](agents.md#what-a-person-and-an-agent-see) shows both views of `devices`.

On a terminal, `devices` ends with one `Next` command on stderr: `export OFFSIDER_DEVICE=<ID>` for the one booted simulator or emulator, `offsider doctor --device <ID>` once that is set, `offsider describe-ui --device <ID>` for the first of several booted, `offsider boot <AVD or UDID>` when none is booted, or `offsider doctor` when there is nothing at all. It never names a physical device, and an agent never gets it. `doctor` ends with `Next: offsider doctor --device <ID>` when exactly one is booted, and `init` with `Next: offsider doctor`.

Every failure ends with the cause and the command to run next. A person at a terminal sees ❌ and the cause in bold red, the rest of the message under it, then a `Try` line; an agent or a pipe reads `Error:` and `Try:` lines, and `--json` puts the command in `hint` instead:

```text
Error: Simulator <UDID> is not booted (Shutdown).
Try: offsider boot <UDID>
```

On a terminal, a device command with no `--device` and no `OFFSIDER_DEVICE` asks which booted simulator or running emulator to use (`Which device? (↑↓, Enter, R rescan, Q quit)`), runs with it, and prints `Using <name> · add --device <ID> to skip this`. It never offers a phone, iPhone or iPad. `offsider boot` with no name asks which simulator or AVD to boot, and `offsider init` with two or more agents' folders asks which to install into. On a list longer than nine rows or the window, `/` filters it: type words from the name, the OS or "running" (case and accents do not matter), Esc clears the filter and a second Esc quits. Every picker redraws when you resize the window. Without a terminal, for an agent, or with `--json`, `--format` or `--compact`, the command exits 64 at once, so agents never see a menu. A picker no key reaches within 60 s closes, and the command exits 64 with the same error and the line `No device chosen within 60 s; pass --device <id>.`
