import Foundation
import Testing

/// What works today on app structures that have tripped Offsider: pages slid over mounted ones, views hidden until a screen reader runs, web views.
@Suite("React Native gotcha fixtures", .serialized, .enabled(if: RNPlatform.anyEnabled), StylusHandwritingOff())
struct ReactNativeGotchaTests {
    private static func json(_ stdout: String) throws -> [String: Any] {
        let line = try #require(stdout.split(separator: "\n").last { $0.hasPrefix("{") }, "\(stdout)")
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "\(stdout)")
    }

    /// Opens stack-test with both sliding pages pushed, by a timed slide from the right or a spring from below.
    private static func pushBothPages(_ app: RNApp, kind: String) async throws {
        try await app.open("stack-test")
        try await app.run("tap --id stack-test-slide-\(kind)")
        _ = try await app.waitForNode { $0["id"] as? String == "stack-test-slide-title-1" }
        try await app.run("tap --id stack-test-slide-confirm")
        _ = try await app.waitForNode { $0["id"] as? String == "stack-test-slide-title-2" }
        try await app.run("wait --settled --ignore-values --timeout 5")
    }

    @Test("on a page slid over a mounted one, a label both pages hold taps the page on top, and Back pops only that page", arguments: RNPlatform.enabled, ["left", "up"])
    func slidPagesTapTheTop(platform: RNPlatform, kind: String) async throws {
        let app = RNApp(platform)
        try await Self.pushBothPages(app, kind: kind)

        let waited = try await app.offsider("wait --id stack-test-slide-up --timeout 1")
        #expect(waited.exitCode == 5, "\(waited.stdout)\(waited.stderr)")
        let asserted = try await app.offsider("assert --id stack-test-slide-up")
        #expect(asserted.exitCode == 5, "\(asserted.stdout)\(asserted.stderr)")
        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("id=stack-test-slide-up"), "\(summary)")
        #expect(summary.components(separatedBy: "# beneath:").count - 1 == 2, "\(summary)")

        try await app.run("tap --label 'Confirm Change' --fail-if-covered")
        _ = try await app.waitForLabel(of: "stack-test-slide-result") { $0 == "Slide Result: Confirmed" }

        try await app.run("tap --label Back --fail-if-covered")
        try await app.run("wait --id stack-test-slide-title-2 --gone --timeout 5")
        try await app.run("assert --id stack-test-slide-title-1")
    }

    @Test("--mask-skip-beneath leaves the email row on the page beneath unpainted", arguments: RNPlatform.enabled)
    func emailBeneathSlidPage(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.pushBothPages(app, kind: "left")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-gotcha-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = try Self.json(try await app.run("screenshot --mask-emails --mask-skip-beneath --json --output \(path)").stdout)

        #expect(report["skippedBeneath"] as? [String: Int] == ["emails": 1], "\(report)")
        #expect(report["masked"] as? Int == 0, "\(report)")
    }

    /// Opens drawer-test with the drawer drawn above the page, and slides it in.
    private static func openDrawerAbove(_ app: RNApp) async throws {
        try await app.open("drawer-test")
        try await app.run("tap --id drawer-test-layer")
        _ = try await app.waitForLabel(of: "drawer-test-layer") { $0 == "Drawer Layer: Above" }
        let parked = try await app.offsider("wait --id drawer-test-row-inbox --timeout 1")
        #expect(parked.exitCode == 5, "\(parked.stdout)\(parked.stderr)")
        try await app.run("tap --id drawer-test-toggle")
        try await app.run("wait --id drawer-test-row-inbox --timeout 5")
    }

    @Test("a confirm panel that slides in hidden from accessibility is listed, and its button is tapped over the twin that slid out", arguments: RNPlatform.enabled)
    func hiddenConfirmPanel(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openDrawerAbove(app)
        try await app.run("tap --id drawer-test-row-reset")

        try await app.run("wait --label 'Reset the drawer?' --timeout 5")
        try await app.run("tap --label 'Reset Drawer'")

        try await app.run("wait --id drawer-test-row-inbox --timeout 5")
        try await app.run("tap --id drawer-test-drawer-back")
        _ = try await app.waitForLabel(of: "drawer-test-pressed") { $0 == "Drawer Pressed: Confirm Reset" }
    }

    @Test("a page pushed from a drawer row takes taps, a label it shares with the drawer's row included, while the drawer stays open beneath it", arguments: RNPlatform.enabled)
    func pagePushedFromDrawerRow(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openDrawerAbove(app)
        try await app.run("tap --id drawer-test-row-reminders")
        _ = try await app.waitForNode { $0["id"] as? String == "drawer-test-row-page-title" }

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("id=drawer-test-row-archive"), "\(summary)")
        try await app.run("tap --label 'Drawer Reminders' --fail-if-covered")
        try await app.run("tap --label Back --fail-if-covered")

        try await app.run("wait --id drawer-test-row-page-title --gone --timeout 5")
        try await app.run("wait --id drawer-test-row-inbox --timeout 5")
        try await app.run("tap --id drawer-test-drawer-back")
        _ = try await app.waitForLabel(of: "drawer-test-pressed") { $0 == "Drawer Pressed: Row Page Reminders" }
    }

    @Test("a tab whose hidden flags wait for a screen reader still lists its rows after a native-driver slide", arguments: RNPlatform.enabled)
    func readerGatedTabs(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("gap-tabs-test")
        try await app.run("tap --id gap-tabs-flags")
        _ = try await app.waitForLabel(of: "gap-tabs-flags") { $0.hasPrefix("Flags: Reader") }
        try await app.run("tap --id gap-tabs-tab-saved")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Saved Tab" }
        try await app.run("wait --settled --ignore-values --timeout 5")

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(summary.contains("# filled: "), "\(summary)")
        #expect(summary.contains("id=gap-tabs-saved-row-2"), "\(summary)")

        try await app.run("tap --label 'Saved Item 4' --verify")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Saved Item 4" }
    }

    /// Taps a third of the story at mid height: the left third goes back, the rest goes on.
    private static func tapStory(_ app: RNApp, left: Bool) async throws {
        let story = try await app.frame(of: "story-intro")
        let x = Int(story.x + story.width * (left ? 0.15 : 0.85)), y = Int(story.y + story.height * 0.25)
        try await app.run("tap -x \(x) -y \(y)")
    }

    @Test("the story's container id taps on to the next page, a tap in the left third goes back, and the last page's nested button is found", arguments: RNPlatform.enabled)
    func storyTapsAndNestedButton(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("story-intro-test", waitingFor: "story-intro-state")
        #expect(try await app.label(of: "story-intro-state") == "Story: Page 1")

        try await app.run("tap --id story-intro")
        _ = try await app.waitForLabel(of: "story-intro-state") { $0 == "Story: Page 2" }
        try await Self.tapStory(app, left: true)
        _ = try await app.waitForLabel(of: "story-intro-state") { $0 == "Story: Page 1" }

        try await Self.tapStory(app, left: false)
        _ = try await app.waitForLabel(of: "story-intro-state") { $0 == "Story: Page 2" }
        try await Self.tapStory(app, left: false)
        try await app.run("wait --id story-intro-start --timeout 5")
        try await app.run("tap --id story-intro-start --fail-if-covered")
        _ = try await app.waitForLabel(of: "story-intro-state") { $0 == "Story: Finished" }
    }

    @Test("the story moves to its second page by itself", arguments: RNPlatform.enabled)
    func storyAdvancesOnItsTimer(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("story-intro-test", waitingFor: "story-intro-state")

        _ = try await app.waitForLabel(of: "story-intro-state", timeout: 20) { $0 == "Story: Page 2" }
    }

    /// Restarts the playground on a screen with the story intro asked for: a launch argument on iOS, a link parameter on Android.
    private static func launchWithIntro(_ app: RNApp, route: String) async throws {
        switch app.platform {
        case .ios:
            try await IOSRNPlayground.ensureInstalled()
            let launch = "xcrun simctl launch --terminate-running-process \(try IOSRNPlayground.udid()) \(IOSRNPlayground.bundleID) -OffsiderScreen \(route) -OffsiderIntro 1"
            let result = try await CommandRunner.runSeparated(launch, timeout: 60)
            guard result.exitCode == 0 else {
                throw DescribeUIError(description: "simctl launch with the intro exited \(result.exitCode): \(result.stderr)")
            }
        case .android:
            try await AndroidE2E.ensurePlaygroundInstalled()
            let link = AndroidE2E.quote("offsiderplaygroundrn://screen/\(route)?intro=1")
            try await AndroidE2E.shell("am force-stop \(AndroidE2E.package); am start -W -a android.intent.action.VIEW -d \(link) \(AndroidE2E.package)")
        }
    }

    @Test("asked for at launch, the story shows before the screen and gives way to it once finished", arguments: RNPlatform.enabled.filter { _ in !isRNDebugE2EEnabled })
    func storyShowsFirst(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.launchWithIntro(app, route: "tap-test")
        _ = try await app.waitForNode(timeout: 40) { $0["id"] as? String == "story-intro" }
        #expect(DescribeUITree.node(id: "tap-test-screen", in: try await app.tree()) == nil)

        try await Self.tapStory(app, left: false)
        try await Self.tapStory(app, left: false)
        try await app.run("wait --id story-intro-start --timeout 5")
        try await app.run("tap --id story-intro-start")

        _ = try await app.waitForNode { $0["id"] as? String == "tap-test-screen" }
    }

    @Test("a swipe pans the web chart's readout, a pinch zooms it, and with its ticks stopped the screen settles", arguments: RNPlatform.enabled)
    func webChartPanPinchSettle(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("web-chart-test")
        let chart = try await app.frame(of: "web-chart")
        let y = Int(chart.y + chart.height / 2), startX = Int(chart.x + 60), endX = Int(chart.x + chart.width - 60)

        try await app.run("swipe --start-x \(startX) --start-y \(y) --end-x \(endX) --end-y \(y) --duration 0.6")
        let readout = try await app.waitForLabel(of: "web-chart-readout") { $0 != "Chart Readout: None" }
        let panned = try #require(readout.components(separatedBy: " at ").last.flatMap { Double($0) }, "\(readout)")
        #expect(abs(panned - (Double(endX) - chart.x)) <= 4, "the readout stopped at \(panned), the swipe at \(Double(endX) - chart.x)")

        try await app.run("gesture pinch --from 60 --to 240 --x \(Int(chart.x + chart.width / 2)) --y \(y)")
        let zoom = try await app.waitForLabel(of: "web-chart-zoom") { $0 != "Chart Zoom: 1.0x" }
        #expect((Double(zoom.dropFirst("Chart Zoom: ".count).dropLast()) ?? 0) > 2, "\(zoom)")

        try await app.run("tap --id web-chart-toggle")
        _ = try await app.waitForLabel(of: "web-chart-ticks") { $0 == "Chart Ticks: Stopped" }
        try await app.run("wait --settled --timeout 10")
    }

    private static func turnstileState(_ app: RNApp) async throws -> [String: Any] {
        try Self.json(try await app.run("turnstile --json").stdout)
    }

    private static func waitForTurnstile(_ app: RNApp, _ state: String, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        repeat {
            last = try await turnstileState(app)["state"] as? String ?? ""
            if last == state { return }
            try await Task.sleep(for: .milliseconds(400))
        } while Date() < deadline
        throw DescribeUIError(description: "turnstile read \(last), not \(state), for \(Int(timeout)) s")
    }

    /// Ticks the fixture's own checkbox where `turnstile` says it is; Offsider itself never taps one.
    private static func tickCheckbox(_ app: RNApp) async throws {
        try await waitForTurnstile(app, "checkbox")
        let frame = try #require(try await turnstileState(app)["frame"] as? [String: Double])
        let x = try #require(frame["x"]) + (try #require(frame["width"])) / 2, y = try #require(frame["y"]) + (try #require(frame["height"])) / 2
        try await app.run("tap -x \(Int(x.rounded())) -y \(Int(y.rounded()))")
    }

    @Test("turnstile reads a web view's human check as a checkbox, passed, failed, and a checkbox again once the pass expires", arguments: RNPlatform.enabled)
    func checkWidgetStates(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("check-widget-test")

        try await Self.tickCheckbox(app)
        try await Self.waitForTurnstile(app, "passed")
        _ = try await app.waitForLabel(of: "check-widget-state") { $0 == "Check: Passed" }

        try await app.run("tap --id check-widget-mode")
        _ = try await app.waitForLabel(of: "check-widget-mode") { $0 == "Check Mode: Expire" }
        try await Self.tickCheckbox(app)
        try await Self.waitForTurnstile(app, "passed")
        try await Self.waitForTurnstile(app, "checkbox")
        _ = try await app.waitForLabel(of: "check-widget-state") { $0 == "Check: Expired" }

        try await app.run("tap --id check-widget-mode")
        _ = try await app.waitForLabel(of: "check-widget-mode") { $0 == "Check Mode: Error" }
        try await Self.tickCheckbox(app)
        try await Self.waitForTurnstile(app, "failed")
        _ = try await app.waitForLabel(of: "check-widget-state") { $0 == "Check: Failed" }
    }

    @Test("logs --rn keeps an object logged as an extra argument in one entry, and on Android reads a console.debug line", arguments: RNPlatform.enabled)
    func debugAndObjectLogs(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")
        let count = Int(ReactNativeEnvironmentTests.number(in: try await app.label(of: "environment-test-log-count")) ?? -1)
        try #require(count >= 0)
        try await app.run("tap --id environment-test-debug")
        try await app.run("tap --id environment-test-object")
        _ = try await app.waitForLabel(of: "environment-test-log-count") { $0 == "Log Count: \(count + 2)" }

        var messages: [(level: String, message: String)] = []
        let deadline = Date().addingTimeInterval(15)
        repeat {
            let logs = try Self.json(try await app.run("logs --rn --last 1m --json").stdout)
            messages = ((logs["entries"] as? [[String: Any]]) ?? []).map { ($0["level"] as? String ?? "", $0["message"] as? String ?? "") }
            if messages.contains(where: { $0.message.contains("OffsiderFixture object \(count + 2)") }) { break }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline

        let object = try #require(messages.first { $0.message.contains("OffsiderFixture object \(count + 2)") }, "no entry for the object log")
        #expect(object.message.contains("second fixture item") && object.message.contains("selected: false"), "\(object.message)")
        if platform == .android {
            let debug = try #require(messages.first { $0.message == "OffsiderFixture debug \(count + 1)" }, "no entry for the debug log")
            #expect(debug.level == "Debug")
        }
    }

    @Test("the storage screen writes its two keys and clears them", arguments: RNPlatform.enabled)
    func storageKeys(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("storage-test")
        try await app.run("tap --id storage-test-clear")
        _ = try await app.waitForLabel(of: "storage-test-count") { $0 == "Stored Keys: 0" }

        try await app.run("tap --id storage-test-write")
        _ = try await app.waitForLabel(of: "storage-test-count") { $0 == "Stored Keys: 2" }

        try await app.run("tap --id storage-test-clear")
        _ = try await app.waitForLabel(of: "storage-test-count") { $0 == "Stored Keys: 0" }
    }

    @Test("a sheet beside the root that hides the whole screen leaves only the sheet listed, and the email drawn behind it is painted, on iOS with the capture reported unproven", arguments: RNPlatform.enabled)
    func rootSheetHidesScreen(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-sheet-test")
        try await app.run("tap --id mask-sheet-test-email")
        try await app.run("type --replace \(ReactNativeEvidenceTests.email)")
        let field = try await app.frame(of: "mask-sheet-test-email")
        try await app.run("tap --id mask-sheet-test-open-root")
        try await app.run("wait --id mask-sheet-test-root-close --timeout 5")
        try await app.run("wait --settled --ignore-values --timeout 5")

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("mask-sheet-test-address") && !summary.contains("id=mask-sheet-test-screen"), "\(summary)")
        try await ReactNativeEnvironmentTests.withTemporaryDirectory { directory in
            let path = directory.appendingPathComponent("emails.png").path
            let emails = try await app.run("screenshot --mask-emails --scale points --json --output \(AndroidE2E.quote(path))")
            let report = try Self.json(emails.stdout)
            #expect((report["maskedBy"] as? [String: Int])?["emails"] == 1, "\(report)")
            #expect(try ReactNativeEvidenceTests.pixel(atPoint: (field.x + 40, field.y + field.height / 2), in: path) == [0, 0, 0], "the email behind the sheet was left unmasked")

            let text = try Self.json(try await app.run(#"screenshot --mask-text '\.\.\.' --json --output "# + AndroidE2E.quote(path)).stdout)
            if platform == .android {
                #expect(report["maskUnproven"] == nil, "\(report)")
                #expect((text["maskedBy"] as? [String: Int])?["text"] == 2, "\(text)")
            } else {
                #expect(report["maskUnproven"] as? String == "modal", "\(report)")
                #expect(emails.stderr.contains("(maskUnproven)"), "\(emails.stderr)")
                #expect(text["maskUnproven"] as? String == "modal", "\(text)")
            }
        }

        try await app.run("tap --id mask-sheet-test-root-close")
        try await app.run("wait --id mask-sheet-test-open-root --timeout 5")
    }

    @Test("in the slow search field, type --verify exits 0 only when the field holds the word, and 5 when a key was lost", arguments: RNPlatform.enabled, [false, true])
    func slowSearchFieldVerify(platform: RNPlatform, twoSources: Bool) async throws {
        let app = RNApp(platform)
        try await app.open("controlled-search-test")
        if twoSources {
            try await app.run("tap --id controlled-search-source")
            _ = try await app.waitForLabel(of: "controlled-search-source") { $0 == "Value Source: State And Props" }
        }

        for word in ["code12", "code34"] {
            let typed = try await app.offsider("type --into-id controlled-search-field --replace --verify --retries 0 '\(word)'")
            try await app.run("wait --settled --ignore-values --timeout 5")
            let held = try await app.label(of: "controlled-search-value") == "Query: \(word.uppercased())"

            #expect(typed.exitCode == (held ? 0 : 5), "exit \(typed.exitCode) with the word \(held ? "held" : "not held"): \(typed.stderr)")
        }
    }

    @Test("in the slow search field, a plain replace leaves the word every time, as the read straight after it shows", arguments: RNPlatform.enabled, [false, true])
    func slowSearchFieldHoldsTheWord(platform: RNPlatform, twoSources: Bool) async throws {
        let app = RNApp(platform)
        try await app.open("controlled-search-test")
        if twoSources {
            try await app.run("tap --id controlled-search-source")
            _ = try await app.waitForLabel(of: "controlled-search-source") { $0 == "Value Source: State And Props" }
        }

        for round in 1...10 {
            let typed = try await app.offsider("type --into-id controlled-search-field --replace 'code12'")
            #expect(typed.exitCode == 0, "round \(round): \(typed.stderr)")
            // The read straight after: the field holds every key, though its capitals may still be on their way from JavaScript.
            let field = try await app.waitForNode { $0["id"] as? String == "controlled-search-field" }
            #expect((field["value"] as? String)?.uppercased() == "CODE12", "round \(round)")
            try await app.run("wait --settled --ignore-values --timeout 5")
            #expect(try await app.label(of: "controlled-search-value") == "Query: CODE12", "round \(round)")
        }
    }

    @Test("type returns once the field holds the text: the read straight after ten characters shows all ten", arguments: RNPlatform.enabled)
    func typeReturnsWithTheText(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("text-input")

        for round in 1...5 {
            try await app.run("type --into-id text-input-field --replace ''")
            try await app.run("type --into-id text-input-field 'samfixture'")
            let field = try await app.waitForNode { $0["id"] as? String == "text-input-field" }
            #expect(field["value"] as? String == "samfixture", "round \(round)")
        }
    }

    @Test("a keypad kept mounted and parked below the screen is not on screen, and a tap on its key is not sent", arguments: RNPlatform.enabled)
    func parkedKeypad(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("cover-test")

        let waited = try await app.offsider("wait --id cover-test-key-5 --timeout 1")
        #expect(waited.exitCode == 5, "\(waited.stdout)\(waited.stderr)")
        let tapped = try await app.offsider("tap --id cover-test-key-5")
        #expect(tapped.exitCode != 0, "\(tapped.stdout)")
        #expect(try await app.label(of: "cover-test-amount") == "Amount, 0, Points")
    }
}
