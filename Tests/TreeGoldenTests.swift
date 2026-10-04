import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Tree goldens", .enabled(if: !TreeGoldens.isUpdating))
struct TreeGoldenTests {
    static let goldens = TreeGoldens.all()
    static let refresh = "Run `OFFSIDER_GOLDENS_UPDATE=1 swift test --filter TreeGoldenRefresh` to re-render the goldens and review the diff."

    @Test("there are iOS goldens to test")
    func goldensExist() {
        #expect(Self.goldens.contains { $0.platform == .ios })
    }

    @Test("once Android has goldens, both platforms have goldens for the same screens")
    func platformsMatch() {
        let android = Set(Self.goldens.filter { $0.platform == .android }.map(\.screen))
        let ios = Set(Self.goldens.filter { $0.platform == .ios }.map(\.screen))
        #expect(android.isEmpty || android == ios, "only on iOS: \(ios.subtracting(android).sorted()), only on Android: \(android.subtracting(ios).sorted())")
    }

    @Test("every golden's raw capture maps to its committed describe-ui JSON", arguments: goldens)
    func rawMapsToJSON(golden: TreeGoldens.Golden) throws {
        let mapped = String(decoding: try TreeGoldens.tree(of: golden).jsonData(), as: UTF8.self)
        let committed = String(decoding: try golden.data(TreeGoldens.jsonFile), as: UTF8.self)
        #expect(mapped == committed, "\(golden.name) changed. \(Self.refresh)")
    }

    @Test("every golden's describe-ui JSON decodes and re-encodes byte for byte", arguments: goldens)
    func jsonRoundTrips(golden: TreeGoldens.Golden) throws {
        let committed = try golden.data(TreeGoldens.jsonFile)
        #expect(try UITree(jsonData: committed).jsonData() == committed, "\(golden.name)")
    }

    @Test("every golden's summary and text renderings match their committed files", arguments: goldens)
    func renderingsMatch(golden: TreeGoldens.Golden) throws {
        let tree = try UITree(jsonData: try golden.data(TreeGoldens.jsonFile))
        for file in [TreeGoldens.summaryFile, TreeGoldens.textFile] {
            let rendered = String(decoding: TreeGoldens.renderings(of: tree)[file]!, as: UTF8.self)
            let committed = String(decoding: try golden.data(file), as: UTF8.self)
            #expect(rendered == committed, "\(golden.name)/\(file) changed. \(Self.refresh)")
        }
    }

