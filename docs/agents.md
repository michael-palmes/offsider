# Agents

## Agent skill and guide

`offsider init` installs one short `SKILL.md`: the core loop, the rules every session needs and a table of topics. It writes each real folder once (a `~/.claude/skills` symlinked to another client's folder counts once), says `Already up to date` when the skill matches, replaces an older Offsider skill without `--force` (which only replaces someone else's skill named offsider), and ends with `Next: offsider doctor` (a person sees a row per folder, ✅ Ready for your agents, then `Next  offsider doctor`). The depth lives in topics printed on demand by `offsider guide <topic>`, so an agent reads only what the task needs and always gets the text that matches the installed binary. `offsider guide` lists the topics and when to read each; an unknown topic exits 64.

A repository can add its own recipes for agents in an `OFFSIDER.md` (the test user tags each flow needs, never accounts; how to reach a screen; what not to tap). `offsider guide --project .` prints it, searching the path and its parents up to the repository root (the first directory holding `.git`), your home directory or `/`; it reads at most 256 KiB of UTF-8, follows a symlink only inside the repository, and exits 1 when there is none. Plain `offsider guide` names the file when it finds one from the current directory.

## What a person and an agent see

Offsider writes for one of two readers. A run is an agent's when `OFFSIDER_OUTPUT` says `agent`, else when an agent harness marks it (`CLAUDE_CODE_CHILD_SESSION=1`, or `AI_AGENT` set to anything but empty or `0`; Claude Code sets both, and `CLAUDECODE` never counts, since IDE terminals set it), else when standard output is not a terminal. `OFFSIDER_OUTPUT=person` makes a terminal opened by an agent's app read as yours; the skill tells agents never to set it to get past a check that needs a person.

An agent reads only the information:

- stdout as before: the same tables, text and JSON, byte for byte, except that `devices --json` prints on one line.
- stderr as one line per note, starting `Warning:`, `Note:`, `Error:` or `Try:`, each printed once per process, escaped and at most 4,096 characters.
- No colour, spinner, wrapping or picker: a command with no device exits 64 at once.
- Hints that work in a fresh shell: `--device <ID>` or `VAR=value offsider …`, never `export`.

```text
PLATFORM  STATE     ID                                    NAME                     OS
ios       Booted    00000000-0000-4000-8000-000000000001  "iPhone 17 Pro"          iOS 26.0
ios       Booting   00000000-0000-4000-8000-000000000003  "iPhone 17e"             iOS 26.0
ios       Shutdown  00000000-0000-4000-8000-000000000002  "iPad Air 13-inch (M3)"  iOS 26.0
android   Booted    emulator-5554                         "Pixel_9"                Android 16
android   Shutdown  Medium_Phone_API_37                   "Medium_Phone_API_37"    Android API 37
Note: emulator-5554 is leased to 'PR 123' until 15:13 (offsider lease show).
```

A person at a terminal reads the same listing as a header, rows behind status dots, notices with the command to run, and one `Next` command last, with a spinner over every pause:

```text
📱  Devices                                      3 running · 2 shut down
────────────────────────────────────────────────────────────────────────

  iOS Simulators
  ● iPhone 17 Pro          00000000-0000-4000-8000-000000000001
  ◐ iPhone 17e             00000000-0000-4000-8000-000000000003  Booting
  ○ iPad Air 13-inch (M3)  00000000-0000-4000-8000-000000000002

  Android Emulators
  ● Pixel_9                emulator-5554
  ○ Medium_Phone_API_37

📌  emulator-5554 is leased to 'PR 123' until 15:13
    See  offsider lease show

Next  offsider describe-ui --device 00000000-0000-4000-8000-000000000001
```

- Dots: `●` running, `◐` starting, `○` off, `✓` passed, `!` needs a look, `✗` failed, `-` skipped. A change ends with a ✅ receipt, input included (never the typed text or its length), and a failure with ❌, the cause in bold red and `Try  <command>`.
- Tables fit the window: they drop optional columns (such as OS) first, then cut names, then stack each row on two lines under 60 columns. IDs and commands are never cut. `COLUMNS=<n>` sets the width.
- `NO_COLOR`, `TERM=dumb` or a pipe drops colour; `NO_COLOR`, `UI_ASCII=1` or a locale that is not UTF-8 swaps marks for ASCII tags (`[OK]`, `[!]`) and dots for `* ~ o + ! x -`.

## Device lock and leases

![A timeline for one device: the first command holds it, a second command that arrives meanwhile exits 8 at once, and the same command with --wait-lock waits until the first lets go, then runs.](assets/device-lock.png)

