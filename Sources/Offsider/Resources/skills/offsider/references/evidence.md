# Evidence for a report

## Runs

`offsider run start <dir> --label 'PR 123'` makes every later `screenshot`, `logs` and `batch` screenshot step from this session also write its file into `<dir>` (created 0700 with a `.gitignore` of `*`, so a run inside a repository is never committed by accident; an existing folder keeps its mode and files, with a warning when other users can write to it) as `NNN-<command>-<HH.MM.SS>.<ext>`, and adds one line per capture, failures included, to `manifest.ndjson`. End with `offsider run stop --summary` (or `--json`), which prints the timeline: one line per capture, then counts of files, failures and unrecorded files.

- A screenshot without `--output` is written only into the run, and `path` is that file; with `--output` both are written and `--json` adds `runFile`. A `logs` file holds exactly what went to stdout, so filter with `logs --exclude` rather than after a pipe to keep noise out of the run.
- The manifest records `--mask-text`, `--mask-label`, `--mask-label-contains`, `--grep` and `--exclude` values as `<N characters>`, in `args` and in batch step lines; `--mask-id` and `--mask-region` values are kept.
- A run masks password fields and email addresses in every capture by default, on top of the capture's own masks and those `offsider.mask.json` names; `--mask-id <id>` adds more, and `--no-mask-secure` or `--no-mask-emails` turns one off (a warning says when password fields are not masked). `run start` again on the active folder adds only the masks its flags name and prints those in force; to drop one, `run stop` and start again. An `OFFSIDER_RUN=<dir>` folder no `run start` set up gets the same default masks. The one exception: `screenshot --mask-skip-beneath` leaves the run's email and id matches unpainted on a screen beneath a page, and its manifest line records `skippedBeneath`; password fields always stay masked.
- The run belongs to your session (your agent or terminal), found through the process's parents, so other agents on the Mac keep their own runs. Run commands from the same session; `run status` shows the run, `run status --all` every run.
- `run_active` (exit 1): this session already has a run in another folder; `run stop` first. `run_unavailable`: the folder cannot be written and it would hold the only copy, the recorded folder is no longer a private directory of yours holding its `run.json`, or no session was found; set `OFFSIDER_RUN=<dir>` to record into a folder whatever the session, or `OFFSIDER_RUN=off` to record nothing.
- A stopped run's folder continues its numbering when started again. A run whose session exits is ended as `owner-exited`. After your agent app restarts, your new session has no run: a capture notes once that the run in `<dir>` ended with its session and writes where it would with no run, so run `offsider run start <dir>` to carry on its numbering, or `offsider run status` to end it and stop the note.

```bash
offsider run start ./evidence --label 'PR 123'
offsider screenshot --device <DEVICE_ID>
offsider logs --rn --last 2m --device <DEVICE_ID>
offsider run stop --summary
```

## Masking personal data

Masks paint opaque black boxes over the image before it is written or compared, so the file never holds what they cover.

