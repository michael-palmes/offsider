# Reading the screen

`describe-ui` prints one object. Every key is present, with `null` when a value is unknown, and `--point x,y` returns the same envelope with the element at that point as the only root. `screen` and frames are in points on iOS and dp on Android. `--display <id>` checks that the active display is the one you expect, and `--app <bundle-id>` names the app to read on a physical iPhone, iPad or Android phone.

A person and an agent read the same output; a person also sees a spinner while it reads, and its notes as styled lines on stderr.

```json
{
  "version": 2,
  "platform": "ios",
  "device": "<ID>",
  "screen": {
    "width": 402, "height": 874, "scale": 3,
    "orientation": "portrait", "rotation": 0,
    "display": { "id": "main", "platformId": "1" },
    "posture": null
  },
  "context": { "window": null, "keyboard": false, "logbox": null },
  "roots": [
    {
      "role": "button",
      "id": "BackButton",
      "label": "Back",
      "value": null,
      "frame": { "x": 16, "y": 62, "width": 44, "height": 44 },
      "enabled": true,
      "state": { "checked": null, "selected": null, "focused": null },
      "native": { "type": "Button", "role": "AXButton", "subrole": null, "roleDescription": "back button", "title": null, "help": null, "customActions": [], "contentRequired": false, "pid": 4242, "axFrame": "{{16, 62}, {44, 44}}" },
      "children": []
    }
  ]
}
```

| `screen` field | Meaning |
| --- | --- |
| `width`, `height`, `scale` | The active display in its current orientation, in points (dp on Android), and pixels per point |
| `orientation` | The shape: `portrait` or `landscape` |
| `rotation` | The device's anticlockwise turn from portrait in degrees (`0`, `90`, `180` or `270`), the number `orientation --json` prints, or `null` when the device does not say. `orientation landscape-left` gives `90` |
| `display` | The active display: `id` is `main`, `cover`, `inner` or `external`, and `platformId` is the simulator's or emulator's own ID for it |
| `posture` | `closed`, `half-opened`, `open` or `unknown` on a foldable, else `null` |

`context` is always present:

- `window` is null with the uiautomator fallback, and on iOS unless a prompt another process draws over the app is up, such as AutoFill's Save Password? after a sign-in. The app's tree holds only that prompt's empty host, so while the host is there `describe-ui` reads the middle of the screen once and names it `{"title": "Save Password?", "kind": "system", "package": "SafariViewService", "empty": false}`, without listing its buttons. On Android it names the active window: `title`, `kind` (`app`; `modal` for a dialog or a React Native `Modal`, known by another application window beneath it or by having no title, since Android leaves the activity beneath a dialog out of the list; or `system`), `package` and `empty` (true for an untitled modal spanning the screen with nothing labelled, named or actionable in it, as React Native can leave its LogBox dialog).
- `keyboard` is true while an on-screen keyboard is in the tree.
- `logbox` is null, or `{logs, inspector}` while React Native LogBox shows in a debug build.
- `presented`: on an iOS simulator `describe-ui` also reads the element at the screen's centre once, alongside the tree read. `presented` is null, or `{label, role, process}` when that element belongs to another process or is missing from the tree, such as a system picker or a view an SDK presents over the app (the label masked and cut to 40 characters, never a value or a secure field's text; the process is its executable's file name). While `window` names a system prompt, `presented` stays null, since the prompt is the element the centre read reaches.
- `staleFrame` is null, or `{id, label, frame}` when a screen-sized view the tree lists off screen holds that element, so its frame is likely out of date.
- `hidden` is null, or on Android the number of branches the helper left out as not visible to the user. `hiddenBranches` is null, or on Android up to five of them, on-screen and larger first, each `{id, label, className, frame}` with the frame in points; a label is never taken from an editable or password field, and is masked and cut to 40 characters.

