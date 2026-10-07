import Foundation
import Testing
import OffsiderCore

@Suite("Live text")
struct LiveTextTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func ticker(_ price: String, extra: [UINode] = [], native: Bool = true) -> UITree {
        func typed(_ node: UINode, _ type: String) -> UINode {
            var node = node
            if native { node.native = .ios(IOSNativeAttributes(type: type)) }
            return node
        }
        return FakeUI.tree([
            typed(FakeUI.node(.text, id: "live-ticker-price", label: price, frame: FakeUI.frame(16, 100, 370, 40)), "StaticText"),
            typed(FakeUI.node(.text, id: "live-ticker-orders", label: "Orders (24h)", value: "18,402", frame: FakeUI.frame(16, 160, 200, 20)), "StaticText"),
            typed(FakeUI.node(.switch, id: "live-ticker-toggle", label: "Price Alerts", frame: FakeUI.frame(16, 200, 52, 32), state: UIState(checked: false)), "Switch"),
            typed(FakeUI.node(.button, id: "live-ticker-noop", label: "Do Nothing", frame: FakeUI.frame(16, 260, 180, 44)), "Button"),
        ] + extra)
    }

    /// The cached record as a command leaves it on disk, so the tree carries no native types.
    static func record(_ tree: UITree, readAgo: TimeInterval = 10, inputAgo: TimeInterval? = 30, role: TreeCacheRecord.TreeRole = .read) throws -> TreeCacheRecord {
        let readAt = now.addingTimeInterval(-readAgo)
        let written = TreeCacheRecord(
            platform: tree.platform, device: tree.device, command: "describe-ui", writtenAt: readAt, treeReadAt: readAt,
            lastInputAt: inputAgo.map { now.addingTimeInterval(-$0) }, treeRole: role, roots: tree.roots
        )
        return try TreeCacheRecord(data: written.encoded())
    }

    @Test("text that changed between the cached tree and the first read, with no input between, is learnt live")
    func learnsTicker() throws {
        let live = LiveText.learn(cached: try Self.record(Self.ticker("$129.95")), first: Self.ticker("$131.22"), readAt: Self.now)
        #expect(live.count == 1)
        let names = ChangeDetector().liveChanges(
            AccessibilitySnapshot(tree: Self.ticker("$131.22")), AccessibilitySnapshot(tree: Self.ticker("$132.63")), live: live
        )
        #expect(names == ["live-ticker-price"])
    }

    @Test("nothing is learnt from a cached tree older than 30 s, read within 2 s of its input, read before input, or with no tree", arguments: [
        (31.0, 60.0, TreeCacheRecord.TreeRole.read),
        (10.0, 11.5, .postAction),
        (10.0, 5.0, .preAction),
    ])
    func refusesUntrustedCache(readAgo: TimeInterval, inputAgo: TimeInterval, role: TreeCacheRecord.TreeRole) throws {
        let record = try Self.record(Self.ticker("$129.95"), readAgo: readAgo, inputAgo: inputAgo, role: role)
        #expect(LiveText.learn(cached: record, first: Self.ticker("$131.22"), readAt: Self.now).isEmpty)
        #expect(LiveText.learn(cached: nil, first: Self.ticker("$131.22"), readAt: Self.now).isEmpty)
    }

    @Test("a row added to a list between the cached tree and the first read teaches nothing beneath the list, while the ticker beside it is still learnt")
    func shiftedRowsTeachNothing() throws {
        func screen(_ price: String, orders: [String]) -> UITree {
            let rows = orders.enumerated().map { index, order in
                FakeUI.node(.text, label: order, frame: FakeUI.frame(16, 300 + Double(index) * 40, 370, 40))
            }
            return FakeUI.tree([
                FakeUI.node(.text, id: "live-ticker-price", label: price, frame: FakeUI.frame(16, 100, 370, 40)),
                FakeUI.node(.group, id: "recent-orders", frame: FakeUI.frame(0, 300, 402, 400), children: rows),
            ])
        }
        let orders = ["Kettle x1", "Toaster x2", "Blender x5", "Kettle x3", "Toaster x1"]

        let live = LiveText.learn(
            cached: try Self.record(screen("$129.95", orders: orders)), first: screen("$131.22", orders: ["Blender x2"] + orders), readAt: Self.now
        )

        #expect(live.count == 1)
        #expect(ChangeDetector().liveChanges(
            AccessibilitySnapshot(tree: screen("$131.22", orders: orders)), AccessibilitySnapshot(tree: screen("$132.63", orders: orders)), live: live
        ) == ["live-ticker-price"])
    }

    @Test("a cached tree of another screen teaches nothing, even when its text differs")
    func otherScreenTeachesNothing() throws {
        let other = FakeUI.tree([
            FakeUI.node(.button, id: "live-ticker-detail-back", label: "Back", frame: FakeUI.frame(0, 50, 80, 44)),
            FakeUI.node(.text, id: "live-ticker-price", label: "$1.00", frame: FakeUI.frame(16, 100, 370, 40)),
        ])
        #expect(LiveText.learn(cached: try Self.record(other), first: Self.ticker("$131.22"), readAt: Self.now).isEmpty)
    }

    @Test("LogBox toasts come out of the tree with their frames; other nodes stay")
    func stripsToasts() {
        let toast = FakeUI.node(.other, label: "!, OffsiderFixture warning toast", frame: FakeUI.frame(10, 806, 382, 48))
        let stripped = LiveText.withoutLogBoxToasts(Self.ticker("$1.00", extra: [toast]))
        #expect(stripped.toasts == [FakeUI.frame(10, 806, 382, 48)])
        #expect(stripped.tree == Self.ticker("$1.00"))
        #expect(LiveText.withoutLogBoxToasts(Self.ticker("$1.00")).toasts.isEmpty)
    }

    @Test("the LogBox inspector opening is told apart from one that was already open")
    func inspectorOpened() {
        let inspector = FakeUI.node(.text, label: "Log 1 of 2", frame: FakeUI.frame(0, 60, 402, 30))
        let closed = Self.ticker("$1.00")
        let open = Self.ticker("$1.00", extra: [inspector])
        #expect(LiveText.logBoxOpened(before: closed, after: open))
        #expect(!LiveText.logBoxOpened(before: open, after: open))
        #expect(!LiveText.logBoxOpened(before: closed, after: closed))
    }
}
