import Foundation
import Testing

let isRNIOSE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_RN_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

enum RNPlatform: String, Sendable, CustomTestStringConvertible {
    case ios
    case android

    /// iOS with OFFSIDER_RN_E2E, Android with OFFSIDER_ANDROID_E2E.
    static var enabled: [RNPlatform] {
        (isRNIOSE2EEnabled ? [.ios] : []) + (isAndroidE2EEnabled ? [.android] : [])
    }

    static var anyEnabled: Bool { !enabled.isEmpty }

    var testDescription: String { rawValue }
}

/// The React Native playground on one platform: Android through the guarded `AndroidE2E` emulator, iOS on SIMULATOR_UDID.
struct RNApp: Sendable {
    let platform: RNPlatform

    init(_ platform: RNPlatform) {
        self.platform = platform
    }

    private var describeUI: DescribeUITree {
        switch platform {
        case .android:
            return AndroidE2E.describeUI
        case .ios:
            return DescribeUITree(read: { try DescribeUITree.parse(try await run("describe-ui").stdout) })
        }
    }

    /// Launches `route` and waits for `id`, by default the `<route>-screen` marker; refuses a landscape device first.
    func open(_ route: String, waitingFor id: String? = nil, timeout: TimeInterval = 40) async throws {
        let size = try await screenSize()
        guard size.width <= size.height else {
            throw DescribeUIError(description: "The \(platform.rawValue) device is in landscape (\(Int(size.width)) x \(Int(size.height))); rotate it to portrait before running the React Native fixtures.")
        }
        switch platform {
        case .android:
            try await AndroidE2E.launch(route)
        case .ios:
            try await IOSRNPlayground.launch(route)
        }
        let marker = id ?? "\(route)-screen"
        _ = try await waitForNode(timeout: timeout) { $0["id"] as? String == marker }
    }

    /// Runs offsider on this platform's device; a non-zero exit is an error carrying stderr.
    @discardableResult
    func run(_ arguments: String, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        let result = try await offsider(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw DescribeUIError(description: "offsider \(arguments) on \(platform.rawValue) exited \(result.exitCode): \(result.stderr)")
        }
        return result
    }

    /// Runs offsider on this platform's device and returns whatever it exits with.
    func offsider(_ arguments: String, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        switch platform {
        case .android:
            return try await AndroidE2E.offsider(arguments, timeout: timeout)
        case .ios:
            return try await TestHelpers.runOffsiderCommandSeparated(arguments, simulatorUDID: try IOSRNPlayground.udid(), timeout: timeout)
        }
    }

    func tree() async throws -> [String: Any] {
        try await describeUI.tree()
    }

    func label(of id: String) async throws -> String? {
        try await describeUI.label(of: id)
    }

    func waitForNode(timeout: TimeInterval = 20, where predicate: @escaping ([String: Any]) -> Bool) async throws -> [String: Any] {
        try await describeUI.waitForNode(timeout: timeout, where: predicate)
    }

    func waitForLabel(of id: String, timeout: TimeInterval = 20, _ predicate: @escaping (String) -> Bool) async throws -> String {
        try await describeUI.waitForLabel(of: id, timeout: timeout, predicate)
    }

    /// The centre of a node's frame, in points or dp, for coordinate commands.
    func centre(of id: String) async throws -> (x: Int, y: Int) {
        try await describeUI.centre(of: id)
    }

    func screenSize() async throws -> (width: Double, height: Double) {
        try await describeUI.screenSize()
    }
}