The text formats print the same facts after the device line, only when they apply: `# window: Lab Toggles (modal)` (`(modal, empty)` for an empty dialog, `(system)` for a system prompt), `# keyboard shown`, `# logbox: 2 logs`, `# presented: "Cancel" from PickerService`, `# stale frame: id=sheet-host is listed off screen at (0, 10000) 402x874, but the screen's centre is inside it; check a screenshot`, `# hidden: 3 branches not visible to the user: id=drawer at (0, 0) 280x874; "Filters" at (16, 600) 360x48; ScrollView at (0, 900) 411.4x300`. Keys may be added within a version.

Labels and values that look like a one-time code after a keyword, a card number, a wallet address or a recovery phrase read `[redacted]`, `[redacted card]`, `[redacted address]` or `[redacted phrase]`; ids never change. A plain field where the tree cache last saw a password field, as a show-password toggle leaves it, reads as bullets, and an element `offsider.mask.json` names reads `[redacted]` for its value and keeps only the text the file names in its label (`Referral code. [redacted]`). When any were hidden, `redacted` and `revealed` follow `context` in JSON and text output ends `# redacted: 2 values, 1 revealed password field`. `--diff`, `--verify` change lists, `wait` and `assert` output and the elements an error names are redacted the same way, while `--has-value` and `--label-contains` compare the real text. It works by pattern, so a secret in another shape still shows.

`version` 2 added `rotation`, `display` and `posture` and made `orientation` the shape; version 1 (0.3.0) had none of the three, and its `orientation` was `portrait`, `portraitUpsideDown`, `landscape` or `landscapeFlipped`.

`role` is one of `application`, `window`, `group`, `other`, `button`, `link`, `menuItem`, `tab`, `tabBar`, `segmentedControl`, `text`, `header`, `image`, `progress`, `textField`, `secureTextField`, `searchField`, `textArea`, `switch`, `checkbox`, `radioButton`, `slider`, `picker`, `cell`, `list`, `scrollView` or `keyboard`.

<details>
<summary>Where each field comes from on iOS and Android</summary>

| Field | iOS source | Android source (UiAutomation helper) |
| --- | --- | --- |
| `roots` | The frontmost app's `application` element | The active window as `application`, labelled with its title (such as `Settings`), then the keyboard as `keyboard`, labelled with its title, while it is shown. The status and navigation bars are left out |
| `id` | `AXUniqueId` (`accessibilityIdentifier`, or `testID` in React Native), else `AXIdentifier` | `resource-id` (`testID` in React Native), else a Jetpack Compose `testTag` |
| `label` | `AXLabel` | `content-desc`, else the text of a non-editable node; a clickable node with neither takes its children's text |
| `value` | `AXValue`, as a string | A text field's text; `1` or `0` for switches, checkboxes and radio buttons, and `2` for a partly checked checkbox; a slider's or progress bar's position in its range as a percentage with up to two decimals, such as `25%` or `39.95%` |
| `frame`, `enabled` | The same keys | `bounds` over density / 160, `enabled` |
| `state.checked` | `switch` and `checkbox` only: `AXValue` `1` or `0` | `checked` for checkable nodes; `null` when partly checked |
| `state.selected`, `state.focused` | `selected` is `true` with the Selected trait and `false` without it, or `null` when the traits could not be read; `focused` is `true` on the field with keyboard focus on a physical iPhone or iPad, and always `null` on a simulator | `selected`, `focused` |
| `native` | `type`, `role`, `subrole`, `roleDescription`, `title`, `help`, `customActions`, `contentRequired`, `pid`, `axFrame` | `className`, `resourceId`, `package`, `pixelFrame`, `text`, `contentDescription`, `hint`, `stateDescription` (the spoken state, such as `25%`), `roleDescription`, `testTag` |

</details>

