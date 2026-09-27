import Foundation
import OffsiderCore
import Testing

@Suite("Accessibility Snapshot Tree Tests")
struct AccessibilitySnapshotTreeTests {
    private let detector = ChangeDetector()

    private func iosJSON(switchValue: String, extra: String = "") -> String {
        """
        [{"type": "Application", "AXLabel": "Playground", "role": "AXApplication", "pid": 42, "enabled": true,
          "frame": {"x": 0, "y": 0, "width": 402, "height": 874},
          "children": [
            {"type": "StaticText", "role": "AXStaticText", "AXLabel": "Weather Alerts", "title": null, "enabled": true,
             "frame": {"x": 16, "y": 120, "width": 140, "height": 20}},
            {"type": "Switch", "role": "AXCheckBox", "subrole": "AXSwitch", "AXUniqueId": "weather-switch",
             "AXLabel": "Weather Alerts", "AXValue": "\(switchValue)", "enabled": true,
             "frame": {"x": 300, "y": 110, "width": 51, "height": 31}}\(extra)
          ]}]
        """
    }

    private func treeSnapshot(_ json: String) throws -> AccessibilitySnapshot {
        let roots = try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
        return AccessibilitySnapshot(tree: UITree(platform: .ios, device: "D", roots: roots))
    }

    private func withoutState(_ nodes: [AccessibilitySnapshot.Node]) -> [AccessibilitySnapshot.Node] {
        nodes.map { node in
            var copy = node
            copy.state = UIState()
            copy.children = withoutState(node.children)
            return copy
        }
    }

    private func android(_ className: String, label: String? = nil, id: String? = nil, checked: Bool? = nil) -> UINode {
        UINode(
            role: .switch,
            id: id,
            label: label,
            state: UIState(checked: checked),
            native: .android(AndroidNativeAttributes(className: className))
        )
    }

    private func androidSnapshot(_ children: [UINode]) -> AccessibilitySnapshot {
        let root = UINode(role: .application, native: .android(AndroidNativeAttributes()), children: children)
        return AccessibilitySnapshot(tree: UITree(platform: .android, device: "emulator-5554", roots: [root]))
    }

    @Test("an iOS tree snapshot matches the raw JSON snapshot apart from state")
    func iosTreeMatchesJSONPath() throws {
        let json = iosJSON(switchValue: "0")
        let fromTree = try treeSnapshot(json)
        let fromJSON = try AccessibilitySnapshot(jsonData: Data(json.utf8))

        #expect(withoutState(fromTree.roots) == fromJSON.roots)
        #expect(fromTree.roots.first?.children.last?.state.checked == false)
    }

    @Test("an iOS switch toggle still reports its value change first")
    func iosSwitchSummaryUnchanged() throws {
        let before = try treeSnapshot(iosJSON(switchValue: "0"))
        let after = try treeSnapshot(iosJSON(switchValue: "1"))

        #expect(detector.compare(before, after) == .changed(summary: "value of weather-switch changed from \"0\" to \"1\""))
    }

    @Test("iOS keys use the native type and identifier")
    func iosKeysUseNativeType() throws {
        let extra = #", {"type": "Button", "role": "AXButton", "AXUniqueId": "save", "AXLabel": "Save", "frame": {"x": 16, "y": 200, "width": 80, "height": 44}}"#
        let before = try treeSnapshot(iosJSON(switchValue: "0"))
        let after = try treeSnapshot(iosJSON(switchValue: "0", extra: extra))

        #expect(detector.compare(before, after) == .changed(summary: "element added: Button#save"))
    }

    @Test("a checked change with no value change is reported as a checked state change")
    func checkedStateChange() {
        let before = androidSnapshot([android("android.widget.Switch", label: "Alerts", checked: false)])
        let after = androidSnapshot([android("android.widget.Switch", label: "Alerts", checked: true)])

        #expect(detector.compare(before, after) == .changed(summary: "checked state of Switch \"Alerts\" changed"))
    }

    @Test("an unchanged checked state compares as unchanged")
    func unchangedState() {
        let before = androidSnapshot([android("android.widget.Switch", id: "alerts", checked: true)])
        let after = androidSnapshot([android("android.widget.Switch", id: "alerts", checked: true)])

        #expect(detector.compare(before, after) == .unchanged)
    }

    @Test("a node without a native type is keyed and described by its role")
    func typeFallsBackToRole() {
        let node = UINode(role: .button, native: .android(AndroidNativeAttributes()))
        let snapshot = AccessibilitySnapshot(tree: UITree(platform: .android, device: "D", roots: [node]))

        #expect(snapshot.roots.first?.type == "button")
        #expect(snapshot.roots.first?.role == "button")
        #expect(snapshot.roots.first?.subrole == nil)
    }
}
