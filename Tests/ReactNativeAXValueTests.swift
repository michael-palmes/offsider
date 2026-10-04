import OffsiderCore
import Testing

@Suite("React Native AXValue Tests")
struct ReactNativeAXValueTests {
    static let heads: [(String, UIRole?)] = [
        ("checkbox", .checkbox), ("radio button", .radioButton), ("switch", .switch), ("tab", .tab),
        ("tab list", .tabBar), ("menu item", .menuItem), ("combo box", .picker), ("progress bar", .progress),
        ("radio group", .group), ("alert", nil), ("menu", nil), ("menu bar", nil), ("scroll bar", nil),
        ("spin button", nil), ("timer", nil), ("tool bar", nil),
    ]

    @Test("each React Native head maps to its Offsider role or is left alone", arguments: heads)
    func headsMap(head: String, role: UIRole?) {
        #expect(ReactNativeAXValue.parse(head)?.role == role)
    }

    @Test("state words set checked and stay out of the value")
    func stateWords() throws {
        let checked = try #require(ReactNativeAXValue.parse("checkbox, checked"))
        #expect(checked.checked == true)
        #expect(checked.value == "1")
        let unchecked = try #require(ReactNativeAXValue.parse("checkbox, unchecked"))
        #expect(unchecked.checked == false)
        #expect(unchecked.value == "0")
        let mixed = try #require(ReactNativeAXValue.parse("checkbox, mixed"))
        #expect(mixed.checked == nil)
        #expect(mixed.mixed)
        #expect(mixed.value == "2")
    }

    @Test("a toggle with an app value keeps the text and the state")
    func toggleWithAppValue() throws {
        let parsed = try #require(ReactNativeAXValue.parse("switch, checked, Wi-Fi"))
        #expect(parsed.checked == true)
        #expect(parsed.value == "Wi-Fi")
    }

    @Test("a bare radio button has no state of its own")
    func bareRadio() throws {
        let parsed = try #require(ReactNativeAXValue.parse("radio button"))
        #expect(parsed.role == .radioButton)
        #expect(parsed.checked == nil)
        #expect(parsed.value == nil)
    }

    @Test("loose words and the app value stay readable")
    func looseWords() {
        #expect(ReactNativeAXValue.parse("menu item, collapsed, busy")?.value == "collapsed, busy")
        #expect(ReactNativeAXValue.parse("progress bar, 3 of 5, almost done")?.value == "3 of 5, almost done")
        #expect(ReactNativeAXValue.parse("combo box, expanded")?.value == "expanded")
        #expect(ReactNativeAXValue.parse("radio group, Size")?.value == nil)
    }

    @Test("a value that only starts like a head is not parsed", arguments: ["checkboxes are fun", "checkbox,unchecked", "Checkbox list", ""])
    func notAHead(value: String) {
        #expect(ReactNativeAXValue.parse(value) == nil)
    }

    @Test("heads and state words match in any case, and the value keeps its case")
    func caseInsensitive() throws {
        let parsed = try #require(ReactNativeAXValue.parse("Radio Button, Checked"))
        #expect(parsed.role == .radioButton)
        #expect(parsed.checked == true)
        #expect(ReactNativeAXValue.parse("Progress Bar, 40%")?.value == "40%")
    }
}
