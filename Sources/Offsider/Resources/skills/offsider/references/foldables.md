# Foldables and displays

- `offsider displays --device <DEVICE_ID>` lists a device's displays and marks the active one. Input, `describe-ui` and `screenshot` use the active display. `screenshot --display <id>` captures another one, and `describe-ui --display <id>` fails with a hint when that display is not active, so a script can check it reads the screen it expects.
- `describe-ui` `screen.display.id` is `main` on a device with one display, and `cover` or `inner` on every foldable (simulator, emulator or phone); `--display main` on a foldable exits 64. `screen.posture` is null unless the device folds.
- `offsider posture --device <DEVICE_ID>` reads a foldable's posture (`closed` uses the cover display, `open` the inner one). `posture open|closed|half-opened` folds an Android emulator or the iPhone Duo simulator (`--angle <0-180>` sets the hinge); it returns once the display has swapped, so read `describe-ui` again afterwards. Setting a posture is emulator-only on Android: fold a phone such as the Galaxy Z Fold by hand.
- Unfolded in portrait, the Duo's inner display is landscape-shaped (951 x 669 pt).
- Folding a Pixel emulator puts "Swipe up to continue" over the app on the cover; swipe up from the bottom edge before reading the app.

```bash
offsider displays --device <DEVICE_ID>
offsider posture open --device <DEVICE_ID>
offsider screenshot --display cover --output cover.png --device <DEVICE_ID>
```
