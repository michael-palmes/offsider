import Foundation
import OffsiderCore
import Testing

/// Recaptures the tree goldens from the React Native playground with OFFSIDER_GOLDENS_UPDATE=1 and the device variables.
@Suite("Tree golden capture", .serialized, .enabled(if: TreeGoldens.isUpdating && RNPlatform.anyEnabled))
struct TreeGoldenCaptureTests {
    struct Screen: Sendable, CustomTestStringConvertible {
        let name: String
        let route: String
        var marker: String? = nil
        var prepare: (@Sendable (RNApp) async throws -> Void)? = nil

        var testDescription: String { name }
    }

    static func tap(_ id: String, thenWaitFor marker: String? = nil) -> @Sendable (RNApp) async throws -> Void {
        { app in
            try await app.run("tap --id \(id)")
            if let marker {
                _ = try await app.waitForNode { $0["id"] as? String == marker }
            }
        }
    }

    static let screens: [Screen] = [
        Screen(name: "menu", route: "menu", marker: "menu-title"),
        Screen(name: "tap-test", route: "tap-test"),
        Screen(name: "rows-test", route: "rows-test", prepare: tap("rows-test-toggle-live")),
        Screen(name: "long-scroll-test", route: "long-scroll-test"),
        Screen(name: "toolbar-picker-test", route: "toolbar-picker-test"),
        Screen(name: "toolbar-picker-test@unread", route: "toolbar-picker-test", prepare: tap("toolbar-picker-test-filter-unread")),
        Screen(name: "choice-test", route: "choice-test"),
        Screen(name: "switch-test", route: "switch-test"),
        Screen(name: "tab-view-test", route: "tab-view-test"),
        Screen(name: "batch-login-flow", route: "batch-login-flow", marker: "batch-login-screen"),
        Screen(name: "sheet-test", route: "sheet-test"),
        Screen(name: "sheet-test@open", route: "sheet-test", prepare: tap("sheet-test-open-sheet", thenWaitFor: "sheet-test-sheet")),
        Screen(name: "parked-sheet-test", route: "parked-sheet-test"),
        Screen(name: "parked-sheet-test@open", route: "parked-sheet-test", prepare: tap("parked-sheet-test-open")),
        Screen(name: "overlay-test", route: "overlay-test"),
        Screen(name: "slider-value-test", route: "slider-value-test"),
        Screen(name: "text-input@keyboard", route: "text-input", prepare: tap("text-input-field", thenWaitFor: "typing-active-indicator")),
    ]

    @Test("captures every screen's raw tree and re-renders its golden", arguments: RNPlatform.enabled)
    func capture(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        if platform == .ios {
            try await Self.requireOffsiderSimulator()
        }
        let devicePlatform: DevicePlatform = platform == .ios ? .ios : .android
        for screen in Self.screens {
            let raw = try await Self.retrying {
                try await app.open(screen.route, waitingFor: screen.marker)
                try await screen.prepare?(app)
                return try await Self.settledCapture(app)
            }
            let scrubbed = try TreeGoldenScrubber.scrub(raw, platform: devicePlatform)
            guard let object = scrubbed as? [String: Any] else {
                throw DescribeUIError(description: "describe-ui --raw-source did not print an object")
            }
            try TreeGoldens.write(object, to: TreeGoldens.Golden(platform: devicePlatform, screen: screen.name))
        }
        try TreeGoldens.writeBudgets()
    }

    /// A busy host can time out one read; each screen gets three tries from a fresh launch.
    static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        for _ in 0..<2 {
            if let value = try? await body() { return value }
        }
        return try await body()
    }

    /// Two reads 500 ms apart with the same roles, labels and values, up to six tries.
    static func settledCapture(_ app: RNApp) async throws -> Any {
        var previous: (raw: Any, summary: [String])?
        for _ in 0..<6 {
            let output = try await app.run("describe-ui --raw-source").stdout
            let raw = try JSONSerialization.jsonObject(with: Data(output.utf8))
            let tree = try TreeGoldens.tree(from: try RawTreeCapture(jsonData: Data(output.utf8)))
            let summary = tree.roots.flatMap { $0.flattened() }.map { "\($0.role) \($0.label ?? "") \($0.value ?? "")" }
            if let previous, previous.summary == summary {
                return raw
            }
            previous = (raw, summary)
            try await Task.sleep(for: .milliseconds(500))
        }
        return try #require(previous).raw
    }

    static func requireOffsiderSimulator() async throws {
        let udid = try IOSRNPlayground.udid()
        let listing = try await CommandRunner.runSeparated("xcrun simctl list devices", timeout: 60)
        let line = listing.stdout.split(separator: "\n").first { $0.contains(udid) } ?? ""
        guard line.contains("Offsider") else {
            throw DescribeUIError(description: "Refusing \(udid): tree goldens are captured only on an Offsider-tagged simulator.")
        }
    }
}