- Password fields are painted by default; a field with no frame withholds the image (`mask_unproven`). `--no-mask-secure` (or `OFFSIDER_MASK_SECURE=0`) skips the tree read, but never drops a run's mask, and from an agent it needs the user to confirm at a terminal (`person_required`). Use it only for a screen with no password field, such as an inactive display. A secret in an ordinary text field, such as a show-password toggle or a custom PIN pad, is not a password field: mask it with `--mask-id`.
- `--mask-id <id>` paints every element with that id; `--mask-label <text>` every element with that label, matched as `--label` matches, and `--mask-label-contains <text>` every element whose label holds the text.
- `--mask-text <regex>` paints the innermost elements whose label, value, title, text, content description or hint matches, case-insensitively; a secure field's value is never searched. `--mask-emails` does the same for email addresses.
- `--mask-region <x,y,w,h>` paints a rectangle in points before any `--region` crop, and reads no tree. Use it for content the tree cannot see.
- Each mask flag takes several values and can repeat. `batch` screenshot steps take the same flags and reuse the batch's tree.
- `--json` adds `masked` (rectangles painted), `maskedBy` (rectangles per kind you asked for), `maskedBeneath` (those painted for elements on a screen beneath a page, which still get painted, so a black box can sit over the page on top; also noted on stderr) and `maskUnmatched` (selectors that matched nothing, also warned on stderr; the image is still written).
- `--mask-skip-beneath` leaves matches of `--mask-id`, `--mask-label`, `--mask-label-contains`, `--mask-text`, `--mask-emails` and the run's email and id masks unpainted when their element is on a screen beneath a page; `--json` adds `skippedBeneath` per kind and stderr counts them. Password fields and `--mask-region` are always painted, and with no page found nothing is skipped. Use it only when the page on top is opaque: a translucent or animating page shows what is beneath, so check the image.
- An element to mask without a frame withholds the image (`mask_unproven`): retry when the screen is still.
- Masks cover what the accessibility tree describes. Web views, canvases, images, and text that appears between the tree read and the capture can still show: check the image before sharing it, and add `--mask-region` for what is left.
- Video takes no tree masks. `record-video` and `stream-video` read the screen once before the first frame and exit 1 with `video_unmasked`, writing nothing, when a password field or an element `offsider.mask.json` names is on screen or the read fails, and when the run masks emails or ids (start the run with `--no-mask-emails` and no `--mask-id` to allow video). The check is at the start only: a password field that appears later is recorded. Capture those steps with `screenshot` instead, or pass `--unmasked` only when the screen shows nothing private. Their `--mask-region` paints a fixed rectangle on every frame (`guide screenshots`). Video files are not numbered into the run.

```bash
offsider screenshot --mask-emails --mask-id profile-name --json --device <DEVICE_ID>
```

## Logs

`offsider logs` reads the last 30 s by default. Choose a source (`--rn`, `--app <bundle id or package>`, both, `--process <name>`, or `--all` for every app; with none it reads the app `offsider.login.json` names, else the whole device) and one window (`--last 2m`, `--since <time>`, `--duration <seconds>` or `--follow`); `--grep <regex>` keeps matching entries and `--exclude <regex>` (repeatable) drops them. Both are case-insensitive, match the message only, after colour codes are removed and after redaction (so they never match inside a hidden value), and work on both platforms in every mode; an excluded entry reaches neither stdout nor the run, and stderr says `Excluded N entries (--exclude).` `--rn --app <id>` reads React Native's log and everything the app logs, which catches an app logger writing outside React Native's; on Android it keeps the app's lines from before a restart, while `--app` alone needs the app running and reads only its current process.

Text output times are in this Mac's zone with their offset (`14:03:22.123+10:30`); `--tz utc` gives `03:33:22.123Z`. Times are the device's own clock: an Android device more than 3 s off this Mac's gets a stderr note, and `--last` and `--since` count back from its clock, so the window is right either way. iOS keeps Info and Debug entries only briefly, and a warning says when they start well after the window; read soon after the action, or collect with `--duration`.

