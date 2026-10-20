# Getting started

```bash
offsider list-devices --booted            # booted simulators and emulators, then a Next: line
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
offsider list-devices --platform android          # emulators and phones by serial, AVDs by name
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
  offsider list-devices    See devices and their IDs
  offsider doctor          Check this Mac is ready
  offsider init            Teach your agent to use Offsider
  offsider guide           Read a topic in depth
  offsider boot <AVD>      Start an emulator or simulator
  offsider --help          Every command and option
```

On a terminal, `list-devices` ends with one `Next:` line on stderr: `export OFFSIDER_DEVICE=<ID>` for the one booted simulator or emulator, `offsider doctor --device <ID>` once that is set, or `offsider boot <AVD or UDID>` when none is booted. It never names a physical device. `doctor` ends with `Next: offsider doctor --device <ID>` when exactly one is booted, and `init` with `Next: offsider doctor`.

Every failure prints `Error:` and the message on stderr, then the command to run next on a `Try:` line (dim on a terminal; left out with `--json`, whose `hint` carries it):

```text
Error: Simulator <UDID> is not booted (Shutdown).
Try: offsider boot <UDID>
```

On a terminal, a device command with no `--device` and no `OFFSIDER_DEVICE` asks which booted simulator or running emulator to use (`Which device? (↑↓, Enter, R rescan, Q quit)`), runs with it, and prints `Using <name> · add --device <ID> to skip this`. It never offers a phone, iPhone or iPad. `offsider boot` with no name asks which simulator or AVD to boot, and `offsider init` with two or more agents' folders asks which to install into. Without a terminal, or with `--json`, `--format` or `--compact`, the command exits 64 as before, so agents never see a menu. A picker no key reaches within 60 s closes, and the command exits 64 with the same error and the line `No device chosen within 60 s; pass --device <id>.`
