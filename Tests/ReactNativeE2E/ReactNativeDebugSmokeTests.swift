import Foundation
import Testing

/// Debug builds of the playground with JavaScript from Metro on 8742 (`./test-runner.sh --rn-debug`).
@Suite("React Native debug smoke", .serialized, .enabled(if: isRNDebugE2EEnabled && RNPlatform.anyEnabled), RNDebugSession())
struct ReactNativeDebugSmokeTests {
    private static func label(_ node: [String: Any]) -> String {
        node["label"] as? String ?? ""
    }

    private static func hasNode(_ app: RNApp, _ predicate: ([String: Any]) -> Bool) async throws -> Bool {
        DescribeUITree.nodes(in: try await app.tree()).contains(where: predicate)
    }

    /// Opens the overlay fixture with LogBox emptied, then logs one console.error.
    private static func openWithErrorBanner(_ app: RNApp) async throws -> [String: Any] {
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-clear-logs")
        try await app.run("tap --id overlay-test-log-error")
        return try await app.waitForNode { label($0).contains("OffsiderFixture error") }
    }

    @Test("the debug app has no embedded bundle and shows the fixture screen from Metro", arguments: RNPlatform.enabled)
    func loadsFromMetro(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")

        switch platform {
        case .ios:
            let installed = try #require(try await IOSRNPlayground.installedAppPath())
            #expect(!FileManager.default.fileExists(atPath: installed + "/main.jsbundle"))
        case .android:
            let listing = try await CommandRunner.runSeparated("/usr/bin/unzip -l \(AndroidE2E.quote(try AndroidE2E.apkPath()))")
            #expect(listing.exitCode == 0)
            #expect(!listing.stdout.contains("assets/index.android.bundle"))
        }
        #expect(try await app.label(of: "overlay-test-tab") == "Overlay Tab: Home")
    }

    @Test("on a fresh install, rn prepare skips the dev menu intro so the first tap reaches the app", arguments: RNPlatform.enabled)
    func freshInstallSkipsIntro(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        switch platform {
        case .ios:
            try await IOSRNPlayground.installFresh()
        case .android:
            try await AndroidE2E.installFresh()
        }
        try await app.run("rn prepare --bundle-id \(IOSRNPlayground.bundleID)")
        try await app.open("overlay-test")
        // The intro and the launch menu open on first render, so give them the time they took when not suppressed.
        try await Task.sleep(for: .seconds(4))

        #expect(try await !Self.hasNode(app) { Self.label($0) == "Continue" })
        #expect(try await !Self.hasNode(app) { $0["id"] as? String == "xmark" || (Self.label($0) == "Close" && $0["role"] as? String == "button") })
        try await app.run("tap --id overlay-test-tab-search --fail-if-covered")
        _ = try await app.waitForLabel(of: "overlay-test-tab") { $0 == "Overlay Tab: Search" }
    }

    @Test("a LogBox error banner over the tab bar swallows a tab tap, with a cover warning on both platforms", arguments: RNPlatform.enabled)
    func logBoxBannerCoversTabs(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        let banner = try await Self.openWithErrorBanner(app)
        #expect(Self.label(banner) == "!, OffsiderFixture error 1", "\(banner)")
        #expect(banner["role"] as? String == (platform == .ios ? "other" : "button"))

        let firstTap = try await app.offsider("tap --id overlay-test-tab-search --fail-if-covered")
        #expect(firstTap.exitCode != 0)
        #expect(firstTap.stderr.contains("may be covered by"), "\(firstTap.stderr)")
        #expect(firstTap.stderr.contains("OffsiderFixture error 1"), "\(firstTap.stderr)")
        let warned = try await app.offsider("tap --id overlay-test-tab-search")
        #expect(warned.exitCode == 0, "\(warned.stderr)")
        #expect(warned.stderr.contains("may be covered by"), "\(warned.stderr)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "overlay-test-tab") == "Overlay Tab: Home")
    }

    @Test("console.warn raises no LogBox banner in a debug build", arguments: RNPlatform.enabled)
    func warningsStayInTheConsole(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-clear-logs")
        try await app.run("tap --id overlay-test-log-warning")
        try await Task.sleep(for: .seconds(2))

        // React Native routes warnings to the debugger (Fusebox) instead of LogBox, on both platforms.
        #expect(try await !Self.hasNode(app) { Self.label($0).contains("OffsiderFixture warning") })
        #expect(try await app.label(of: "overlay-test-screen") != nil)
    }

    @Test("tapping the banner opens the LogBox inspector, which is in the tree and closes with Dismiss", arguments: RNPlatform.enabled)
    func logBoxInspector(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        let banner = try await Self.openWithErrorBanner(app)
        let frame = try #require(banner["frame"] as? [String: Double])
        let x = Int((frame["x"] ?? 0) + (frame["width"] ?? 0) * 0.4)
        let y = Int((frame["y"] ?? 0) + (frame["height"] ?? 0) / 2)

        try await app.run("tap -x \(x) -y \(y)")

        switch platform {
        case .ios:
            _ = try await app.waitForNode { Self.label($0) == "Console Error" }
            _ = try await app.waitForNode { Self.label($0) == "Dismiss" && $0["role"] as? String == "other" }
            #expect(try await Self.hasNode(app) { Self.label($0) == "Minimize" })
            #expect(try await Self.hasNode(app) { $0["id"] as? String == "overlay-test-screen" })
        case .android:
            // The inspector is its own window, so describe-ui shows it without the app beneath.
            _ = try await app.waitForNode { Self.label($0) == "Console Error" }
            _ = try await app.waitForNode { Self.label($0) == "Dismiss" && $0["role"] as? String == "button" }
            #expect(try await Self.hasNode(app) { Self.label($0) == "Minimize" })
            #expect(try await !Self.hasNode(app) { $0["id"] as? String == "overlay-test-screen" })
        }
        try await app.run("tap --label Dismiss")
        let gone = try await app.offsider("wait --label 'Console Error' --gone --timeout 10")
        #expect(gone.exitCode == 0, "\(gone.stderr)")
        #expect(try await !Self.hasNode(app) { Self.label($0).contains("OffsiderFixture error") })
    }

