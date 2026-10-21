# Install

```bash
brew install michael-palmes/tap/offsider
```

You need:

- An Apple silicon Mac (arm64) on macOS 26 or later. Intel Macs are not supported.
- Xcode 26 or later, selected with `xcode-select` or `DEVELOPER_DIR`, even if you only drive Android, because the binary links the simulator frameworks. Tested on Xcode 27, where simulators run under Device Hub and Simulator.app is not required.
- For Android: the Android SDK with Platform-Tools (and the Android Emulator for emulators) and `arm64-v8a` system images, tested on API 36 (the adb fallback needs API 33 or later); screen reads, selectors and taps are also checked on Android 9, API 28. Offsider finds the SDK through `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk` (where Android Studio installs it) or `adb` on your `PATH`.
- For a physical iPhone or iPad: a USB cable. The host's Xcode decides which commands work; see [Physical iPhones and iPads](ios-devices.md).

To install the signed release tarball by hand instead, see [Verified tarball](#verified-tarball). To build from source, run `make setup` in a clone ([Building from source](building.md)).

## Verified tarball

Each release publishes `offsider-<version>-arm64.tar.gz`, a `SHA256SUMS` file and a GitHub build provenance attestation from `.github/workflows/release.yml`. The binary is signed with a Developer ID certificate, runs with library validation on (it loads only frameworks signed by the same team or by Apple) and is notarised. `--signer-workflow` and `--source-ref` check that the attestation came from the release workflow building that tag.

```bash
VERSION=0.14.0
gh release download "v${VERSION}" --repo michael-palmes/offsider \
  --pattern "offsider-${VERSION}-arm64.tar.gz" --pattern SHA256SUMS
shasum -a 256 -c SHA256SUMS
gh attestation verify "offsider-${VERSION}-arm64.tar.gz" --repo michael-palmes/offsider \
  --signer-workflow michael-palmes/offsider/.github/workflows/release.yml --source-ref "refs/tags/v${VERSION}" \
  --deny-self-hosted-runners
mkdir -p ~/.local/offsider && tar -xzf "offsider-${VERSION}-arm64.tar.gz" -C ~/.local/offsider
codesign -dv --verbose=4 ~/.local/offsider/offsider
```

Keep the `offsider` binary beside its `Frameworks/` directory and resource bundle, then put a symlink on your `PATH` rather than moving the binary:

```bash
mkdir -p ~/.local/bin
ln -s ~/.local/offsider/offsider ~/.local/bin/offsider   # ~/.local/bin must be on your PATH
offsider --version
```
