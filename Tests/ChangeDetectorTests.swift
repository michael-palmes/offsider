import Foundation
import Testing
import OffsiderCore

@Suite("Change Detector Tests", .personOutput)
struct ChangeDetectorTests {
    private let detector = ChangeDetector()

    private func element(
        _ type: String = "StaticText",
        id: String? = nil,
        label: String? = nil,
        value: String? = nil,
        frame: [Double] = [20, 100, 200, 30]
    ) -> String {
        func json(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "null" }
        return """
        {"type": "\(type)", "AXUniqueId": \(json(id)), "AXLabel": \(json(label)), "AXValue": \(json(value)),
         "role": "AXStaticText", "enabled": true, "pid": 42, "traits": [],
         "frame": {"x": \(frame[0]), "y": \(frame[1]), "width": \(frame[2]), "height": \(frame[3])},
         "children": []}
        """
    }

    private func app(_ label: String = "OffsiderPlayground", pid: Int = 42, children: [String]) throws -> AccessibilitySnapshot {
        let json = """
        [{"type": "Application", "AXLabel": "\(label)", "role": "AXApplication", "pid": \(pid),
          "frame": {"x": 0, "y": 0, "width": 402, "height": 874},
          "children": [\(children.joined(separator: ","))]}]
        """
        return try AccessibilitySnapshot(jsonData: Data(json.utf8))
    }

    @Test("Identical trees are unchanged")
    func identicalTreesAreUnchanged() throws {
        let tree = try app(children: [element(id: "tap-count", label: "Tap Count: 0", value: "0")])
        #expect(detector.compare(tree, tree) == .unchanged)
    }

    @Test("Differences in ignored fields such as pid are unchanged")
    func ignoredFieldsDoNotCount() throws {
        let before = try app(pid: 1, children: [element(id: "tap-count", value: "0")])
        let after = try app(pid: 2, children: [element(id: "tap-count", value: "0")])
        #expect(detector.compare(before, after) == .unchanged)
    }

    @Test("A value change is reported with the element and both values")
    func valueChangeNamesTheElement() throws {
        let before = try app(children: [element(id: "tap-count", value: "0")])
        let after = try app(children: [element(id: "tap-count", value: "1")])
        #expect(detector.compare(before, after) == .changed(summary: #"value of tap-count changed from "0" to "1""#))
    }

    @Test("A label change is changed and names the element")
    func labelChangeIsChanged() throws {
        let before = try app(children: [element(id: "state", label: "Initial")])
        let after = try app(children: [element(id: "state", label: "Tapped")])
        guard case .changed(let summary) = detector.compare(before, after) else {
            Issue.record("Expected a change")
            return
        }
        #expect(summary.contains("state"))
        #expect(summary.contains("Tapped"))
    }

    @Test("An added element is changed, and generated ids read as <uuid>")
    func addedElementIsChanged() throws {
        let before = try app(children: [element(id: "tap-count")])
        let after = try app(children: [
            element(id: "tap-count"),
            element("Other", id: "tap-indicator-\(UUID().uuidString)"),
        ])
        #expect(detector.compare(before, after) == .changed(summary: "element added: Other#tap-indicator-<uuid>"))
    }

    @Test("for an agent, an element's id in a change is JSON-quoted", .agentOutput)
    func agentQuotesIdentifiers() throws {
        let before = try app(children: [element(id: "sheet"), element(id: "title")])
        let after = try app(children: [element(id: "title")])
        #expect(detector.compare(before, after) == .changed(summary: #"element removed: StaticText#"sheet""#))
    }

    @Test("A removed element is changed")
    func removedElementIsChanged() throws {
        let before = try app(children: [element(id: "sheet"), element(id: "title")])
        let after = try app(children: [element(id: "title")])
        #expect(detector.compare(before, after) == .changed(summary: "element removed: StaticText#sheet"))
    }

