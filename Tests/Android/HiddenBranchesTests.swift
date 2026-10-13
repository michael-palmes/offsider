import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android hidden branches")
@MainActor
struct HiddenBranchesTests {
    nonisolated static let statsFromTapTest = #""stats":{"windows":2,"trees":1,"nodes":3}"#

    /// The tap-test dump with `stats` in place of its own; nil drops the key.
    static func dump(stats: String?) -> String {
        guard let stats else { return FakeHelperDevice.tapTestDump.replacingOccurrences(of: "," + statsFromTapTest, with: "") }
        return FakeHelperDevice.tapTestDump.replacingOccurrences(of: statsFromTapTest, with: stats)
    }

    static func tree(stats: String?) async throws -> UITree {
        #expect(FakeHelperDevice.tapTestDump.contains("," + statsFromTapTest))
        let device = FakeHelperDevice()
        device.dump = Self.dump(stats: stats)
        let rig = try HelperRig(device)
        let tree = try await rig.read()
        await rig.backend.close()
        return tree
    }

    static func summary(_ tree: UITree) -> String {
        String(decoding: UITreeRenderer.render(tree, .summary), as: UTF8.self)
    }

    static func context(_ tree: UITree) throws -> [String: Any] {
        try #require((try JSONSerialization.jsonObject(with: tree.jsonData()) as? [String: Any])?["context"] as? [String: Any])
    }

    @Test("the helper's count of subtrees not visible to the user is in the summary's header and in JSON", arguments: [(2, "# hidden: 2 branches not visible to the user"), (1, "# hidden: 1 branch not visible to the user")])
    func hiddenBranchesReported(count: Int, line: String) async throws {
        let tree = try await Self.tree(stats: #""stats":{"windows":2,"trees":1,"nodes":3,"skippedInvisible":\#(count)}"#)

        #expect(tree.context.hidden == count)
        #expect(Self.summary(tree).components(separatedBy: "\n").contains(line))
        #expect(try Self.context(tree)["hidden"] as? Int == count)
    }

    @Test("none hidden gives no header line, though JSON says 0")
    func noneHidden() async throws {
        let tree = try await Self.tree(stats: #""stats":{"windows":2,"trees":1,"nodes":3,"skippedInvisible":0}"#)

        #expect(!Self.summary(tree).contains("# hidden"))
        #expect(try Self.context(tree)["hidden"] as? Int == 0)
    }

    @Test("a helper that sends no count, or no stats at all, leaves hidden null", arguments: [statsFromTapTest, nil])
    func olderHelper(stats: String?) async throws {
        let tree = try await Self.tree(stats: stats)

        #expect(tree.context.hidden == nil)
        #expect(try Self.context(tree)["hidden"] is NSNull)
        #expect(!Self.summary(tree).contains("# hidden"))
    }

    @Test("the uiautomator fallback cannot say, so hidden is null")
    func uiautomatorLeavesNull() async throws {
        let server = AndroidBackendTreeTests.server(dump: FakeAdbServer.shell(stdout: AndroidBackendTreeTests.dump(rotation: 0)))

        let tree = try await AndroidBackendTreeTests.backend(server).accessibilityTree(for: AndroidBackendTreeTests.device, point: nil)

        #expect(tree.context.hidden == nil)
    }

    /// Hidden roots as helper 1.6.0 sends them, in pixels at 420 dpi: a drawer by id, a titled sheet clipped below the screen, and a list named by its first labelled row.
    nonisolated static let namedStats = #""stats":{"windows":2,"trees":1,"nodes":3,"skippedInvisible":3,"hiddenBranches":["#
        + #"{"i":-1,"class":"android.view.ViewGroup","package":"com.mpalmes.offsider.playground.rn","resourceId":"drawer","bounds":[0,0,735,2294],"visibleToUser":false},"#
        + #"{"i":-1,"class":"android.view.View","package":"com.mpalmes.offsider.playground.rn","contentDescription":"Filters","bounds":[42,28769,987,2424],"visibleToUser":false},"#
        + #"{"i":-1,"class":"android.widget.ScrollView","package":"com.mpalmes.offsider.playground.rn","bounds":[0,2600,1080,3388],"visibleToUser":false,"children":[{"i":-1,"class":"android.widget.TextView","text":"Long Scroll Row 9","bounds":[0,2600,1080,2726],"visibleToUser":false}]}"#
        + #"]}"#

    @Test("named branches follow the count in the summary, in points, by id, label or the first labelled row")
    func namedInSummary() async throws {
        let tree = try await Self.tree(stats: Self.namedStats)

        #expect(Self.summary(tree).components(separatedBy: "\n").contains(
            #"# hidden: 3 branches not visible to the user: id=drawer at (0, 0) 280x873.9; "Filters" at (16, 10959.6) 360x0; "Long Scroll Row 9" at (0, 990.5) 411.4x300.2"#
        ))
    }

