# Notice

## Fork attribution

Offsider is a fork of [AXe](https://github.com/cameroncooke/axe) v1.8.0 (commit `30f4bfa`) by Cameron Cooke, distributed under the MIT licence. The original copyright notice is kept in [LICENSE](LICENSE) alongside the copyright for Offsider's changes. Offsider is not endorsed by AXe's author.

Offsider renames the tool, package, targets, executable, bundle identifiers, environment variables and bundled agent skill, builds for Apple silicon only, and builds its simulator frameworks from its own idb mirror. [CHANGELOG.md](CHANGELOG.md) lists the changes since the fork.

## Third-party software

| Component | Licence | Copyright | How it is used |
| --- | --- | --- | --- |
| [idb](https://github.com/facebook/idb) (FBControlCore, FBSimulatorControl, FBDeviceControl, XCTestBootstrap) | MIT | Meta Platforms, Inc. and affiliates | Built from the [michael-palmes/idb](https://github.com/michael-palmes/idb) mirror at the revision pinned in `scripts/build.sh` (branch `offsider/xcode27`, tag `offsider-idb-v0.1.0`) and shipped as frameworks beside the binary |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 with the Runtime Library Exception | Apple Inc. and the Swift project authors | Statically linked into the `offsider` binary |
| gRPC Swift: [grpc-swift-2](https://github.com/grpc/grpc-swift-2), [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport), [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf) | Apache 2.0 | The gRPC Swift Project | Statically linked into the `offsider` binary (Network.framework transport only) |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Apache 2.0 with the Runtime Library Exception | Apple Inc. and the project authors | Statically linked into the `offsider` binary |
| SwiftNIO: [swift-nio](https://github.com/apple/swift-nio), [swift-nio-http2](https://github.com/apple/swift-nio-http2), [swift-nio-extras](https://github.com/apple/swift-nio-extras), [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | Apache 2.0 | The SwiftNIO Project, Apple Inc. and the SwiftNIO project authors | Statically linked into the `offsider` binary |
| [swift-atomics](https://github.com/apple/swift-atomics), [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 with the Runtime Library Exception | Apple Inc. and the Swift project authors | Statically linked into the `offsider` binary |
| Android Emulator gRPC protocol definition (`emulator_controller.proto`) | Apache 2.0 | The Android Open Source Project | Vendored and trimmed in `Sources/OffsiderAndroid/Grpc/Proto`; compiled in as generated code |

The full licence texts are in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

## Apple frameworks

Offsider loads private Xcode and CoreSimulator frameworks from the Xcode installation on your Mac at runtime. It does not redistribute them. Private headers from the idb checkout are used only at compile time and are not shipped.

## Android SDK

Offsider runs `adb` and the Android Emulator from your Android SDK at runtime. It does not redistribute them and does not use Google's Android CLI.
