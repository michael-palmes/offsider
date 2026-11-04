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
        /// On Android, captured with Gboard's full keys, which it shows beside a hardware keyboard only when asked before the app opens.
        var fullKeyboard = false

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

    /// Beside the emulator's hardware keyboard Gboard shows only its floating toolbar; this Android setting asks for its full keys.
    static let fullKeyboardSetting = "show_ime_with_hard_keyboard"

    /// Gboard's full keys stand about 336 pt tall, its toolbar 48 pt.
    static let fullKeyboardHeight = 200.0

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
        Screen(name: "text-input@keyboard", route: "text-input", prepare: tap("text-input-field", thenWaitFor: "typing-active-indicator"), fullKeyboard: true),
        Screen(name: "stack-test@full", route: "stack-test", prepare: tap("stack-test-open-full", thenWaitFor: "stack-test-full-title-1")),
        Screen(name: "stack-test@flags", route: "stack-test", prepare: { app in
            try await tap("stack-test-open-full", thenWaitFor: "stack-test-full-title-1")(app)
            try await tap("stack-test-full-next", thenWaitFor: "stack-test-full-title-2")(app)
        }),
    ]

    @Test("captures every screen's raw tree and re-renders its golden", arguments: RNPlatform.enabled)
    func capture(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        if platform == .ios {
            try await Self.requireOffsiderSimulator()
        }
        let devicePlatform: DevicePlatform = platform == .ios ? .ios : .android
        let keyboardSetting = platform == .android ? try await AndroidE2E.shell("settings get secure \(Self.fullKeyboardSetting)").trimmingCharacters(in: .whitespacesAndNewlines) : nil
        do {
            for screen in Self.screens {
                let full = screen.fullKeyboard && platform == .android
                // Set before the app opens: Gboard keeps its toolbar for a field that took focus earlier.
                if full { _ = try await AndroidE2E.shell("settings put secure \(Self.fullKeyboardSetting) 1") }
                let raw = try await Self.retrying {
                    try await app.open(screen.route, waitingFor: screen.marker)
                    try await screen.prepare?(app)
                    let raw = try await Self.settledCapture(app)
                    if full { try Self.requireFullKeyboard(raw, screen: screen.name) }
                    return raw
                }
                if full { try await Self.restoreKeyboard(keyboardSetting) }
                let scrubbed = try TreeGoldenScrubber.scrub(raw, platform: devicePlatform)
                guard let object = scrubbed as? [String: Any] else {
                    throw DescribeUIError(description: "describe-ui --raw-source did not print an object")
                }
                try TreeGoldens.write(object, to: TreeGoldens.Golden(platform: devicePlatform, screen: screen.name))
            }
        } catch {
            try? await Self.restoreKeyboard(keyboardSetting)
            throw error
        }
        try await Self.restoreKeyboard(keyboardSetting)
        try TreeGoldens.writeBudgets()
    }

    /// Refuses a capture whose keyboard is Gboard's toolbar alone, so the golden never loses its keys unnoticed.
    static func requireFullKeyboard(_ raw: Any, screen: String) throws {
        let tree = try TreeGoldens.tree(from: try RawTreeCapture(jsonData: try JSONSerialization.data(withJSONObject: raw)))
        let height = tree.roots.filter { $0.role == .keyboard }.compactMap(\.frame?.height).max() ?? 0
        guard height >= fullKeyboardHeight else {
            throw DescribeUIError(description: "\(screen) shows a keyboard \(height) pt tall, not Gboard's full keys; check \(fullKeyboardSetting) on the AVD.")
        }
    }

    /// Puts the AVD's keyboard setting back as the capture found it; nil on iOS.
    static func restoreKeyboard(_ value: String?) async throws {
        guard let value else { return }
        _ = try await AndroidE2E.shell(value == "1" || value == "0" ? "settings put secure \(fullKeyboardSetting) \(value)" : "settings delete secure \(fullKeyboardSetting)")
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
            // A golden recapture is a person's own check, so the raw tree is read as one.
            let output = try TestHelpers.jsonObject(in: try await app.runAsPerson("describe-ui --raw-source").stdout)
            let raw = try JSONSerialization.jsonObject(with: output)
            let tree = try TreeGoldens.tree(from: try RawTreeCapture(jsonData: output))
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
