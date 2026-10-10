import Foundation
import Testing
import OffsiderCore

@Suite("Change Detector Tests")
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

@Suite("Change Detector live keys")
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
}