    @Test("An empty root on either side is unknown, never unchanged")
    func emptyRootIsUnknown() throws {
        let empty = try app(children: [])
        let full = try app(children: [element(id: "tap-count")])
        #expect(detector.compare(empty, full) == .unknown)
        #expect(detector.compare(full, empty) == .unknown)
        #expect(detector.compare(empty, empty) == .unknown)
        #expect(!empty.isKnown)
    }

    @Test("Sub-point frame jitter is unchanged; a 10 pt move is changed")
    func frameTolerance() throws {
        let before = try app(children: [element(id: "box", frame: [20, 100, 200, 30])])
        let jitter = try app(children: [element(id: "box", frame: [20.3, 100.2, 200, 30])])
        let moved = try app(children: [element(id: "box", frame: [30, 100, 200, 30])])
        #expect(detector.compare(before, jitter) == .unchanged)
        #expect(detector.compare(before, moved) != .unchanged)
    }

    @Test("An identifier regenerated from UUID() with the same content is unchanged")
    func regeneratedUUIDIsUnchanged() throws {
        let before = try app(children: [element("Other", id: "row-\(UUID().uuidString)", label: "Row")])
        let after = try app(children: [element("Other", id: "row-\(UUID().uuidString)", label: "Row")])
        #expect(detector.compare(before, after) == .unchanged)
    }

    @Test("A change only on a key that moved between baseline reads is unchanged")
    func volatileKeysAreIgnored() throws {
        let baselineA = try app(children: [element(id: "spinner", value: "1"), element(id: "tap-count", value: "0")])
        let baselineB = try app(children: [element(id: "spinner", value: "2"), element(id: "tap-count", value: "0")])
        let volatile = detector.volatileKeys(baselineA, baselineB)
        let after = try app(children: [element(id: "spinner", value: "3"), element(id: "tap-count", value: "0")])
        #expect(!volatile.isEmpty)
        #expect(detector.compare(baselineB, after, ignoring: volatile) == .unchanged)

        let realChange = try app(children: [element(id: "spinner", value: "3"), element(id: "tap-count", value: "1")])
        #expect(detector.compare(baselineB, realChange, ignoring: volatile) != .unchanged)
    }

    @Test("A different frontmost app is changed")
    func differentRootAppIsChanged() throws {
        let playground = try app(children: [element(id: "button-test-screen")])
        let springBoard = try app("SpringBoard", children: [element("Icon", label: "Settings")])
        #expect(detector.compare(playground, springBoard) != .unchanged)
    }

    @Test("A single root object decodes like an array of roots")
    func singleRootDecodes() throws {
        let object = try AccessibilitySnapshot(jsonData: Data(element(id: "only").utf8))
        let array = try AccessibilitySnapshot(jsonData: Data("[\(element(id: "only"))]".utf8))
        #expect(object == array)
        #expect(throws: (any Error).self) { try AccessibilitySnapshot(jsonData: Data("42".utf8)) }
    }

    @Test("ignoring text and frames, a ticking label, a new value and a move are unchanged, and an added element still counts")
    func ignoreText() throws {
        let detector = ChangeDetector(options: .init(ignoreText: true, ignoreFrames: true))
        let before = try app(children: [element(id: "clock", label: "12:00:01", value: "1")])
        let ticked = try app(children: [element(id: "clock", label: "12:00:02", value: "2", frame: [20, 140, 200, 30])])
        #expect(detector.compare(before, ticked) == .unchanged)

        let added = try app(children: [element(id: "clock", label: "12:00:02"), element(id: "toast", label: "Saved")])
        #expect(detector.compare(before, added) == .changed(summary: "element added: StaticText#toast"))
    }

    @Test("ignoring text alone, a ticking label is unchanged even as it resizes with its text, but a move of steady text still counts")
    func ignoreTextKeepsFrames() throws {
        let detector = ChangeDetector(options: .init(ignoreText: true))
        let before = try app(children: [element(id: "clock", label: "12:00:01"), element(id: "title", label: "Title", frame: [20, 40, 200, 30])])
        let ticked = try app(children: [element(id: "clock", label: "12:00:02", frame: [10, 100, 210, 30]), element(id: "title", label: "Title", frame: [20, 40, 200, 30])])
        let moved = try app(children: [element(id: "clock", label: "12:00:02"), element(id: "title", label: "Title", frame: [20, 80, 200, 30])])
        #expect(detector.compare(before, ticked) == .unchanged)
        #expect(detector.compare(before, moved) == .changed(summary: "title moved or resized"))
    }
}