`--json` prints `{"version":1,"platform","device","entries":[...],"truncated","redacted","excluded"}`: `truncated` counts entries `--max-lines` left out and `excluded` those `--exclude` dropped. Each entry has `timestamp` (ISO 8601 in UTC, the device's clock), `level`, `process`, `pid`, `tag`, `message` (colour codes removed unless `--raw`), `raw`, the line as the device wrote it (a whole logcat line, or the iOS message with its colour codes), or null, and `truncated`, true when the device's log cut the message. With `--follow --json`, each entry is one line of its own.

Long messages: iOS's unified log keeps about 1 KB of a message (1,015 bytes of its arguments; React Native logs each message as one argument) and ends a longer one `<…>`; the rest is never stored, so no reader can get it back. Offsider keeps the message as stored, sets the entry's `truncated` to true, ends its text line `<…> [truncated]` and says on stderr how many entries were cut. Android's logd drops what is past about 4 KB of a message with no marker, so it is not flagged. logcat prints each line of a multi-line message under its own header, and Offsider joins them into one entry, so `--grep` matches the whole message and `.` crosses its lines. For a long React Native error, see `offsider guide react-native`.

Redaction is on by default for every source: `message` and `raw` read `[redacted]` where a value was masked, the JSON report adds `redacted` (the count), and stderr ends `Redacted N values (passwords, tokens, emails, addresses, cards, phrases, codes).` `--grep` and `--exclude` match the redacted text. `--raw` keeps colour codes (never the conceal code) and still redacts; other escape sequences, newlines and control characters in a message print as escapes such as `\u001b` or `\n`, so each entry stays on one line. A read with no `--app`, `--rn` or `--process` reads every app's log and says so on stderr: name the app under test.

- A value is masked when its key (`key: value`, `key=value`, quoted or not) has a camel, snake, kebab or dot part of `password`, `passwd`, `passcode`, `pwd`, `pin`, `secret`, `token`, `authorization`, `jwt`, `ticket`, `email`, `cookie`, `otp`, `apikey`, `mnemonic`, `seed`, `passphrase`, `privatekey`, `xprv`, `totp`, `mfa`, `2fa`, `iban`, `bsb`, `cvv`, `cvc`, `ssn`, `tfn`, `passport`, `dob` or `birthday` (and similar), or a pair such as `api` then `key`, `private key`, `secret key`, `recovery phrase`, `verification code`, `account number`, `card number` or `wallet address`, unless its last part is `id`, `ids`, `type`, `count`, `length`, `expiry`, `expires`, `ttl`, `verified`, `enabled`, `required`, `valid`, `status` or `at` (so `tokenType` and `emailVerified` stay).
- `true`, `false`, `null` and `undefined` are left; an object or array value (`mnemonic: [...]`, `privateKey: {...}`) is masked whole, and a quoted key's value becomes `"[redacted]"`, so JSON still parses. `Authorization` and `Cookie` values run to the end of the header.
- `Bearer` and `Basic` credentials, JWTs (`[redacted jwt]`) and email addresses (`[redacted email]`) are masked anywhere, as are wallet addresses (`0x` hex, `bc1`, base58: `[redacted address]`), card numbers that pass the Luhn check (`[redacted card]`), runs of 12 to 24 lowercase words like a recovery phrase, or a quoted list of them (`[redacted phrase]`) and a 6-digit code just after `otp`, `code`, `pin` or `2fa`. Redacting twice changes nothing.
- False positives: a capitalised `Basic` before a long word, and any value under a key such as `pin`. False negatives: secrets under other keys or in free text. Read a log before you share it.

## Pixel diffs

`screenshot --compare before.png` counts which pixels changed as well as its tile verdict (by 8 by 8 block on a physical iPhone or iPad, `guide screenshots`): `--json` adds `changedPixels`, `comparedPixels` and `changedBounds` (`{x,y,width,height}` in the image's pixels, or null). `--diff-output <png>` (a file, or a directory for a generated name) writes the capture faded to white with every changed pixel magenta and the status bar band grey, so a report can show what moved. The exit code still follows the tiles and `--threshold`: 0 changed, 5 not, or the reverse with `--expect unchanged` (to prove a step left the screen alone); `--json` adds `expected` and `met`, and the manifest line `expect`. A baseline of another size writes no diff, and a run keeps its own `-diff.png` only when pixels changed (`--diff-output` always writes).

```bash
offsider screenshot --compare before.png --diff-output diff.png --json --device <DEVICE_ID>
```

## Project guide

A repository can keep its own recipes for agents in `OFFSIDER.md`: the test user tags each flow needs (never accounts, `guide login`), how to reach a screen, which elements to mask in a report. `offsider guide --project .` prints it, searching the path and its parents up to the repository root, your home directory or `/`, and exits 1 when there is none. Read it at the start of a session, before these generic topics.