Input commands (`tap`, `login`, `type`, `swipe`, `drag`, `touch`, `gesture`, `key`, `key-combo`, `key-sequence`, `button`, `slider`, `shake`, `batch`, `rn prepare`, and `posture`, `orientation`, `appearance`, `content-size`, `permission`, `status-bar` and `biometric` when setting a value) lock the device for their run, so two agents cannot interleave input. `login` holds that lock for the whole sign-in, and `batch` takes it once for all its steps. On Android, any command that reads the screen through the helper or `uiautomator` (`describe-ui`, `wait`, `assert`, `turnstile`, a masked `screenshot`) also locks, since Android has one UiAutomation slot. Reads on iOS (`describe-ui`, `screenshot`, `wait`, `assert`, `logs`, `displays`, `devices`, `doctor` and the getters) never lock.

A second command on a held device exits 8 with the reason `device_busy`, naming the holder's pid and command, and sends nothing. `--wait-lock <seconds>` (0 to 600) waits for the holder instead, and `OFFSIDER_WAIT_LOCK` sets that wait by default; it exists only on commands that can lock, so `logs`, `displays`, `stream-video` and `record-video` reject it with exit 64. Separate `touch --down` and `touch --up` commands each lock only for their own run, so another agent can act between them; keep a held touch in one `touch --down --up` or one `batch`. The lock is advisory: it stops other Offsider commands, not other tools.

`devices` shows who holds each device (`heldBy` in `--json`), reading the holder's record without taking the lock, so an iOS read such as `wait` polling a simulator never shows there. A record counts only while its pid is a live `offsider` process that started before it took the lock, and a command empties the record when it lets go.

Locks are files in a private per-user directory, `offsider-<uid>/locks/` under the per-user temp directory (`getconf DARWIN_USER_TEMP_DIR`), which ignores `TMPDIR` so agents with different sandboxes share one lock. When that directory cannot be used, Offsider falls back to `$TMPDIR/offsider-<uid>/`, and agents with different `TMPDIR` values then lock only among themselves. Each lock file is mode 0600 inside 0700 directories and holds only the holder's pid, command name and start time. The kernel drops a lock when its command exits, even when killed.

### Leases

`offsider lease set --device <id> --label <text>` marks a device as used by one session for `--ttl` minutes (1 to 1440, default 240), `release` ends it and `show` lists leases (`--json`). A lease is kept under the device's AVD name, phone serial or UDID, so it follows an emulator across serials, and a shut-down AVD can be leased by name. Another label's live lease exits 8 (`device_leased`) unless `--force`; the same label renews it, for the session that sets it.

`set` records the session it runs in (the agent or terminal above its shell), so `doctor --device` passes `device.lease` for any later command of that session, even from a new shell, and warns for another session, naming it, or for one that has ended. `OFFSIDER_LEASE`, when set, decides instead (a pass only when it matches the label), so two agents in one harness can tell their leases apart. When `set` finds no session to record, it says to run later commands as `OFFSIDER_LEASE='<label>' offsider …`. `--json` adds `owner` (`{pid, name, startedAt}`).

`lease check --device <id>` (`--label`, `--json`) is a read-only snapshot for scripts: 0 when the device is free or this session's, 8 (`device_leased`) while another session's lease is live, even when that session has ended (`ownerEnded` in `--json`); only `set` claims a device. Leases are advisory: input commands never read them, while `devices` shows them (`mine` in `--json` says whether a lease is this session's).

## Coming from idb, Maestro or agent-device

`offsider guide migrate` maps each tool's commands to Offsider, marking every row same, renamed, missing or by design. The most common:

| From | Offsider |
| --- | --- |
| `idb list-targets` | `devices` |
| `idb ui describe-all`, agent-device `snapshot` | `describe-ui --summary` |
| `idb ui tap X Y`, agent-device `press` | `tap -x X -y Y`, or `tap --id` and `tap --label` |
| Maestro `tapOn` | `tap --id` or `tap --label` |
| `idb ui text`, Maestro `inputText` | `type` |
| agent-device `fill`, Maestro `eraseText` | `tap` on the field, then `type --replace` |
| Maestro `assertVisible`, `extendedWaitUntil` | `assert --id`, `wait --id` |
| Maestro `waitForAnimationToEnd` | `wait --settled` |
| `idb approve`, `idb revoke` | `permission grant`, `permission revoke` |
| `idb record video`, `idb video-stream` | `record-video`, `stream-video` |

Installing and launching apps stays with `xcrun simctl` and `adb`, and Offsider keeps no element refs: selectors and the automatic device lock cover them. Between commands it keeps only what [Privacy and security](privacy.md#what-offsider-keeps-on-your-mac) lists.
