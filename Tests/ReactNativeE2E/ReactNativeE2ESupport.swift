import Foundation
import Testing

let isRNIOSE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_RN_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

/// Debug builds that load JavaScript from Metro on 8742 replace the Release app on both platforms.
let isRNDebugE2EEnabled = {
    let raw = ProcessInfo.processInfo.environment["OFFSIDER_RN_DEBUG_E2E"]?.lowercased() ?? ""
    return raw == "1" || raw == "true" || raw == "yes"
}()

/// The Metro that `scripts/rn-playground.sh metro start` runs for the Debug builds.
enum RNMetro {
    static let port = 8742
    static let url = "http://127.0.0.1:\(port)"
    /// The dev client's own link to load a bundle URL, as `expo start --dev-client` prints it.
    static let devClientURL = "exp+offsiderplaygroundrn://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A\(port)"
}

/// Around a debug suite: points the Android emulator's 127.0.0.1:8742 at Metro on the Mac, and removes it afterwards.
struct RNDebugSession: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard isAndroidE2EEnabled else {
            try await function()
            return
        }
        try await AndroidE2E.reverseMetro()
        do {
            try await function()
        } catch {
            try? await AndroidE2E.removeMetroReverse()
            throw error
        }
        try await AndroidE2E.removeMetroReverse()
    }
}

/// Stylus handwriting off around a suite that types, as Gboard's stylus tutorial opens after an emulator's tap on a field and `type` then refuses; put back as found.
struct StylusHandwritingOff: SuiteTrait, TestScoping {
    static let setting = "stylus_handwriting_enabled"

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await Self.scoped("0", function)
    }

    /// Sets the guarded emulator's setting for `function`, then puts back what was there, deleting it when it was unset.
    static func scoped(_ value: String, _ function: @Sendable () async throws -> Void) async throws {
        guard isAndroidE2EEnabled else {
            try await function()
            return
        }
        let found = try await AndroidE2E.shell("settings get secure \(Self.setting)").trimmingCharacters(in: .whitespacesAndNewlines)
        let restore = found == "null" ? "settings delete secure \(Self.setting)" : "settings put secure \(Self.setting) \(AndroidE2E.quote(found))"
        do {
            try await AndroidE2E.shell("settings put secure \(Self.setting) \(value)")
            try await function()
        } catch {
            _ = try? await AndroidE2E.shell(restore)
            throw error
        }
        try await AndroidE2E.shell(restore)
    }
}

/// Stylus handwriting on around a suite that proves `type` with Gboard's tutorial able to open; put back as found.
struct StylusHandwritingOn: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await StylusHandwritingOff.scoped("1", function)
    }
}

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
    /// A Debug build's first bundle from Metro can take minutes, so it gets at least 180 s.
    func open(_ route: String, waitingFor id: String? = nil, timeout: TimeInterval = 40) async throws {
        let timeout = isRNDebugE2EEnabled ? max(timeout, 180) : timeout
        let size = try await screenSize()
        guard size.width <= size.height else {
            throw DescribeUIError(description: "The \(platform.rawValue) device is in landscape (\(Int(size.width)) x \(Int(size.height))); rotate it to portrait before running the React Native fixtures.")
        }
        switch platform {
        case .android:
            try await AndroidE2E.launch(route)
            try await AndroidE2E.dismissANRDialog()
        case .ios:
            try await IOSRNPlayground.launch(route)
        }
        let marker = id ?? "\(route)-screen"
        _ = try await waitForNode(timeout: timeout) { $0["id"] as? String == marker }
        if platform == .android {
            // A warm helper reads within milliseconds, so let the new screen finish laying out, ticking text aside.
            _ = try await offsider("wait --settled --ignore-values --timeout 10")
        }
    }

    /// Runs offsider on this platform's device; a non-zero exit is an error carrying stderr.
    @discardableResult
    func run(_ arguments: String, environment: [String: String]? = nil, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        let result = try await offsider(arguments, environment: environment, timeout: timeout)
        guard result.exitCode == 0 else {
            throw DescribeUIError(description: "offsider \(arguments) on \(platform.rawValue) exited \(result.exitCode): \(result.stderr)")
        }
        return result
    }

    /// `run` on a pseudo-terminal, for the person gates; stderr comes mixed into stdout.
    func runAsPerson(_ arguments: String, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        let device = platform == .android ? try await AndroidE2E.serial() : try IOSRNPlayground.udid()
        let result = try await TestHelpers.runOffsiderAsPerson("\(arguments) --device \(device)", timeout: timeout)
        guard result.exitCode == 0 else {
            throw DescribeUIError(description: "offsider \(arguments) on \(platform.rawValue) exited \(result.exitCode): \(result.stdout)")
        }
        return result
    }

    /// Runs offsider on this platform's device and returns whatever it exits with; on Android, first answers an ANR dialog.
    func offsider(_ arguments: String, environment: [String: String]? = nil, timeout: TimeInterval = 120) async throws -> SeparatedCommandOutput {
        switch platform {
        case .android:
            try await AndroidE2E.dismissANRDialog()
            return try await AndroidE2E.offsider(arguments, environment: environment, timeout: timeout)
        case .ios:
            return try await TestHelpers.runOffsiderCommandSeparated(arguments, simulatorUDID: try IOSRNPlayground.udid(), environment: environment, timeout: timeout)
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

    /// A row whose centre lies under `cover` with 8 pt of it showing, scrolling `list` a little when this screen's size leaves every centre clear.
    func rowCentred(under cover: String, rows: [String], list: String) async throws -> String {
        let scroller = try await frame(of: list)
        let x = Int(scroller.x + scroller.width / 2), y = Int(scroller.y + scroller.height / 3)
        var lastTops: [Double]?
        while true {
            let tree = try await tree()
            let bar = try #require(DescribeUITree.frame(of: cover, in: tree))
            let frames = rows.map { (id: $0, frame: DescribeUITree.frame(of: $0, in: tree)) }
            let found = frames.first { entry in
                guard let row = entry.frame else { return false }
                let centre = row.y + row.height / 2
                return centre >= bar.y && centre < bar.y + bar.height && (bar.y - row.y >= 8 || row.y + row.height - bar.y - bar.height >= 8)
            }
            if let found { return found.id }
            let tops = frames.compactMap { $0.frame?.y }
            guard tops != lastTops else {
                throw DescribeUIError(description: "\(list) stopped scrolling on this screen before a row's centre came under \(cover); this fixture needs a shorter screen")
            }
            lastTops = tops
            try await run("swipe --start-x \(x) --start-y \(y) --end-x \(x) --end-y \(y - 30) --duration 0.8")
            try await run("wait --settled --ignore-values --timeout 5")
        }
    }

    /// A node's frame in points or dp, waiting for the node to appear.
    func frame(of id: String) async throws -> (x: Double, y: Double, width: Double, height: Double) {
        let node = try await waitForNode { $0["id"] as? String == id }
        guard let frame = node["frame"] as? [String: Double],
              let x = frame["x"], let y = frame["y"], let width = frame["width"], let height = frame["height"] else {
            throw DescribeUIError(description: "\(id) has no frame")
        }
        return (x, y, width, height)
    }
}
