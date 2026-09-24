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
}