    @Test("every golden has its raw, JSON, summary and text files and nothing else", arguments: goldens)
    func filesComplete(golden: TreeGoldens.Golden) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: golden.directory.path).filter { !$0.hasPrefix(".") }
        #expect(Set(names) == Set(TreeGoldens.files), "\(golden.name) holds \(names.sorted())")
    }

    @Test("tree goldens hold no device ids, serials, home paths, user names or email addresses")
    func noLeaks() throws {
        let files = TreeGoldens.allFiles()
        #expect(!files.isEmpty)
        for file in files {
            let findings = TreeGoldenLeaks.findings(in: try String(contentsOf: file, encoding: .utf8))
            #expect(findings.isEmpty, "\(file.path.replacingOccurrences(of: TreeGoldens.root.path, with: "trees")): \(findings)")
        }
    }

    @Test("the leak check catches each kind of identity", arguments: [
        "1A2B3C4D-1111-4222-8333-123456789ABC", "emulator-5554", "/Users/someone/Library", "dev@example.com", "127.0.0.1", "localhost",
    ])
    func leakCheckCatches(text: String) {
        #expect(!TreeGoldenLeaks.findings(in: "label \(text) here").isEmpty)
    }

    @Test("the scrubber replaces ids, serials and the iOS pid, and refuses a readable secure value")
    func scrubber() throws {
        let raw: [String: Any] = ["type": "Button", "pid": 4242, "AXLabel": "1A2B3C4D-1111-4222-8333-123456789ABC on emulator-5554"]
        let scrubbed = try #require(try TreeGoldenScrubber.scrub(raw, platform: .ios) as? [String: Any])
        #expect(scrubbed["pid"] as? Int == 1000)
        #expect(scrubbed["AXLabel"] as? String == "\(TreeGoldenScrubber.zeroUUID) on <android-device>")
        #expect(throws: TreeGoldenScrubber.SecureValueFound.self) {
            try TreeGoldenScrubber.scrub(["type": "SecureTextField", "AXValue": "hunter2"], platform: .ios)
        }
        #expect(throws: TreeGoldenScrubber.SecureValueFound.self) {
            try TreeGoldenScrubber.scrub(["children": [["password": true, "text": "hunter2"]]], platform: .android)
        }
        _ = try TreeGoldenScrubber.scrub(["type": "SecureTextField", "AXValue": "•••"], platform: .ios)
    }

    @Test("Android raw captures hold no timings, stats or event sequence, which change on every read", arguments: goldens.filter { $0.platform == .android })
    func androidRawIsStable(golden: TreeGoldens.Golden) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: golden.data(TreeGoldens.rawFile)) as? [String: Any])
        let source = try #require(object["source"] as? [String: Any])
        for key in TreeGoldens.volatileAndroidKeys {
            #expect(source[key] == nil, "\(golden.name) raw.json keeps \(key)")
        }
        #expect(source["windows"] != nil)
    }

    @Test("secure fields in the goldens hold no readable value", arguments: goldens)
    func secureFieldsMasked(golden: TreeGoldens.Golden) throws {
        let tree = try UITree(jsonData: try golden.data(TreeGoldens.jsonFile))
        for node in tree.roots.flatMap({ $0.flattened() }) where node.isSecure {
            #expect(node.value.map(TreeGoldenLeaks.isMasked) ?? true, "\(golden.name): \(node.id ?? node.label ?? "secure field")")
        }
        let capture = try RawTreeCapture(jsonData: try golden.data(TreeGoldens.rawFile))
        _ = try TreeGoldenScrubber.scrub(try JSONSerialization.jsonObject(with: capture.source), platform: golden.platform)
    }

    @Test("the choice screen golden reports checkboxes, radio buttons and a switch on iOS")
    func choiceScreenRoles() throws {
        let golden = TreeGoldens.Golden(platform: .ios, screen: "choice-test")
        let nodes = try UITree(jsonData: try golden.data(TreeGoldens.jsonFile)).roots.flatMap { $0.flattened() }
        func node(_ id: String) throws -> UINode { try #require(nodes.first { $0.id == id }, "\(id) missing") }

        #expect(try node("choice-test-checkbox-terms").role == .checkbox)
        #expect(try node("choice-test-checkbox-terms").value == "0")
        #expect(try node("choice-test-checkbox-updates").state.checked == true)
        #expect(try node("choice-test-checkbox-updates").value == "1")
        #expect(try node("choice-test-checkbox-mixed").value == "2")
        #expect(try node("choice-test-radio-medium").role == .radioButton)
        #expect(try node("choice-test-radio-medium").state.checked == true)
        #expect(try node("choice-test-radio-small").state.checked == false)
        #expect(try node("choice-test-switch").role == .switch)
        #expect(try node("choice-test-radio-medium").native.typeName != "RadioButton")
    }

    @Test("an iOS screen's off-screen rows drop out of the on-screen filter")
    func offScreenRows() throws {
        let golden = TreeGoldens.Golden(platform: .ios, screen: "rows-test")
        let tree = try UITree(jsonData: try golden.data(TreeGoldens.jsonFile))
        let all = tree.flatEntries(UITreeFilter()).compactMap(\.node.id)
        let onScreen = tree.flatEntries(UITreeFilter(onScreen: true)).compactMap(\.node.id)
        #expect(all.contains("rows-test-item-40"))
        #expect(!onScreen.contains("rows-test-item-40"))
        #expect(onScreen.contains("rows-test-state"))
    }
}

