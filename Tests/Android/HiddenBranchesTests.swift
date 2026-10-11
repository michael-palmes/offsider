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

    @Test("a describe-ui JSON with hidden decodes back to the same context")
    func roundTrip() throws {
        var tree = UITree(platform: .android, device: "emulator-5556", roots: [])
        tree.hiddenBranches = 4

        #expect(try UITree(jsonData: tree.jsonData()).context.hidden == 4)
    }
}
