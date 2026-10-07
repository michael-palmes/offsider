# Evidence for a report

## Runs

`offsider run start <dir> --label 'PR 123'` makes every later `screenshot`, `logs` and `batch` screenshot step from this session also write its file into `<dir>` (created 0700; an existing folder keeps its mode, with a warning when other users can write to it) as `NNN-<command>-<HH.MM.SS>.<ext>`, and adds one line per capture, failures included, to `manifest.ndjson`. End with `offsider run stop --summary` (or `--json`), which prints the timeline: one line per capture, then counts of files, failures and unrecorded files.

- A screenshot without `--output` is written only into the run, and `path` is that file; with `--output` both are written and `--json` adds `runFile`. A `logs` file holds exactly what went to stdout.
- The manifest records `--mask-text`, `--mask-label` and `--grep` values as `<N characters>`, in `args` and in batch step lines; `--mask-id` and `--mask-region` values are kept.
- `run start --mask-secure --mask-emails --mask-id <id>` masks every capture in the run, on top of the capture's own masks. `run start` again on the active folder adds masks and prints those in force; to drop one, `run stop` and start again.
- The run belongs to your session (your agent or terminal), found through the process's parents, so other agents on the Mac keep their own runs. Run commands from the same session; `run status` shows the run, `run status --all` every run.
- `run_active` (exit 1): this session already has a run in another folder; `run stop` first. `run_unavailable`: the folder cannot be written and it would hold the only copy, or no session was found; set `OFFSIDER_RUN=<dir>` to record into a folder whatever the session, or `OFFSIDER_RUN=off` to record nothing.
- A stopped run's folder continues its numbering when started again. A run whose session exits is ended as `owner-exited`.

```bash
offsider run start ./evidence --label 'PR 123' --mask-emails
offsider screenshot --device <DEVICE_ID>
offsider logs --rn --last 2m --device <DEVICE_ID>
offsider run stop --summary
```

## Masking personal data

Masks paint opaque black boxes over the image before it is written or compared, so the file never holds what they cover.

- `--mask-secure` paints password fields; add it before sharing any screen with one. `OFFSIDER_MASK_SECURE=1` turns it on by default.
- `--mask-id <id>` paints every element with that id; `--mask-label <text>` every element with that label, matched as `--label` matches.
- `--mask-text <regex>` paints the innermost elements whose label, value, title, text, content description or hint matches, case-insensitively; a secure field's value is never searched. `--mask-emails` does the same for email addresses.
- `--mask-region <x,y,w,h>` paints a rectangle in points before any `--region` crop, and reads no tree. Use it for content the tree cannot see.
- Each mask flag takes several values and can repeat. `batch` screenshot steps take the same flags and reuse the batch's tree.
- `--json` adds `masked` (rectangles painted), `maskedBy` (rectangles per kind you asked for) and `maskUnmatched` (selectors that matched nothing, also warned on stderr; the image is still written).
- An element to mask without a frame withholds the image (`mask_unproven`): retry when the screen is still.
- Masks cover what the accessibility tree describes. Web views, canvases, images, and text that appears between the tree read and the capture can still show: check the image before sharing it, and add `--mask-region` for what is left.

```bash
offsider screenshot --mask-secure --mask-emails --mask-id profile-name --json --device <DEVICE_ID>
```

## Logs

`offsider logs` reads the last 30 s by default. Choose a source (`--rn`, `--app <bundle id or package>`, both, or `--process <name>`) and one window (`--last 2m`, `--since <time>`, `--duration <seconds>` or `--follow`); `--grep <regex>` filters. `--rn --app <id>` reads React Native's log and everything the app logs, which catches an app logger writing outside React Native's; on Android it keeps the app's lines from before a restart, while `--app` alone needs the app running and reads only its current process.

Text output times are in this Mac's zone with their offset (`14:03:22.123+10:30`); `--tz utc` gives `03:33:22.123Z`. Times are the device's own clock: an Android device more than 3 s off this Mac's gets a stderr note, and `--last` and `--since` count back from its clock, so the window is right either way. iOS keeps Info and Debug entries only briefly, and a warning says when they start well after the window; read soon after the action, or collect with `--duration`.

`--json` prints `{"version":1,"platform","device","entries":[...],"truncated"}`; each entry has `timestamp` (ISO 8601 in UTC, the device's clock), `level`, `process`, `pid`, `tag`, `message` (colour codes removed unless `--raw`) and `raw`, the line as the device wrote it (a whole logcat line, or the iOS message with its colour codes), or null. With `--follow --json`, each entry is one line of its own.

Redaction is on by default for every source: `message` and `raw` read `[redacted]` where a value was masked, the JSON report adds `redacted` (the count), and stderr ends `Redacted N values (passwords, tokens, emails); --no-redact shows them.` `--grep` matches the text before redaction. `--no-redact` turns it off, as `--raw` alone does; `--raw --redact` keeps colour codes and redacts.

- A value is masked when its key (`key: value`, `key=value`, quoted or not) has a camel, snake, kebab or dot part of `password`, `passwd`, `passcode`, `pwd`, `pin`, `secret`, `token`, `authorization`, `jwt`, `ticket`, `email`, `cookie`, `otp`, `apikey` or `api` then `key`, unless its last part is `id`, `ids`, `type`, `count`, `length`, `expiry`, `expires`, `ttl`, `verified`, `enabled`, `required`, `valid`, `status` or `at` (so `tokenType` and `emailVerified` stay).
- `true`, `false`, `null`, `undefined` and objects or arrays (`token: {...}`) are left; a quoted key's bare value becomes `"[redacted]"`, so JSON still parses. `Authorization` and `Cookie` values run to the end of the header.
- `Bearer` and `Basic` credentials, JWTs (`[redacted jwt]`) and email addresses (`[redacted email]`) are masked anywhere.
- False positives: a capitalised `Basic` before a long word, and any value under a key such as `pin`. False negatives: secrets under other keys or in free text. Read a log before you share it.

## Pixel diffs

`screenshot --compare before.png` counts which pixels changed as well as its tile verdict (by 8 by 8 block on a physical iPhone or iPad, `guide screenshots`): `--json` adds `changedPixels`, `comparedPixels` and `changedBounds` (`{x,y,width,height}` in the image's pixels, or null). `--diff-output <png>` (a file, or a directory for a generated name) writes the capture faded to white with every changed pixel magenta and the status bar band grey, so a report can show what moved. The exit code still follows the tiles and `--threshold`: 0 changed, 5 not. A baseline of another size writes no diff.

```bash
offsider screenshot --compare before.png --diff-output diff.png --json --device <DEVICE_ID>
```

## Project guide

A repository can keep its own recipes for agents in `OFFSIDER.md`: test accounts, how to reach a screen, which elements to mask in a report. `offsider guide --project .` prints it, searching the path and its parents up to the repository root, your home directory or `/`, and exits 1 when there is none. Read it at the start of a session, before these generic topics.
