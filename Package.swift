// swift-tools-version:6.2
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let idbCheckoutDirectory = ProcessInfo.processInfo.environment["IDB_CHECKOUT_DIR"]
    .map { URL(fileURLWithPath: $0) }
    ?? packageRoot.appendingPathComponent("idb_checkout", isDirectory: true)
let idbPrivateHeadersDirectory = idbCheckoutDirectory.appendingPathComponent(
    "PrivateHeaders",
    isDirectory: true
)
// Compile-only module-map inputs: never copy these headers into release artifacts or runtime rpaths.
let idbPrivateHeaderSearchFlags = [
    idbPrivateHeadersDirectory,
    idbPrivateHeadersDirectory.appendingPathComponent("AccessibilityPlatformTranslation", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("AXRuntime", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimDeviceIO", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulator", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("CoreSimulatorUtilities", isDirectory: true),
    idbPrivateHeadersDirectory.appendingPathComponent("SimulatorKit", isDirectory: true),
// Keep each search path in one token. SwiftPM can otherwise drop the path while propagating
// unsafe flags to its generated test runner, leaving a bare `-I` that consumes the next option.
].map { "-I\($0.path)" }

let package = Package(
    name: "Offsider",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OffsiderCore",
            targets: ["OffsiderCore"]
        ),
        .executable(
            name: "offsider",
            targets: ["Offsider"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // Exact pins: the checked-in generated gRPC code must match the runtime it was generated for.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.3"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.10.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.4.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(
            name: "OffsiderCore",
            path: "Sources/OffsiderCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .strictMemorySafety()
            ]
        ),
        .target(
            name: "OffsiderAndroid",
            dependencies: [
                "OffsiderCore",
                // Never the umbrella GRPCNIOTransportHTTP2 or the Posix product, which pull in NIOSSL and BoringSSL.
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/OffsiderAndroid",
            exclude: ["Grpc/Proto"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "OffsiderIOSDevice",
            dependencies: ["OffsiderCore"],
            path: "Sources/OffsiderIOSDevice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Offsider",
            dependencies: [
                "OffsiderCore",
                "OffsiderAndroid",
                "OffsiderIOSDevice",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "FBSimulatorControl",
                "FBDeviceControl",
                "FBControlCore",
                "XCTestBootstrap"
            ],
            path: "Sources/Offsider",
            resources: [
                .copy("Resources/skills"),
                .copy("Resources/helper"),
                .copy("Resources/runner")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-parse-as-library"] + idbPrivateHeaderSearchFlags)
            ],
            linkerSettings: [
                // For XCFrameworks, rpath can often be just @executable_path
                // if SPM handles embedding correctly, or you might need to adjust
                // if you manually copy them later for distribution.
                .unsafeFlags([
                    "-Xlinker", "-dead_strip",
                    "-Xlinker", "-headerpad_max_install_names",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path" // Simpler rpath for SPM-handled XCFrameworks
                ])
            ],
            plugins: ["VersionPlugin"]
        ),
        .testTarget(
            name: "OffsiderTests",
            dependencies: ["Offsider", "OffsiderCore", "OffsiderAndroid", "OffsiderIOSDevice"],
            path: "Tests",
            exclude: ["Fixtures", "Goldens", "IOSDevice/Fixtures"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(idbPrivateHeaderSearchFlags)
            ]
        ),
        .plugin(
            name: "VersionPlugin",
            capability: .buildTool(),
            path: "Plugins/VersionPlugin"
        ),
        .binaryTarget(
            name: "FBControlCore",
            path: "build_products/XCFrameworks/FBControlCore.xcframework" // Updated path
        ),
        .binaryTarget(
            name: "FBDeviceControl",
            path: "build_products/XCFrameworks/FBDeviceControl.xcframework" // Updated path
        ),
        .binaryTarget(
            name: "FBSimulatorControl",
            path: "build_products/XCFrameworks/FBSimulatorControl.xcframework" // Updated path
        ),
        .binaryTarget(
            name: "XCTestBootstrap",
            path: "build_products/XCFrameworks/XCTestBootstrap.xcframework" // Updated path
        ),
    ]
)

// The fuzz driver builds only on request (OFFSIDER_FUZZ=1, debug builds for its @testable imports) and never ships.
if ProcessInfo.processInfo.environment["OFFSIDER_FUZZ"] == "1" {
    package.products.append(.executable(name: "OffsiderFuzz", targets: ["OffsiderFuzz"]))
    package.targets.append(
        .executableTarget(
            name: "OffsiderFuzz",
            dependencies: ["OffsiderCore", "OffsiderAndroid", "OffsiderIOSDevice"],
            path: "Sources/OffsiderFuzz",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    )
}
