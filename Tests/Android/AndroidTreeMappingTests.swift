import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Fixtures trimmed from React Native playground dumps on Offsider_E2E_Pixel_9 (1080 x 2424 px, 420 dpi, scale 2.625).
@Suite("Android tree mapping")
struct AndroidTreeMappingTests {
    private static let scale = 2.625
    private static let common = #"package="com.mpalmes.offsider.playground.rn" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" selected="false" hint="""#

    private static func tree(_ body: String, rotation: Int = 0) throws -> [UINode] {
        let xml = """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="\(rotation)"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" checkable="false" checked="false" clickable="false" password="false" bounds="[0,0][1080,2424]" \(common)>\(body)</node></hierarchy>
        """
        return AndroidTreeMapping.roots(from: try UIAutomatorDump.parse(xml), scale: scale)
    }

    private static func node(_ id: String, in roots: [UINode]) throws -> UINode {
        try #require(roots.flatMap { $0.flattened() }.first { $0.id == id })
    }

    @Test("the root is the application, with the whole window as its frame")
    func rootIsApplication() throws {
        let roots = try Self.tree("")
        #expect(roots.count == 1)
        #expect(roots[0].role == .application)
        #expect(roots[0].label == nil)
        #expect(roots[0].frame == UIFrame(x: 0, y: 0, width: 411.43, height: 923.43))
    }

