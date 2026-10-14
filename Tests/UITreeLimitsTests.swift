import Foundation
import OffsiderCore
import Testing

@Suite("Tree limits")
struct UITreeLimitsTests {
    /// iOS accessibility JSON nested `depth` levels deep, one element per level.
    static func nested(_ depth: Int) -> Data {
        var json = #"{"type":"StaticText","AXLabel":"leaf"}"#
        for level in 1..<depth { json = #"{"type":"Group","AXLabel":"level \#(level)","children":[\#(json)]}"# }
        return Data(json.utf8)
    }

    static func depth(of nodes: [UINode]) -> Int {
        nodes.map { 1 + depth(of: $0.children) }.max() ?? 0
    }

    @Test("a tree 70 levels deep is cut to 64 and says so in one note line")
    func depthCut() throws {
        let tree = UITree(platform: .ios, device: "D", roots: try IOSAccessibilityMapping.roots(fromJSON: Self.nested(70)))
        #expect(Self.depth(of: tree.roots) == 64)
        #expect(tree.truncated == UITreeTruncation(depth: true))
        #expect(tree.truncated?.note == "Note: the tree was cut at 64 levels deep, so some elements are not listed.")
    }

    @Test("a tree within the limits is kept whole and unflagged")
    func withinLimits() throws {
        let roots = try IOSAccessibilityMapping.roots(fromJSON: Self.nested(64))
        let tree = UITree(platform: .ios, device: "D", roots: roots)
        #expect(tree.roots == roots)
        #expect(tree.truncated == nil)
    }

    @Test("a describe-ui JSON file with 60,000 elements is capped at 50,000 in reading order")
    func nodeCap() throws {
        let leaves = (0..<59_999).map { #"{"role":"text","label":"n\#($0)","native":{"type":"StaticText"}}"# }.joined(separator: ",")
        let json = #"{"version":2,"platform":"ios","device":"D","roots":[{"role":"group","native":{"type":"Group"},"children":[\#(leaves)]}]}"#
        let tree = try UITree(jsonData: Data(json.utf8))
        let all = tree.roots.flatMap { $0.flattened() }
        #expect(all.count == 50_000)
        #expect(all.last?.label == "n49998")
        #expect(tree.truncated == UITreeTruncation(nodes: true))
        #expect(tree.truncated?.note.contains("50,000 elements") == true)
    }
}