When Offsider falls back to `uiautomator` on Android (see [Screen reads and the helper](android.md#screen-reads-and-the-helper)), the tree has one unlabelled `application` root and no keyboard root, and sliders and progress bars have no `value`.

## Summary and text output

For a screen scan, `describe-ui --summary` prints one line per on-screen node that has a label, id or value, which is usually a small fraction of the full tree:

```text
# ios <ID> 402x874 @3x portrait 0°
application "Playground" (0,0 402x874)
  button "Save" id=save-button (170.7,313.3 61x34.3)
  group id=rows (0,400 402x474)
    button "Inbox, 3 unread" (0,400 402x56)
    [off-screen below] 34 items: id=rows-item-9 to id=rows-end
# folded 2 repeated labels
# off-screen: 34 elements folded into runs; check one with assert --label-contains <text> --allow-offscreen
```

On a foldable the header line ends with the display and posture, such as `inner open`.

`--summary` is short for `--flat --on-screen --labelled --format text --max-bytes 16384`. `--flat` lists nodes without nesting under `nodes`, each with `index`, `parent` and `depth`; `--on-screen` keeps nodes with at least 1 point on screen, judged as selectors judge it; `--labelled` keeps nodes with a label, id or value; `--actionable` keeps controls; `--fields` picks keys; `--format json|ndjson|text` picks the format, where `ndjson` prints a screen line and then one node per line; `--compact` prints JSON on one line. Without these flags the output is unchanged.

Text output (`--summary` and `--format text`) saves bytes in four ways; JSON and ndjson keep every node and label:

- A child whose label its parent already shows, whole or as one of its comma-separated parts (React Native merges `Inbox` and `3 unread` into `Inbox, 3 unread`), loses the label, and its line goes when nothing else is left (no id, value, control role or checked or selected state). A text's value equal to its label is left out. One closing `# folded N repeated labels` line counts them.
- With `--on-screen`, nodes wholly past an edge that would otherwise show are summarised where they start, per side and counting rows rather than their texts: `[off-screen below] 34 items: id=rows-item-9 to id=rows-end`, also `above`, `left` and `right`. When the items hold elements that would be listed, the count says so: `[off-screen below] 1 item (+12 inside): id=sheet-host`. Scroll that way to bring them on screen. A run's items are not listed, so a grep for one misses it: a closing `# off-screen: 34 elements folded into runs` line, which the byte budget never cuts, counts them, and `assert --label-contains <text> --allow-offscreen` checks one.
- With `--on-screen`, a screen a full-screen page is drawn over (an earlier page kept mounted under a pushed one, by Android's drawing order or iOS tree order) is left out, and a closing line counts it, which the byte budget never cuts: `# beneath: "Products" (42 elements) under "Kettle"`. Its elements are still in JSON and plain `--format text`.
- Nested lines stop indenting at 10 levels.

`--max-bytes <n>` cuts text output at whole lines (UTF-8 bytes, newline included) so it fits `n` bytes, always keeping the header and the first node, and ends with `# truncated: 87 more nodes past the 16384-byte budget; pass --max-bytes 0 for all, or narrow with --actionable`. `--summary` defaults to 16384 bytes, `--max-bytes 0` lifts the limit, plain `--format text` has none unless asked, and with JSON or ndjson `--max-bytes` is a usage error (exit 64), as is a value from 1 to 511. When the Android device stops listing nodes at its own limit, text output ends with `# the device stopped listing nodes at its limit; this tree is incomplete`.

## Changes since the last command

`describe-ui --diff` compares this read with the previous command's tree for the device (see [What Offsider keeps on your Mac](privacy.md#what-offsider-keeps-on-your-mac)) and prints only what changed, in the `--summary` view unless `--format text` and filters are given:

```text
# ios <ID> 402x874 @3x portrait 0°
# changes since tap 840 ms ago: 1 added, 1 changed, 0 removed
changed text "State: Unread" id=filter-state value="Unread" (16,120 370x44) (was: text "State: All" id=filter-state value="All" (16,120 370x44))
added button "Apply" id=apply-filters (142,640 118x34)
```

A node is named by its `id` (UUIDs normalised), else by its role, label and position on a 4 pt grid. A screen with no change prints `# unchanged since <command> <n> ms ago (<hash>)`; with no earlier tree, or when 60 or more lines or over half of them changed, the full view follows a comment saying so. After a tap the base is the tree read before the tap, so tap then `--diff` shows what the tap did. `--diff` is text only, and refused with JSON formats, `--compact` and `--point`.
