import Foundation
import OffsiderCore
import Testing

@Suite("iOS Accessibility Mapping Tests")
struct IOSAccessibilityMappingTests {
    /// The types the pre-0.3.0 resolver treated as actionable.
    static let legacyActionableTypes = [
        "Button", "Cell", "CheckBox", "Link", "MenuItem", "PopUpButton", "RadioButton", "SecureTextField",
        "SegmentedControl", "Slider", "Switch", "Tab", "TabBarButton", "TextField", "Toggle",
    ]

    private func roots(_ json: String) throws -> [UINode] {
        try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8))
    }

    private func role(_ type: String?, role: String? = nil, subrole: String? = nil, description: String? = nil) -> UIRole {
        IOSAccessibilityMapping.role(type: type, role: role, subrole: subrole, roleDescription: description)
    }

    @Test("neutral fields come from the AX keys and native keeps the iOS attributes")
    func fieldMapping() throws {
        let node = try #require(try roots("""
        [{"type": "Button", "role": "AXButton", "subrole": null, "role_description": "back button",
          "AXUniqueId": "BackButton", "AXLabel": "Offsider Playground", "AXValue": null, "title": null, "help": null,
          "enabled": true, "content_required": false, "pid": 4242, "custom_actions": ["Delete"], "traits": [],
          "AXFrame": "{{16, 62}, {44, 44}}", "frame": {"x": 16, "y": 62, "width": 44, "height": 44}, "children": []}]
        """).first)

        #expect(node.role == .button)
        #expect(node.id == "BackButton")
        #expect(node.label == "Offsider Playground")
        #expect(node.value == nil)
        #expect(node.frame == UIFrame(x: 16, y: 62, width: 44, height: 44))
        #expect(node.enabled == true)
        #expect(node.state == UIState())
        #expect(node.native == .ios(IOSNativeAttributes(
            type: "Button", role: "AXButton", roleDescription: "back button", customActions: ["Delete"],
            contentRequired: false, pid: 4242, axFrame: "{{16, 62}, {44, 44}}"
        )))
        #expect(node.native.typeName == "Button")
    }

    @Test("id falls back to AXIdentifier when AXUniqueId is absent")
    func identifierFallback() throws {
        let nodes = try roots("""
        [{"type": "Button", "AXIdentifier": "legacy-id"},
         {"type": "Button", "AXUniqueId": "unique-id", "AXIdentifier": "legacy-id"}]
        """)

        #expect(nodes.map(\.id) == ["legacy-id", "unique-id"])
    }

    @Test("the iOS 27 keyboard layout group is the keyboard, so the summary and focus checks see it")
    func keyboardLayoutGroup() throws {
        let tree = UITree(platform: .ios, device: "IOS-UDID", roots: try roots("""
        [{"type": "Application", "AXLabel": "App", "children": [
          {"type": "Group", "AXUniqueId": "UIKeyboardLayoutStar Preview", "children": [{"type": "Button", "AXLabel": "q"}]},
          {"type": "Group", "AXUniqueId": "keyboard-help-panel"}]}]
        """))

        #expect(tree.roots[0].children.map(\.role) == [.keyboard, .group])
        #expect(tree.roots[0].children[0].children[0].role == .button)
        #expect(UITreeContext(tree: tree).keyboard)
    }

    @Test("numeric AX values become strings")
    func numericValues() throws {
        let nodes = try roots(#"[{"type": "StaticText", "AXValue": 5}, {"type": "Slider", "AXValue": 0.25}]"#)

        #expect(nodes.map(\.value) == ["5", "0.25"])
    }

    @Test("a single object is one root and children keep their order")
    func singleObjectRoot() throws {
        let nodes = try roots("""
        {"type": "Application", "children": [{"type": "StaticText", "AXLabel": "A"}, {"type": "StaticText", "AXLabel": "B"}]}
        """)

        #expect(nodes.count == 1)
        #expect(nodes.first?.role == .application)
        #expect(nodes.first?.children.map(\.label) == ["A", "B"])
    }

    @Test("JSON that is not an accessibility tree is rejected", arguments: [#""text""#, "42", "[1, 2]"])
    func rejectsNonTree(json: String) {
        #expect(throws: IOSAccessibilityMapping.MappingError.notAnAccessibilityTree) {
            try roots(json)
        }
    }

    @Test("iOS types map to neutral roles", arguments: [
        ("Application", UIRole.application), ("Window", .window), ("Button", .button), ("PopUpButton", .button),
        ("Link", .link), ("MenuItem", .menuItem), ("Tab", .tab), ("TabBarButton", .tab), ("TabBar", .tabBar),
        ("SegmentedControl", .segmentedControl), ("CheckBox", .checkbox), ("RadioButton", .radioButton),
        ("TextField", .textField), ("SecureTextField", .secureTextField), ("SearchField", .searchField),
        ("TextView", .textArea), ("TextEditor", .textArea), ("StaticText", .text), ("Image", .image),
        ("Cell", .cell), ("Table", .list), ("CollectionView", .list), ("ScrollView", .scrollView),
        ("ScrollArea", .scrollView), ("NavigationBar", .header), ("Heading", .header), ("Picker", .picker),
        ("PickerWheel", .picker), ("ProgressIndicator", .progress), ("ActivityIndicator", .progress),
        ("Keyboard", .keyboard), ("Key", .keyboard), ("Group", .group), ("Switch", .switch), ("Toggle", .switch),
        ("Slider", .slider), ("GenericElement", .other), ("Other", .other),
    ])
    func typeTable(type: String, expected: UIRole) {
        #expect(role(type) == expected)
    }

    @Test("switch-like controls are switches whatever their type")
    func switchDetection() {
        #expect(role("CheckBox", subrole: "AXSwitch") == .switch)
        #expect(role("Other", role: "AXSwitch") == .switch)
        #expect(role("Button", description: " Toggle ") == .switch)
        #expect(role("CheckBox", description: "switch button") == .switch)
        #expect(role("CheckBox", description: "checkbox") == .checkbox)
    }

    @Test("slider-like controls are sliders whatever their type")
    func sliderDetection() {
        #expect(role("Other", role: "AXSlider") == .slider)
        #expect(role("Other", subrole: "AXSlider") == .slider)
        #expect(role("Group", description: "Slider") == .slider)
    }

    @Test("a missing type falls back to the AX role")
    func missingTypeUsesRole() {
        #expect(role(nil, role: "AXButton") == .button)
        #expect(role(nil) == .other)
    }

    @Test("checked state comes from a switch or checkbox value of 1 or 0 only")
    func checkedState() throws {
        let nodes = try roots("""
        [{"type": "Switch", "AXValue": "1"}, {"type": "CheckBox", "AXValue": "0"},
         {"type": "Switch", "AXValue": "maybe"}, {"type": "StaticText", "AXValue": "1"}]
        """)

        #expect(nodes.map(\.state.checked) == [true, false, nil, nil])
        #expect(nodes.allSatisfy { $0.state.selected == nil && $0.state.focused == nil })
    }

    @Test("every legacy actionable type maps to an actionable role", arguments: IOSAccessibilityMappingTests.legacyActionableTypes)
    func legacyActionableTypesStayActionable(type: String) {
        #expect(role(type).isActionable)
    }

    @Test("text areas are actionable, and no other role beyond the legacy set is")
    func actionableRolesMatchLegacySetPlusTextArea() {
        let expected = Set(Self.legacyActionableTypes.map { role($0) }).union([.textArea])

        #expect(UIRole.textArea.isActionable)
        #expect(role("TextEditor").isActionable)
        #expect(Set(UIRole.allCases.filter(\.isActionable)) == expected)
    }
}

@Suite("iOS React Native Role Mapping Tests")
struct IOSReactNativeRoleMappingTests {
    private func node(_ type: String, value: String?, traits: [String] = []) throws -> UINode {
        var element: [String: Any] = ["type": type, "traits": traits]
        element["AXValue"] = value
        return IOSAccessibilityMapping.node(from: element)
    }

    @Test("an Other with role words takes the role, a native control keeps its own value")
    func otherTakesRole() throws {
        let radio = try node("Other", value: "radio button, checked")
        #expect(radio.role == .radioButton)
        #expect(radio.state.checked == true)
        #expect(radio.value == "1")
        #expect(radio.native.typeName == "Other")

        let field = try node("TextField", value: "checkbox, unchecked")
        #expect(field.role == .textField)
        #expect(field.value == "checkbox, unchecked")
        #expect(field.state.checked == nil)

        let text = try node("StaticText", value: "checkbox, unchecked")
        #expect(text.role == .text)
        #expect(text.value == "checkbox, unchecked")
    }

    @Test("a head with no Offsider role leaves the node as other with its words")
    func untouchedHead() throws {
        let timer = try node("Other", value: "timer, 00:42")
        #expect(timer.role == .other)
        #expect(timer.value == "timer, 00:42")
    }

    @Test("a mixed checkbox reads 2 and is neither checked nor unchecked")
    func mixedCheckbox() throws {
        let box = try node("Other", value: "checkbox, mixed")
        #expect(box.role == .checkbox)
        #expect(box.value == "2")
        #expect(box.state.checked == nil)
    }

    @Test("a bare radio button is checked when it has the Selected trait, and unknown when it has not")
    func bareRadioTakesTrait() throws {
        let on = try node("Other", value: "radio button", traits: ["Selected"])
        #expect(on.role == .radioButton)
        #expect(on.state.checked == true)
        #expect(on.state.selected == true)
        #expect(on.value == "1")

        let off = try node("Other", value: "radio button")
        #expect(off.state.checked == nil)
        #expect(off.state.selected == nil)
        #expect(off.value == nil)
    }

    @Test("a state word outranks the Selected trait")
    func wordOutranksTrait() throws {
        let radio = try node("Other", value: "radio button, unchecked", traits: ["Selected"])
        #expect(radio.state.checked == false)
        #expect(radio.state.selected == true)
    }

    @Test("the Selected trait sets selected on any iOS node, and its absence leaves selected nil")
    func selectedTrait() throws {
        #expect(try node("Button", value: nil, traits: ["Button", "Selected"]).state.selected == true)
        #expect(try node("Button", value: nil, traits: ["Button"]).state.selected == nil)
    }

    @Test("a native switch still reads its own 1 or 0")
    func nativeSwitch() throws {
        let toggle = try node("Switch", value: "1")
        #expect(toggle.role == .switch)
        #expect(toggle.state.checked == true)
        #expect(toggle.value == "1")
    }
}