    @Test("JSON names the branches beside the count, which stays an integer")
    func namedInJSON() async throws {
        let context = try Self.context(try await Self.tree(stats: Self.namedStats))

        #expect(context["hidden"] as? Int == 3)
        let branches = try #require(context["hiddenBranches"] as? [[String: Any]])
        #expect(branches.map { $0["id"] as? String } == ["drawer", nil, nil])
        #expect(branches.map { $0["label"] as? String } == [nil, "Filters", "Long Scroll Row 9"])
        #expect(branches.map { $0["className"] as? String } == ["android.view.ViewGroup", "android.view.View", "android.widget.ScrollView"])
        #expect((branches[0]["frame"] as? [String: Any])?["width"] as? Double == 280)
    }

    @Test("a branch's label never comes from a password or editable field, and secrets are masked and cut to 40 characters")
    func labelsAreSafe() async throws {
        let password = #"{"i":-1,"class":"android.widget.EditText","resourceId":"pin","text":"123456","password":true,"bounds":[0,0,10,10],"visibleToUser":false}"#
        let field = #"{"i":-1,"class":"android.widget.EditText","text":"typed text","editable":true,"bounds":[0,0,10,10],"visibleToUser":false}"#
        let group = #"{"i":-1,"class":"android.view.ViewGroup","bounds":[0,0,10,10],"visibleToUser":false,"children":["# + password + "]}"
        let long = #"{"i":-1,"class":"android.view.View","contentDescription":"Signed in as someone@example.com with a very long name","bounds":[0,0,10,10],"visibleToUser":false}"#
        let tree = try await Self.tree(stats: #""stats":{"skippedInvisible":4,"hiddenBranches":["# + [password, field, group, long].joined(separator: ",") + "]}")

        let branches = try #require(tree.context.hiddenBranches)
        #expect(branches.map(\.label) == [nil, nil, nil, "Signed in as [redacted email] with a ve…"])
        #expect(branches.map(\.name) == ["id=pin", "EditText", "ViewGroup", #""Signed in as [redacted email] with a ve…""#])
        #expect(!Self.summary(tree).contains("123456") && !Self.summary(tree).contains("typed text"))
    }

    @Test("branches counted but none named give an empty list and the plain line; no stats give null")
    func countedButUnnamed() async throws {
        let unnamed = try await Self.tree(stats: #""stats":{"skippedInvisible":2,"hiddenBranches":[]}"#)
        #expect(try Self.context(unnamed)["hiddenBranches"] as? [Any] != nil)
        #expect(Self.summary(unnamed).components(separatedBy: "\n").contains("# hidden: 2 branches not visible to the user"))

        let older = try await Self.tree(stats: nil)
        #expect(try Self.context(older)["hiddenBranches"] is NSNull)
    }

    @Test("a describe-ui JSON with hidden decodes back to the same context")
    func roundTrip() throws {
        var tree = UITree(platform: .android, device: "emulator-5556", roots: [])
        tree.hiddenBranches = 4
        tree.namedHiddenBranches = [
            UITreeContext.HiddenBranch(id: "drawer", label: nil, className: "android.view.ViewGroup", frame: UIFrame(x: 0, y: 0, width: 280, height: 874)),
            UITreeContext.HiddenBranch(id: nil, label: "Filters", className: nil, frame: nil),
        ]

        let decoded = try UITree(jsonData: tree.jsonData()).context
        #expect(decoded.hidden == 4)
        #expect(decoded.hiddenBranches == tree.namedHiddenBranches)
    }
}