@Suite("Output economy", .enabled(if: !TreeGoldens.isUpdating))
struct OutputEconomyTests {
    static let goldens = TreeGoldens.all()
    static let raise = "Raising a budget is a reviewed edit of Tests/Goldens/trees/budgets.json."

    @Test("every golden has a budget and every budget has a golden")
    func budgetsCoverGoldens() throws {
        #expect(Set(try TreeGoldens.budgets().keys) == Set(Self.goldens.map(\.name)))
    }

    @Test("no golden's summary or text output exceeds its budget", arguments: goldens)
    func withinBudget(golden: TreeGoldens.Golden) throws {
        let budget = try #require(try TreeGoldens.budgets()[golden.name])
        let renderings = TreeGoldens.renderings(of: try UITree(jsonData: try golden.data(TreeGoldens.jsonFile)))
        let summary = renderings[TreeGoldens.summaryFile]!.count
        let text = renderings[TreeGoldens.textFile]!.count
        #expect(summary <= budget.summary, "\(golden.name) summary is \(summary) bytes, over its \(budget.summary) byte budget. \(Self.raise)")
        #expect(text <= budget.text, "\(golden.name) text is \(text) bytes, over its \(budget.text) byte budget. \(Self.raise)")
    }

    @Test("no budget is more than 20 percent above the output it bounds, or above its 64-byte rounding when that is more", arguments: goldens)
    func noSlack(golden: TreeGoldens.Golden) throws {
        let budget = try #require(try TreeGoldens.budgets()[golden.name])
        let renderings = TreeGoldens.renderings(of: try UITree(jsonData: try golden.data(TreeGoldens.jsonFile)))
        for (name, size, limit) in [
            ("summary", renderings[TreeGoldens.summaryFile]!.count, budget.summary),
            ("text", renderings[TreeGoldens.textFile]!.count, budget.text),
        ] {
            #expect(Double(limit) <= max(Double(size) * 1.2, Double(TreeGoldens.budget(for: size))), "\(golden.name) \(name) budget \(limit) is more than 20 percent above its \(size) bytes; lower it.")
        }
    }
}

/// With OFFSIDER_GOLDENS_UPDATE=1 and no device variables: re-renders every golden from its committed raw capture.
@Suite("Tree golden refresh", .enabled(if: TreeGoldens.isUpdating && !RNPlatform.anyEnabled))
struct TreeGoldenRefreshTests {
    @Test("re-renders the derived files offline and lowers budgets that have slack")
    func rerender() throws {
        for golden in TreeGoldens.all() {
            try TreeGoldens.rerender(golden)
        }
        try TreeGoldens.writeBudgets()
    }
}

@Suite("Target resolution on tree goldens", .enabled(if: !TreeGoldens.isUpdating))
struct TreeGoldenResolutionTests {
    private func roots(_ screen: String) throws -> [UINode] {
        try UITree(jsonData: try TreeGoldens.Golden(platform: .ios, screen: screen).data(TreeGoldens.jsonFile)).roots
    }

    private func reason(_ body: () throws -> Void) -> FailureReason? {
        do {
            try body()
            return nil
        } catch {
            return (error as? ElementResolutionError)?.reason
        }
    }

    @Test("a row below the fold is off screen and a pinned readout resolves")
    func rowsBelowFold() throws {
        let roots = try roots("rows-test")
        #expect(reason { _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("rows-test-item-40")) } == .targetOffScreen)
        _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .id("rows-test-toggle-live"))
    }

    @Test("a React Native radio segment selects by element type on iOS")
    func radioByElementType() throws {
        let tap = try AccessibilityTargetResolver.resolveTap(roots: try roots("toolbar-picker-test"), query: .label("Unread"), elementType: "radioButton")
        #expect(tap.matched?.id == "toolbar-picker-test-filter-unread")
    }
}
