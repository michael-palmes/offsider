# describe-ui

## The summary

- `offsider describe-ui --summary --device <DEVICE_ID>` prints one line per on-screen node that has a label, id or value, such as `button "Save" id=save-button (170.7,313.3 61x34.3)` (role, label, id, value, then x,y and size). Use it to find `--id` and `--label` values for selectors and to confirm coordinates.
- `--summary` is `--flat --on-screen --labelled --format text --max-bytes 16384`. Combine the parts yourself when you need more: `--flat` (no nesting; each node has `index`, `parent` and `depth`, under `nodes`), `--on-screen`, `--labelled`, `--actionable` (controls only), `--fields role,id,label,value,frame`, `--format json|ndjson|text` and `--compact` (one-line JSON). A full screen can hold hundreds of nodes, many of them off screen, so reach for plain `describe-ui` only when you need the whole tree.
- `--summary` folds labels a parent already shows (`# folded N repeated labels` closes the output), and lists rows past an edge as one line per side, such as `[off-screen below] 34 items: id=rows-item-9 to id=rows-end`: scroll that way to reach them.
- A screen a full-screen page covers is left out of `--summary` and counted at the end, past any truncation: `# beneath: "Assets" (42 elements) under "Bitcoin"`. Its elements are beneath the page, so a tap there would land on the page; selectors prefer the page's own matches, and JSON still lists everything.
- It stops at 16384 bytes with a `# truncated: N more nodes` line; pass `--max-bytes 0` for everything, or narrow with `--actionable`. `# the device stopped listing nodes at its limit` means the Android tree itself is incomplete.
- `offsider describe-ui --point <X,Y> --device <DEVICE_ID>` inspects the element at a coordinate.
- Lines after the device line say what surrounds the elements, only when it applies: `# window: <title> (modal)` or `(system)` on Android when a dialog, a React Native `Modal` or a system window is in front (only its elements are listed), `# keyboard shown` while a keyboard is up (dismiss it before tapping near the bottom; an iOS 27 simulator lists no keyboard element, so Offsider reads its key layout group, id `UIKeyboardLayoutStar Preview`, as role `keyboard`, and a hardware keyboard shows no header), and `# logbox: 2 logs` or `# logbox: inspector open` in a React Native debug build. JSON carries them as `context` (`window`, `keyboard`, `logbox`).

## What changed

After an action, `describe-ui --diff` prints only what changed since the previous command's tree: `added`, `changed ... (was: ...)` and `removed` lines, or the full view when most of the screen changed. After a tap it compares with the screen before the tap. `unchanged since tap 840 ms ago` means the screen matches that earlier tree exactly: the action had no visible effect yet, so wait or check the target rather than re-reading. Text only.

## JSON

- Without those flags the output is `{"version": 2, "platform", "device", "screen", "roots": [...]}`. Each node has `role`, `id`, `label`, `value`, `frame`, `enabled`, `state` (`checked`, `selected`, `focused`), `native` and `children`; every key is present, with `null` when unknown. `--point` returns the same envelope with the hit element as the only root.
- `role` is one of `application`, `window`, `group`, `other`, `button`, `link`, `menuItem`, `tab`, `tabBar`, `segmentedControl`, `text`, `header`, `image`, `progress`, `textField`, `secureTextField`, `searchField`, `textArea`, `switch`, `checkbox`, `radioButton`, `slider`, `picker`, `cell`, `list`, `scrollView` or `keyboard`.
- `native` keeps the platform attributes, such as the iOS `type` (`TextField`, `RadioButton`), `role` (`AXButton`) and `roleDescription`.
- Password and other secure fields read as bullets, one per character.
- `screen.orientation` is the shape (`portrait` or `landscape`) and `screen.rotation` the device's turn in degrees anticlockwise from portrait (portrait 0, landscape-left 90, portrait-upside-down 180, landscape-right 270), the same as `orientation --json` `rotation`. `screen.display.id` is `main`, or `cover` or `inner` on a foldable, and `screen.posture` is null unless the device folds.
- `--display <id>` fails with a hint when that display is not active (`guide foldables`).
