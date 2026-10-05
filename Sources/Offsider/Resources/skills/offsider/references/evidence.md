# Evidence for a report

## Masking personal data

Masks paint opaque black boxes over the image before it is written or compared, so the file never holds what they cover.

- `--mask-secure` paints password fields; `OFFSIDER_MASK_SECURE=1` turns it on by default.
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

## Pixel diffs

`screenshot --compare before.png` counts exactly which pixels changed as well as its tile verdict: `--json` adds `changedPixels`, `comparedPixels` and `changedBounds` (`{x,y,width,height}` in the image's pixels, or null). `--diff-output <png>` (a file, or a directory for a generated name) writes the capture faded to white with every changed pixel magenta and the status bar band grey, so a report can show what moved. The exit code still follows the tiles and `--threshold`: 0 changed, 5 not. A baseline of another size writes no diff.

```bash
offsider screenshot --compare before.png --diff-output diff.png --json --device <DEVICE_ID>
```

## Logs

`offsider logs` reads the last 30 s by default. Choose one source (`--rn`, `--app <bundle id or package>`, `--process <name>`) and one window (`--last 2m`, `--since <time>`, `--duration <seconds>` or `--follow`); `--grep <regex>` filters.

`--json` prints `{"version":1,"platform","device","entries":[...],"truncated"}`; each entry has `timestamp` (ISO 8601, the device's clock), `level`, `process`, `pid`, `tag`, `message` (colour codes removed unless `--raw`) and `raw`, the line as the device wrote it (a whole logcat line, or the iOS message with its colour codes), or null. With `--follow --json`, each entry is one line of its own.