@Suite("Change Detector live keys", .personOutput)
struct ChangeDetectorLiveTests {
    private let detector = ChangeDetector()

    /// With `native`, each node carries the native type a fresh read has; without, it has only its role, as the cache keeps it.
    private static func screen(heartRate: String, heartRateWidth: Double = 370, alerts: Bool = false, extra: [UINode] = [], native: Bool = true) -> AccessibilitySnapshot {
        func typed(_ node: UINode, _ type: String) -> UINode {
            var node = node
            if native { node.native = .ios(IOSNativeAttributes(type: type)) }
            return node
        }
        let nodes = [
            typed(FakeUI.node(.text, id: "heart-rate", label: heartRate, frame: FakeUI.frame(16, 100, heartRateWidth, 40)), "StaticText"),
            typed(FakeUI.node(.switch, id: "alerts", label: "Goal Alerts", frame: FakeUI.frame(16, 200, 52, 32), state: UIState(checked: alerts)), "Switch"),
        ] + extra
        let root = typed(FakeUI.node(.application, label: "Playground", frame: FakeUI.frame(0, 0, 402, 874), children: nodes), "Application")
        return AccessibilitySnapshot(tree: UITree(platform: .ios, device: "fake", roots: [root]))
    }

    @Test("a tree without native types, as the cache keeps it, lines up with a fresh read, so the ticking heart rate is learnt live")
    func cachedTreeLinesUp() {
        let cached = Self.screen(heartRate: "60 bpm", native: false)
        let fresh = Self.screen(heartRate: "62 bpm")
        #expect(detector.sharedKeyFraction(cached, fresh) == 1)
        let live = detector.liveTextKeys(cached, fresh)
        #expect(live.count == 1)
        #expect(detector.liveChanges(cached, fresh, live: live) == ["heart-rate"])
    }

    @Test("a live key's text and own frame never count, while its siblings' state and added elements still do")
    func liveKeysIgnoreTextOnly() {
        let live = detector.liveTextKeys(Self.screen(heartRate: "60 bpm"), Self.screen(heartRate: "62 bpm"))
        let baseline = Self.screen(heartRate: "62 bpm")
        let wider = Self.screen(heartRate: "102 bpm", heartRateWidth: 390)
        #expect(detector.compare(baseline, wider, live: live) == .unchanged)
        #expect(detector.compare(baseline, wider) != .unchanged)
        let switched = Self.screen(heartRate: "63 bpm", alerts: true)
        #expect(detector.compare(baseline, switched, live: live) == .changed(summary: "checked state of alerts changed"))
        let toast = Self.screen(heartRate: "64 bpm", extra: [FakeUI.node(.text, id: "saved", label: "Saved", frame: FakeUI.frame(16, 300, 100, 20))])
        #expect(detector.compare(baseline, toast, live: live) == .changed(summary: "element added: text#saved"))
    }

    @Test("an element added to a flat screen beside the ticker still lets the ticker be learnt")
    func addedElementKeepsLearning() {
        let toast = FakeUI.node(.text, id: "saved", label: "Saved", frame: FakeUI.frame(16, 300, 100, 20))
        let after = Self.screen(heartRate: "62 bpm", extra: [toast])

        let live = detector.liveTextKeys(Self.screen(heartRate: "60 bpm"), after)

        #expect(live.count == 1)
        #expect(detector.liveChanges(after, Self.screen(heartRate: "63 bpm", extra: [toast]), live: live) == ["heart-rate"])
    }

