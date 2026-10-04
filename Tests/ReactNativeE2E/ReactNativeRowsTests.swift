import Foundation
import Testing

@Suite("React Native rows", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeRowsTests {
    static let terms = AndroidE2E.quote("I've Read the Terms")

    /// Swipes the list up until the footer sits wholly on screen.
    static func scrollToFooter(_ app: RNApp) async throws {
        for _ in 0..<20 {
            let tree = try await app.tree()
            if let node = DescribeUITree.node(id: "rows-test-footer", in: tree),
               let frame = node["frame"] as? [String: Double],
               let y = frame["y"], let height = frame["height"],
               let screen = DescribeUITree.screenSize(in: tree),
               y >= 0, y + height <= screen.height {
                return
            }
            try await app.run("gesture scroll-up")
            try await Task.sleep(for: .milliseconds(800))
        }
        throw DescribeUIError(description: "rows-test-footer never came wholly on screen after 20 swipes")
    }

    @Test("an ASCII apostrophe matches the typographic footer label once it is scrolled into view", arguments: RNPlatform.enabled)
    func quoteFoldingAfterScroll(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")

        let belowFold = try await app.offsider("tap --label \(Self.terms)")
        #expect(belowFold.exitCode != 0)
        switch platform {
        case .ios:
            #expect(belowFold.stderr.contains("is off screen"), "iOS keeps rows below the fold in the tree: \(belowFold.stderr)")
        case .android:
            #expect(belowFold.stderr.contains("No accessibility element matched"), "Android's helper omits rows below the fold: \(belowFold.stderr)")
        }
        #expect(try await app.label(of: "rows-test-state") == "Rows Selected: None")

        try await Self.scrollToFooter(app)
        try await app.run("tap --label \(Self.terms)")

        _ = try await app.waitForLabel(of: "rows-test-state") { $0 == "Rows Selected: Terms" }
    }

    @Test("a near-miss label suggests the real one", arguments: RNPlatform.enabled)
    func nearMissSuggests(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")
        try await Self.scrollToFooter(app)

        let result = try await app.offsider("tap --label 'Ive Read the Term'")

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("Did you mean 'I’ve Read the Terms'?"), "\(result.stderr)")
        #expect(try await app.label(of: "rows-test-state") == "Rows Selected: None")
    }

    @Test("an unlabelled row merges its texts and takes a coordinate tap", arguments: RNPlatform.enabled)
    func unlabelledRowCoordinateTap(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")

        // Observed on both platforms: "Inbox, 3 unread"; Android also lists the two texts as children.
        let inbox = try await app.waitForNode { node in
            let label = node["label"] as? String ?? ""
            return label.contains("Inbox") && label.contains("3 unread")
        }
        let centre = try #require(DescribeUITree.centre(of: inbox))
        try await app.run("tap -x \(centre.x) -y \(centre.y)")

        _ = try await app.waitForLabel(of: "rows-test-state") { $0 == "Rows Selected: Inbox" }
    }

    @Test("the live row's merged label changes on its own", arguments: RNPlatform.enabled)
    func liveRowLabelChanges(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")
        func downloadRow() async throws -> String? {
            DescribeUITree.nodes(in: try await app.tree())
                .compactMap { $0["label"] as? String }
                .first { $0.contains("Downloads") && $0.contains("complete") }
        }

        let first = try await downloadRow()
        try await Task.sleep(for: .milliseconds(2_500))
        let second = try await downloadRow()

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second, "the Downloads row should change between reads")
    }

    @Test("describe-ui --summary is short, summarises rows below the fold and folds labels the row shows", arguments: RNPlatform.enabled)
    func summaryIsShort(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")

        let summary = try await app.run("describe-ui --summary").stdout
        let full = try await app.run("describe-ui").stdout

        #expect(summary.utf8.count < 10_000, "summary was \(summary.utf8.count) bytes")
        #expect(summary.contains("rows-test-state"))
        #expect(!summary.contains("rows-test-item-40"))
        switch platform {
        case .ios:
            #expect(full.contains("rows-test-item-40"), "iOS lists every row of a non-virtualised ScrollView")
            #expect(summary.contains("[off-screen below]"))
        case .android:
            #expect(!full.contains("rows-test-item-40"), "Android's helper omits rows below the fold from every view")
            #expect(!summary.contains(#"text "Inbox""#), "the row's child texts repeat its merged label")
            #expect(summary.contains("# folded "))
        }
    }
}