    @Test("tap-test: the back button is a 44 dp button labelled from content-desc, with its testID as id")
    func backButton() throws {
        let roots = try Self.tree(#"<node index="0" text="" resource-id="BackButton" class="android.widget.Button" content-desc="Offsider Playground" checkable="false" checked="false" clickable="true" password="false" bounds="[21,142][137,258]" \#(Self.common) />"#)
        let button = try Self.node("BackButton", in: roots)

        #expect(button.role == .button)
        #expect(button.label == "Offsider Playground")
        #expect(button.frame == UIFrame(x: 8, y: 54.1, width: 44.19, height: 44.19))
        #expect(button.native == .android(AndroidNativeAttributes(
            className: "android.widget.Button", resourceId: "BackButton", package: "com.mpalmes.offsider.playground.rn",
            pixelFrame: UIFrame(x: 21, y: 142, width: 116, height: 116), contentDescription: "Offsider Playground"
        )))
    }

    @Test("tap-test: a readout TextView takes its label from content-desc")
    func readout() throws {
        let roots = try Self.tree(#"<node index="0" text="" resource-id="tap-count" class="android.widget.TextView" content-desc="Tap Count: 0" checkable="false" checked="false" clickable="false" password="false" bounds="[413,418][668,479]" \#(Self.common) />"#)
        let readout = try Self.node("tap-count", in: roots)
        #expect(readout.role == .text)
        #expect(readout.label == "Tap Count: 0")
        #expect(readout.value == nil)
    }

    @Test("switch-test: switches report value 0 and checked false, as iOS does")
    func switches() throws {
        let roots = try Self.tree("""
        <node index="2" text="" resource-id="swiftui-weather-alerts-switch" class="android.widget.Switch" content-desc="SwiftUI Weather Alerts" checkable="true" checked="false" clickable="true" password="false" bounds="[916,435][1038,506]" \(Self.common) /><node index="3" text="" resource-id="uikit-weather-alerts-switch" class="android.widget.Switch" content-desc="UIKit Weather Alerts" checkable="true" checked="true" clickable="true" password="false" bounds="[902,651][1038,735]" \(Self.common) />
        """)
        let first = try Self.node("swiftui-weather-alerts-switch", in: roots)
        let second = try Self.node("uikit-weather-alerts-switch", in: roots)

        #expect(first.role == .switch)
        #expect(first.value == "0")
        #expect(first.state == UIState(checked: false, selected: false, focused: false))
        #expect(second.value == "1")
        #expect(second.state.checked == true)
    }

    @Test("slider-value-test: a SeekBar is a slider with no value until the helper reports one")
    func seekBar() throws {
        let roots = try Self.tree(#"<node index="0" text="" resource-id="slider-value-slider" class="android.widget.SeekBar" content-desc="Slider Value Slider" checkable="false" checked="false" clickable="false" password="false" bounds="[42,1010][1038,1057]" \#(Self.common) />"#)
        let slider = try Self.node("slider-value-slider", in: roots)
        #expect(slider.role == .slider)
        #expect(slider.value == nil)
        #expect(slider.state.checked == nil)
    }

    @Test("batch-login: a password EditText is a secure text field whose value is the masked text")
    func passwordField() throws {
        let roots = try Self.tree(#"<node index="4" text="•••••••••••" resource-id="batch-login-password-field" class="android.widget.EditText" content-desc="" checkable="false" checked="false" clickable="true" password="true" bounds="[42,581][1038,697]" \#(Self.common) />"#)
        let field = try Self.node("batch-login-password-field", in: roots)
        #expect(field.role == .secureTextField)
        #expect(field.label == nil)
        #expect(field.value == "•••••••••••")
    }

    @Test("an editable field's text is its value, not its label")
    func editTextValue() throws {
        let roots = try Self.tree(#"<node index="0" text="hello world" resource-id="text-field" class="android.widget.EditText" content-desc="Name" checkable="false" checked="false" clickable="true" password="false" bounds="[42,581][1038,697]" \#(Self.common) />"#)
        let field = try Self.node("text-field", in: roots)
        #expect(field.role == .textField)
        #expect(field.label == "Name")
        #expect(field.value == "hello world")
    }

    @Test("a clickable ViewGroup without a label is a button named by its text children")
    func pressableFoldsLabel() throws {
        let roots = try Self.tree("""
        <node index="0" text="" resource-id="row" class="android.view.ViewGroup" content-desc="" checkable="false" checked="false" clickable="true" password="false" bounds="[0,300][1080,420]" \(Self.common)><node index="0" text="Weather" resource-id="" class="android.widget.TextView" content-desc="" checkable="false" checked="false" clickable="false" password="false" bounds="[40,310][400,360]" \(Self.common) /><node index="1" text="Alerts on" resource-id="" class="android.widget.TextView" content-desc="" checkable="false" checked="false" clickable="false" password="false" bounds="[40,360][400,410]" \(Self.common) /><node index="2" text="Nested" resource-id="" class="android.widget.Button" content-desc="" checkable="false" checked="false" clickable="true" password="false" bounds="[800,310][1000,410]" \(Self.common) /></node>
        """)
        let row = try Self.node("row", in: roots)
        #expect(row.role == .button)
        #expect(row.label == "Weather Alerts on")
    }

    @Test("non-clickable containers are groups, or scroll views when scrollable")
    func containers() throws {
        let roots = try Self.tree("""
        <node index="0" text="" resource-id="area" class="android.view.ViewGroup" content-desc="" checkable="false" checked="false" clickable="false" password="false" bounds="[0,259][1080,2424]" \(Self.common) /><node index="1" text="" resource-id="scroller" class="com.example.CustomView" content-desc="" checkable="false" checked="false" clickable="false" password="false" bounds="[0,259][1080,2424]" package="x" scrollable="true" />
        """)
        #expect(try Self.node("area", in: roots).role == .group)
        #expect(try Self.node("area", in: roots).label == nil)
        #expect(try Self.node("scroller", in: roots).role == .scrollView)
    }

    @Test("class suffixes pick roles for androidx and Material subclasses", arguments: [
        ("androidx.appcompat.widget.AppCompatEditText", UIRole.textField),
        ("android.widget.AutoCompleteTextView", .textField),
        ("androidx.appcompat.widget.SwitchCompat", .switch),
        ("com.google.android.material.materialswitch.MaterialSwitch", .switch),
        ("android.widget.ToggleButton", .switch),
        ("com.google.android.material.checkbox.MaterialCheckBox", .checkbox),
        ("android.widget.RadioButton", .radioButton),
        ("com.google.android.material.button.MaterialButton", .button),
        ("android.widget.ImageButton", .button),
        ("com.google.android.material.slider.Slider", .slider),
        ("android.widget.ProgressBar", .progress),
        ("android.widget.ImageView", .image),
        ("android.widget.CheckedTextView", .text),
        ("androidx.core.widget.NestedScrollView", .scrollView),
        ("androidx.recyclerview.widget.RecyclerView", .list),
        ("android.widget.Spinner", .picker),
        ("android.widget.TabWidget", .tabBar),
        ("android.webkit.WebView", .other),
    ])
    func classRoles(className: String, role: UIRole) {
        let raw = RawAndroidNode(attributes: ["class": className, "clickable": "true"])
        #expect(AndroidTreeMapping.role(for: raw) == role)
    }

    @Test("inverted bounds from clipped rows become a zero-height frame")
    func invertedBounds() {
        #expect(AndroidTreeMapping.pixelFrame("[42,2424][1038,2380]") == UIFrame(x: 42, y: 2424, width: 996, height: 0))
        #expect(AndroidTreeMapping.pixelFrame("garbage") == nil)
    }
}