    @Test("a row without an id added before a ticking text without one is lined up, so the ticker's key is the one later reads give it")
    func insertedRowKeepsLaterKeys() {
        func screen(clock: String, saved: String?) -> AccessibilitySnapshot {
            let banner = saved.map { [FakeUI.node(.text, label: $0, frame: FakeUI.frame(16, 60, 200, 20))] } ?? []
            return AccessibilitySnapshot(tree: FakeUI.tree(banner + [
                FakeUI.node(.button, id: "refresh", label: "Refresh", frame: FakeUI.frame(16, 100, 120, 44)),
                FakeUI.node(.text, label: clock, frame: FakeUI.frame(16, 160, 200, 20)),
            ]))
        }
        let after = screen(clock: "Updated 12:00:02", saved: "Saved")

        let live = detector.liveTextKeys(screen(clock: "Updated 12:00:01", saved: nil), after)

        #expect(live.count == 1)
        #expect(detector.compare(after, screen(clock: "Updated 12:00:03", saved: "Saved"), live: live) == .unchanged)
        #expect(detector.compare(after, screen(clock: "Updated 12:00:02", saved: "Saved again"), live: live) != .unchanged)
    }

    @Test("reads of different screens share few keys")
    func differentScreensShareFewKeys() {
        let other = AccessibilitySnapshot(tree: FakeUI.tree([FakeUI.node(.button, id: "back", label: "Back"), FakeUI.node(.text, id: "title", label: "Detail")]))
        #expect(detector.sharedKeyFraction(Self.screen(heartRate: "60 bpm"), other) < LiveText.minimumSharedKeys)
    }

    @Test("masking live text gives every read of the ticker the same text, so the change list passes over it")
    func maskingLive() {
        func tree(_ heartRate: String, alerts: Bool) -> UITree {
            FakeUI.tree([
                FakeUI.node(.text, id: "heart-rate", label: heartRate, frame: FakeUI.frame(16, 100, 370, 40)),
                FakeUI.node(.switch, id: "alerts", label: "Goal Alerts", frame: FakeUI.frame(16, 200, 52, 32), state: UIState(checked: alerts)),
            ])
        }
        let live = detector.liveTextKeys(AccessibilitySnapshot(tree: tree("60 bpm", alerts: false)), AccessibilitySnapshot(tree: tree("61 bpm", alerts: false)))
        let diff = TreeDiff.diff(old: detector.maskingLive(tree("61 bpm", alerts: false), live: live), new: detector.maskingLive(tree("67 bpm", alerts: true), live: live))
        #expect(diff.entries.map(\.key) == ["#alerts"])
    }

    private static func group(id: String? = nil, _ frame: AccessibilitySnapshot.Frame, children: [AccessibilitySnapshot.Node] = []) -> AccessibilitySnapshot.Node {
        AccessibilitySnapshot.Node(type: "Group", identifier: id, frame: frame, children: children)
    }

    private static func page(_ children: [AccessibilitySnapshot.Node]) -> AccessibilitySnapshot {
        AccessibilitySnapshot(roots: [group(.init(x: 0, y: 0, width: 400, height: 800), children: children)])
    }

    private static let rest = group(id: "rest", .init(x: 0, y: 700, width: 400, height: 50))

    @Test("the moving part is the nearest element holding every change, named by its id")
    func movingPartNamesTheHolder() {
        let before = Self.page([Self.group(id: "chart", .init(x: 20, y: 100, width: 300, height: 200), children: [
            Self.group(.init(x: 30, y: 110, width: 20, height: 50)),
            Self.group(.init(x: 60, y: 110, width: 20, height: 50)),
        ]), Self.rest])
        let after = Self.page([Self.group(id: "chart", .init(x: 20, y: 100, width: 300, height: 200), children: [
            Self.group(.init(x: 30, y: 120, width: 20, height: 40)),
            Self.group(.init(x: 60, y: 90, width: 20, height: 70)),
        ]), Self.rest])

        let part = ChangeDetector().movingPart(before, after)

        #expect(part == .id("chart"))
        #expect(part?.flag == "--ignore-id chart")
    }

