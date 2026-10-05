# Screenshots and video

## Capturing

- Screenshots are in pixels by default; taps and `describe-ui` frames are in points (dp on Android). Capture with `screenshot --scale points` so image coordinates are tap coordinates.
- Crop with `--region <x,y,w,h>` (points, from `describe-ui`) instead of reading a full screen. `--scale <0.1-1>`, `--format jpeg` and `--quality` shrink the file.
- `--json` prints `path`, `width`, `height`, `pixelsPerPoint`, `region`, `orientation`, `rotation`, `display` and `posture`. Landscape captures are upright.
- `screenshot --display <id>` captures a foldable's other display (`guide foldables`).
- On an Android phone, or an emulator without gRPC, `screenshot` uses `screencap -p`. `OFFSIDER_ANDROID_CAPTURE=raw` (raw `screencap` pixels) or `helper` (the UiAutomation helper) encodes the PNG on the Mac instead, falling back to `screencap -p`; both measured slower, so leave it unset.
- On a physical iPhone or iPad with Xcode 27, `screenshot` takes a frame from the device's session broker, about 230 ms; the first one starts the broker (about 3 s), and `offsider session stop --device <UDID>` ends it when you are done. Without the broker (Xcode 26, or no desktop session on the Mac) it uses `devicectl device capture screenshot`, about 2.3 s. `--verify` may take several captures there, so it is slower than on a simulator.

```bash
offsider screenshot --device <DEVICE_ID> --output screenshot.png --scale points
offsider screenshot --device <DEVICE_ID> --region <X,Y,W,H> --compare before.png
```

## Comparing regions

Content the tree cannot see (charts, maps, canvases, web views) changes pixels only. Save a baseline with `screenshot --region <x,y,w,h> --output before.png`, act, then run `screenshot --region <x,y,w,h> --compare before.png`. It exits 0 when the region changed and 5 when it did not, and prints the changed share; `--threshold <0-1>` ignores small changes. Use the same `--region` and `--scale` for both captures. `wait --region <x,y,w,h> --changed|--stable` waits on the same kind of change.

## Secure fields

Add `--mask-secure` to `screenshot` (or `batch`) before sharing an image of a screen with a password field: it paints password fields black first. A withheld screenshot means a secure field could not be located; retry when the screen is still.

## Video

- `offsider record-video --output run.mp4 --device <DEVICE_ID>` records the display to an H.264 MP4 until Ctrl+C (`--fps`, `--quality`, `--scale`).
- `offsider stream-video` streams frames to stdout (`--format mjpeg|raw|ffmpeg|bgra`, `--fps`, `--quality`, `--scale`). On Android `bgra` sends a frame only when the screen changes, and needs an emulator; use `mjpeg` on a phone. On an iPhone or iPad `bgra` is refused, and the other formats and `record-video` build each frame from a screenshot, so the frame rate is low.
