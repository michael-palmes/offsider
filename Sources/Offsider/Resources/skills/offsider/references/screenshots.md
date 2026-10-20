# Screenshots and video

## Capturing

- Screenshots are in pixels by default; taps and `describe-ui` frames are in points (dp on Android). Capture with `screenshot --scale points` so image coordinates are tap coordinates.
- Crop with `--region <x,y,w,h>` (points, from `describe-ui`) instead of reading a full screen. `--scale <0.1-1>`, `--format jpeg` and `--quality` shrink the file.
- `--json` prints `path`, `width`, `height`, `pixelsPerPoint`, `region`, `orientation`, `rotation`, `display` and `posture`. Landscape captures are upright.
- `screenshot --display <id>` captures a foldable's other display (`guide foldables`).
- On Android, a plain `screenshot` (PNG, native scale, no `--region`, masks, `--compare`, `--display` or `--json`) writes the device's PNG as it came, with no screen read. On a foldable phone the first capture learns the active panel and keeps it in a small private cache, so the next command captures that panel at once and checks it against its size and the device state read alongside; `OFFSIDER_DISPLAY_CACHE=off` turns that off.
- On an Android phone, or an emulator without gRPC, `screenshot` uses `screencap -p`. `OFFSIDER_ANDROID_CAPTURE=raw` (raw `screencap` pixels) or `helper` (the UiAutomation helper) encodes the PNG on the Mac instead, falling back to `screencap -p`; both measured slower, so leave it unset.
- On a physical iPhone or iPad, every capture first checks that the pinned app is in front (`app_not_allowed` otherwise). With Xcode 27, `screenshot` takes a frame from the device's session broker, about 230 ms; the first one starts the broker (about 3 s), and `offsider session stop --device <UDID>` ends it when you are done. Without the broker (Xcode 26, or no desktop session on the Mac) it uses `devicectl device capture screenshot`, about 2.3 s. `--verify` may take several captures there, so it is slower than on a simulator.

```bash
offsider screenshot --device <DEVICE_ID> --output screenshot.png --scale points
offsider screenshot --device <DEVICE_ID> --region <X,Y,W,H> --compare before.png
```

## Comparing regions

Content the tree cannot see (charts, maps, canvases, web views) changes pixels only. Save a baseline with `screenshot --region <x,y,w,h> --output before.png`, act, then run `screenshot --region <x,y,w,h> --compare before.png`. It exits 0 when the region changed and 5 when it did not (`--expect unchanged` reverses that, to check a step changed nothing), and prints the changed share; `--threshold <0-1>` ignores small changes. It also counts the changed pixels, and `--diff-output <png>` writes an image of where they are (`guide evidence`). On a physical iPhone or iPad the pixel counts are block-based: a pixel counts as changed only when the mean colour of its 8 by 8 block moved by more than the stream's noise, so whole blocks are counted and marked. Use the same `--region` and `--scale` for both captures. `wait --region <x,y,w,h> --changed|--stable` waits on the same kind of change.

## Secure fields and personal data

`screenshot` paints password fields black by default, after one tree read. `--no-mask-secure` (or `OFFSIDER_MASK_SECURE=0`) skips it for a screen with none, but from an agent it needs the user to confirm at a terminal (`person_required` otherwise): keep the mask. A repository's `offsider.mask.json` names more to paint (ids, labels, label text, value patterns, emails) in every screenshot, batch step and evidence run; its masks always apply, and its values read `[redacted]` in `describe-ui`. Before sharing an image with personal data, mask that too: `--mask-id`, `--mask-text`, `--mask-emails` and `--mask-region` are in `offsider guide evidence`, as is `--mask-skip-beneath`, which leaves matches on a screen beneath an opaque page unpainted.

## Video

- `offsider record-video --output run.mp4 --device <DEVICE_ID>` records the display to an H.264 MP4 until Ctrl+C (`--fps`, `--quality`, `--scale`). A generated file name is never written over; `--output` replaces only an image or video file of yours. Frames are upright, as screenshots are. `--json` prints `path`, `frames`, `heldFrames`, `maskedBy` and `unmasked` when it ends.
- `offsider stream-video` streams frames to stdout (`--format mjpeg|raw|ffmpeg|bgra`, `--fps`, `--quality`, `--scale`). On Android `bgra` sends a frame only when the screen changes, and needs an emulator; use `mjpeg` on a phone. On an iPhone or iPad `bgra` is refused, and the other formats and `record-video` build each frame from a screenshot, so the frame rate is low.
- Video is never masked by the tree. `--mask-secure`, `--mask-id`, `--mask-label`, `--mask-label-contains`, `--mask-text` and `--mask-emails` exit 1 with `video_unmasked` and write nothing, as does a recording while the evidence run masks emails or ids, or when a password field or an element `offsider.mask.json` names is on screen as it starts (checked once, not on every frame). `record-video` also exits 8 while `login` or `wake` holds the device. Take masked evidence with `screenshot` instead; `--unmasked` records anyway, with a warning, so use it only when the screen shows nothing private (beside a tree mask flag it is a usage error).
- `--mask-region <x,y,w,h>` (points, repeatable) paints a rectangle black on every frame, and `bgra` refuses it. The screen's orientation is read after every capture, which slows frames (about 5 a second on an Android emulator), and a frame taken while the screen turned or resized repeats the last masked frame (`heldFrames`); when the first frame cannot place a region, nothing is recorded (`mask_unproven`). Keep the screen in one orientation while you record.