    @Test("rn logbox reads two errors, the summary names them, dismiss clears both and the tab tap then lands", arguments: RNPlatform.enabled)
    func logBoxStatusAndDismiss(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-clear-logs")
        try await app.run("tap --id overlay-test-log-two-errors")
        _ = try await app.waitForNode { Self.label($0).hasPrefix("2, ") }

        let status = try await app.run("rn logbox status --json").stdout
        #expect(status.contains(#""logs":2"#), "\(status)")
        let summary = try await app.run("describe-ui --summary").stdout
        #expect(summary.contains("\n# logbox: 2 logs\n"), "\(summary.prefix(400))")

        let dismissed = try await app.run("rn logbox dismiss --json").stdout
        #expect(dismissed.contains(#""cleared":2,"remaining":0"#), "\(dismissed)")
        let after = try await app.run("rn logbox status --json").stdout
        #expect(after.contains(#""logs":0"#) && !after.contains("10, pcs"), "\(after)")
        try await app.run("tap --id overlay-test-tab-search --fail-if-covered")
        _ = try await app.waitForLabel(of: "overlay-test-tab") { $0 == "Overlay Tab: Search" }
    }

    @Test("a full-width 10, pcs button near the bottom is never read as LogBox", arguments: RNPlatform.enabled)
    func amountIsNotLogBox(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-clear-logs")

        let status = try await app.run("rn logbox status --json").stdout
        #expect(status.contains(#""logs":0,"toasts":[]"#), "\(status)")
        #expect(!(try await app.run("describe-ui --summary").stdout.contains("# logbox")))
    }

    /// Stops the debug app and starts it with no link, so the dev client shows its launcher or reopens the last Metro.
    private static func plainLaunch(_ platform: RNPlatform) async throws {
        switch platform {
        case .ios:
            let udid = try IOSRNPlayground.udid()
            _ = try await CommandRunner.runSeparated("xcrun simctl launch --terminate-running-process \(udid) \(IOSRNPlayground.bundleID)", timeout: 60)
        case .android:
            try await AndroidE2E.shell("am force-stop \(AndroidE2E.package)")
            try await AndroidE2E.shell("monkey -p \(AndroidE2E.package) -c android.intent.category.LAUNCHER 1")
        }
    }

    @Test("rn open loads the bundle from Metro after a plain launch, whether or not the launcher showed, and a port with no Metro is exit 9", arguments: RNPlatform.enabled)
    func rnOpen(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.plainLaunch(platform)
        try await Task.sleep(for: .seconds(3))

        let opened = try await app.run("rn open --port \(RNMetro.port) --bundle-id \(IOSRNPlayground.bundleID) --wait-id menu-title --json", timeout: 240)
        #expect(opened.stdout.contains(#""metro":"running""#), "\(opened.stdout)")
        // A dev client may reopen the last Metro it loaded instead of showing its launcher, so only a send is required.
        let report = try #require(try JSONSerialization.jsonObject(with: Data(opened.stdout.utf8)) as? [String: Any])
        #expect((report["sends"] as? Int ?? 0) >= 1, "\(opened.stdout)")
        _ = try await app.waitForNode { $0["id"] as? String == "menu-title" }

        let noMetro = try await app.offsider("rn open --port \(RNMetro.port + 1) --bundle-id \(IOSRNPlayground.bundleID) --timeout 10")
        #expect(noMetro.exitCode == 9, "\(noMetro.stderr)")
    }

    @Test("rn devmenu reload reloads the app, and inspector then rn tools off leaves no panel", arguments: RNPlatform.enabled)
    func devMenu(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")

        let listed = try await app.run("rn devmenu --json")
        #expect(listed.stdout.contains(#""label":"Reload""#), "\(listed.stdout)")
        try await app.run("rn devmenu close")
        try await app.run("rn devmenu reload", timeout: 240)
        _ = try await app.waitForNode(timeout: 180) { $0["id"] as? String != nil }

        try await app.run("rn devmenu inspector")
        let off = try await app.run("rn tools off --json")
        #expect(off.stdout.contains(#""inspector":"turned-off""#), "\(off.stdout)")
        #expect(try await !Self.hasNode(app) { Self.label($0) == "Touchables" })
    }

    @Test("shake opens the dev menu, which closes with its Close button", arguments: RNPlatform.enabled.filter { $0 == .ios })
    func shakeOpensDevMenu(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")

        try await app.run("shake")
        _ = try await app.waitForNode(timeout: 10) { $0["id"] as? String == "xmark" && Self.label($0) == "Close" }
        #expect(try await Self.hasNode(app) { Self.label($0) == "Reload" && $0["role"] as? String == "button" })

        try await app.run("tap --id xmark")
        let gone = try await app.offsider("wait --id xmark --gone --timeout 10")
        #expect(gone.exitCode == 0, "\(gone.stderr)")
        try await app.run("tap --id overlay-test-tab-profile --fail-if-covered")
        _ = try await app.waitForLabel(of: "overlay-test-tab") { $0 == "Overlay Tab: Profile" }
    }
}