    @Test("with no id a command line can carry, the moving part is a rectangle of whole points around the changes, on the screen", arguments: [nil, "Bar chart", "--force", "bad\nid"])
    func movingPartFallsBackToARegion(id: String?) {
        let before = Self.page([Self.group(id: id, .init(x: 20.4, y: 100.6, width: 300, height: 200)), Self.rest])
        let after = Self.page([Self.group(id: id, .init(x: 20.4, y: 110.2, width: 399.8, height: 200)), Self.rest])

        let part = ChangeDetector().movingPart(before, after)

        #expect(part?.flag == "--ignore-region 20,100,380,211")
    }

    @Test("a change across most of the screen offers no flag, since leaving it out would leave nothing to wait for")
    func movingPartRefusesMostOfTheScreen() {
        let before = Self.page([Self.group(id: "main", .init(x: 0, y: 0, width: 400, height: 780))])
        let after = Self.page([Self.group(id: "main", .init(x: 0, y: 10, width: 400, height: 780))])
        #expect(ChangeDetector().movingPart(before, after) == nil)
    }

    @Test("two changes with no element holding both give the rectangle around them")
    func movingPartAcrossSiblings() {
        let before = Self.page([Self.group(.init(x: 10, y: 10, width: 50, height: 50)), Self.group(.init(x: 100, y: 200, width: 50, height: 50)), Self.rest])
        let after = Self.page([Self.group(.init(x: 12, y: 10, width: 50, height: 50)), Self.group(.init(x: 102, y: 200, width: 50, height: 50)), Self.rest])
        #expect(ChangeDetector().movingPart(before, after)?.flag == "--ignore-region 10,10,142,240")
    }

    @Test("a masked id is never printed in the flag")
    func movingPartHidesAMaskedID() async throws {
        let mask = TreeValueMask(ids: ["secret-chart"])
        let before = Self.page([Self.group(id: "secret-chart", .init(x: 20, y: 100, width: 300, height: 200)), Self.rest])
        let after = Self.page([Self.group(id: "secret-chart", .init(x: 20, y: 110, width: 300, height: 200)), Self.rest])
        await OutputMasks.$current.withValue(OutputMasks { mask }) {
            #expect(ChangeDetector().movingPart(before, after)?.flag == "--ignore-region 20,100,300,210")
        }
    }

    @Test("a region never leaves out the page holding it, or the root, however much of them it covers")
    func regionKeepsContainers() throws {
        let bar = Self.group(id: "bar", .init(x: 0, y: 150, width: 50, height: 50))
        let far = Self.group(id: "far", .init(x: 0, y: 700, width: 50, height: 50))
        let snapshot = Self.page([Self.group(id: "content", .init(x: 0, y: 100, width: 400, height: 660), children: [bar, far])])

        let kept = snapshot.leavingOut([PointRegion(x: 0, y: 100, width: 400, height: 500)])

        let content = try #require(kept.roots.first?.children.first)
        #expect(content.identifier == "content")
        #expect(content.children.map(\.identifier) == ["far"])
    }

    @Test("a region leaves out elements at least half inside it with everything under them, and keeps the rest")
    func regionLeavesOut() throws {
        let inside = Self.group(id: "half", .init(x: 0, y: 150, width: 100, height: 100), children: [Self.group(id: "child-far-away", .init(x: 300, y: 600, width: 10, height: 10))])
        let less = Self.group(id: "less", .init(x: 0, y: 170, width: 100, height: 100))
        let flat = Self.group(id: "flat", .init(x: 10, y: 110, width: 0, height: 0))
        let snapshot = Self.page([inside, less, flat, Self.rest])

        let kept = snapshot.leavingOut([PointRegion(x: 0, y: 100, width: 100, height: 100)])

        let ids = try #require(kept.roots.first).children.map(\.identifier)
        #expect(ids == ["less", "flat", "rest"])
        #expect(snapshot.leavingOut([]) == snapshot)
    }
}
