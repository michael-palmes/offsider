import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Helper and uiautomator dumps of the same playground screens on Offsider_E2E_Pixel_9 (scale 2.625), trimmed.
@Suite("Android helper tree mapping")
struct HelperTreeMappingTests {
    static let scale = 2.625
    static let display = #""display":{"displayId":0,"source":"DisplayManagerGlobal","logicalWidthPx":1080,"logicalHeightPx":2424,"rotation":0,"physicalWidthPx":1080,"physicalHeightPx":2424,"densityDpi":420,"densityStableDpi":420}"#
    static let statusBar = #"{"id":2313,"type":"system","layer":1,"displayId":0,"bounds":[0,0,1080,142],"active":false,"focused":false}"#
    static let package = #""package":"com.mpalmes.offsider.playground.rn""#

    static func dump(_ windows: String, generation: Int = 1) throws -> HelperDump {
        try JSONDecoder().decode(HelperDump.self, from: Data(#"{"id":2,"ok":true,"generation":\#(generation),"idle":true,\#(display),"windows":[\#(windows)],"truncated":false,"source":"getWindows","stats":{"windows":2},"timings":{"totalMs":22},"eventSeq":4}"#.utf8))
    }

    static func appWindow(_ children: String, title: String = "OffsiderPlaygroundRN", active: Bool = true, layer: Int = 0, firstIndex: Int = 0) -> String {
        #"{"id":2314,"type":"application","layer":\#(layer),"title":"\#(title)","displayId":0,"bounds":[0,0,1080,2424],"active":\#(active),"focused":\#(active),"root":{"i":\#(firstIndex),"class":"android.widget.FrameLayout",\#(package),"bounds":[0,0,1080,2424],"children":[\#(children)]}}"#
    }

    static let switchChildren = [
        #"{"i":1,"class":"android.widget.Button",\#(package),"resourceId":"BackButton","contentDescription":"Offsider Playground","bounds":[21,142,137,258],"clickable":true,"focusable":true}"#,
        #"{"i":2,"class":"android.view.View",\#(package),"resourceId":"switch-test-screen","contentDescription":"Switch Test","bounds":[158,169,923,230],"focusable":true}"#,
        #"{"i":3,"class":"android.widget.TextView",\#(package),"resourceId":"switch-test-title","contentDescription":"Switch Playground","bounds":[42,301,1038,372],"focusable":true}"#,
        #"{"i":4,"class":"android.widget.Switch",\#(package),"resourceId":"swiftui-weather-alerts-switch","contentDescription":"SwiftUI Weather Alerts","stateDescription":"OFF","bounds":[916,435,1038,506],"checkable":true,"checkedState":"unchecked","clickable":true,"focusable":true}"#,
        #"{"i":5,"class":"android.widget.TextView",\#(package),"resourceId":"swiftui-weather-alerts-state","contentDescription":"SwiftUI Weather Alerts: Off","bounds":[42,527,1038,588],"focusable":true}"#,
        #"{"i":6,"class":"android.widget.Switch",\#(package),"resourceId":"uikit-weather-alerts-switch","contentDescription":"UIKit Weather Alerts","bounds":[902,651,1038,735],"checkable":true,"checkedState":"unchecked","clickable":true,"focusable":true}"#,
        #"{"i":7,"class":"android.widget.TextView",\#(package),"resourceId":"uikit-weather-alerts-state","contentDescription":"UIKit Weather Alerts: Off","bounds":[42,756,1038,817],"focusable":true}"#,
    ].joined(separator: ",")

    static let switchXML = """
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.mpalmes.offsider.playground.rn" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,0][1080,2424]" drawing-order="0" hint=""><node index="0" text="" resource-id="BackButton" class="android.widget.Button" package="com.mpalmes.offsider.playground.rn" content-desc="Offsider Playground" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[21,142][137,258]" drawing-order="1" hint="" /><node index="1" text="" resource-id="switch-test-screen" class="android.view.View" package="com.mpalmes.offsider.playground.rn" content-desc="Switch Test" checkable="false" checked="false" clickable="false" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[158,169][923,230]" drawing-order="2" hint="" /><node index="2" text="" resource-id="switch-test-title" class="android.widget.TextView" package="com.mpalmes.offsider.playground.rn" content-desc="Switch Playground" checkable="false" checked="false" clickable="false" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[42,301][1038,372]" drawing-order="3" hint="" /><node index="3" text="" resource-id="swiftui-weather-alerts-switch" class="android.widget.Switch" package="com.mpalmes.offsider.playground.rn" content-desc="SwiftUI Weather Alerts" checkable="true" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[916,435][1038,506]" drawing-order="4" hint="" /><node index="4" text="" resource-id="swiftui-weather-alerts-state" class="android.widget.TextView" package="com.mpalmes.offsider.playground.rn" content-desc="SwiftUI Weather Alerts: Off" checkable="false" checked="false" clickable="false" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[42,527][1038,588]" drawing-order="5" hint="" /><node index="5" text="" resource-id="uikit-weather-alerts-switch" class="android.widget.Switch" package="com.mpalmes.offsider.playground.rn" content-desc="UIKit Weather Alerts" checkable="true" checked="false" clickable="true" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[902,651][1038,735]" drawing-order="6" hint="" /><node index="6" text="" resource-id="uikit-weather-alerts-state" class="android.widget.TextView" package="com.mpalmes.offsider.playground.rn" content-desc="UIKit Weather Alerts: Off" checkable="false" checked="false" clickable="false" enabled="true" focusable="true" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[42,756][1038,817]" drawing-order="7" hint="" /></node></hierarchy>
    """

    /// text-input with Gboard up: the keyboard window comes first in z-order and its nodes take the first indexes.
    static let textInputWindows = [
        statusBar,
        #"{"id":2337,"type":"inputMethod","layer":1,"title":"Gboard","displayId":0,"bounds":[0,1187,1080,2424],"active":false,"focused":false,"root":{"i":0,"class":"android.widget.FrameLayout","package":"com.google.android.inputmethod.latin","bounds":[0,142,1080,2424],"children":[{"i":1,"class":"android.widget.FrameLayout","package":"com.google.android.inputmethod.latin","resourceId":"com.google.android.inputmethod.latin:id/0_resource_name_obfuscated","contentDescription":"More keyboard options","bounds":[32,1197,158,1323],"clickable":true,"focusable":true}]}}"#,
        appWindow([
            #"{"i":3,"class":"android.widget.Button",\#(package),"resourceId":"BackButton","contentDescription":"Offsider Playground","bounds":[21,142,137,258],"clickable":true,"focusable":true}"#,
            #"{"i":4,"class":"android.widget.EditText",\#(package),"resourceId":"text-input-field","bounds":[42,510,1038,626],"clickable":true,"longClickable":true,"focusable":true,"focused":true,"editable":true}"#,
        ].joined(separator: ","), firstIndex: 2),
    ].joined(separator: ",")

    static func flat(_ roots: [UINode]) -> [UINode] {
        roots.flatMap { $0.flattened() }
    }

    @Test("switch-test gives the same ids, labels, roles, frames and values as uiautomator")
    func sameAsUIAutomator() throws {
        let helper = HelperTreeMapping.roots(from: try Self.dump(Self.appWindow(Self.switchChildren) + "," + Self.statusBar), scale: Self.scale, pid: 1).roots
        let xml = AndroidTreeMapping.roots(from: try UIAutomatorDump.parse(Self.switchXML), scale: Self.scale)

        #expect(helper.count == 1)
        #expect(Self.flat(helper).map(\.id) == Self.flat(xml).map(\.id))
        #expect(Self.flat(helper).dropFirst().map(\.label) == Self.flat(xml).dropFirst().map(\.label))
        #expect(Self.flat(helper).map(\.role) == Self.flat(xml).map(\.role))
        #expect(Self.flat(helper).map(\.frame) == Self.flat(xml).map(\.frame))
        #expect(Self.flat(helper).map(\.value) == Self.flat(xml).map(\.value))
        #expect(Self.flat(helper).map(\.state) == Self.flat(xml).map(\.state))
    }

    @Test("the active window is the application root, labelled with its title; system windows are left out")
    func applicationRoot() throws {
        let roots = HelperTreeMapping.roots(from: try Self.dump(Self.statusBar + "," + Self.appWindow(Self.switchChildren)), scale: Self.scale, pid: 1).roots
        #expect(roots.map(\.role) == [.application])
        #expect(roots.first?.label == "OffsiderPlaygroundRN")
        #expect(roots.first?.frame == UIFrame(x: 0, y: 0, width: 411.43, height: 923.43))
    }

    @Test("with the keyboard up, the application root comes first and the keyboard follows, labelled with its title")
    func keyboardRoot() throws {
        let roots = HelperTreeMapping.roots(from: try Self.dump(Self.textInputWindows), scale: Self.scale, pid: 1).roots
        #expect(roots.map(\.role) == [.application, .keyboard])
        #expect(roots.map(\.label) == ["OffsiderPlaygroundRN", "Gboard"])
        #expect(Self.flat([roots[1]]).last?.label == "More keyboard options")
        #expect(Self.flat([roots[0]]).first { $0.id == "text-input-field" }?.role == .textField)
    }

    @Test("with no active window, the topmost application window is the root")
    func topmostApplication() throws {
        let lower = Self.appWindow("", title: "Lower", active: false, layer: 0)
        let upper = Self.appWindow("", title: "Upper", active: false, layer: 2)
        let roots = HelperTreeMapping.roots(from: try Self.dump([lower, upper, Self.statusBar].joined(separator: ",")), scale: Self.scale, pid: 1).roots
        #expect(roots.map(\.label) == ["Upper"])
    }

    @Test("a dump whose app window has no tree gives no roots")
    func noTree() throws {
        let window = #"{"id":2314,"type":"application","layer":0,"title":"X","bounds":[0,0,1080,2424],"active":true,"focused":true,"root":null}"#
        let dump = try Self.dump(Self.statusBar + "," + window)
        #expect(HelperTreeMapping.appWindow(in: dump) == nil)
        #expect(HelperTreeMapping.roots(from: dump, scale: Self.scale, pid: 1).roots.isEmpty)
    }

    @Test("the index lines up with a pre-order walk of the roots, keeping each node's dump reference")
    func index() throws {
        let mapped = HelperTreeMapping.roots(from: try Self.dump(Self.textInputWindows, generation: 7), scale: Self.scale, pid: 4242)
        #expect(mapped.index.pid == 4242)
        #expect(mapped.index.generation == 7)
        #expect(mapped.index.entries.map(\.node) == Self.flat(mapped.roots))
        #expect(mapped.index.entries.map(\.ref.index) == [2, 3, 4, 0, 1])
        let field = try #require(mapped.index.entries.first { $0.node.id == "text-input-field" })
        #expect(field.ref == HelperNodeRef(generation: 7, index: 4, className: "android.widget.EditText", resourceId: "text-input-field"))
    }

    @Test("slider-value-test: the SeekBar's range is a percentage value, and TalkBack's text is kept in native")
    func slider() throws {
        let seekBar = #"{"i":1,"class":"android.widget.SeekBar",\#(Self.package),"resourceId":"slider-value-slider","contentDescription":"Slider Value Slider","stateDescription":"25%","bounds":[42,1010,1038,1057],"focusable":true,"rangeInfo":{"type":"int","min":0,"max":10000,"current":2500}}"#
        let mapped = HelperTreeMapping.roots(from: try Self.dump(Self.appWindow(seekBar)), scale: Self.scale, pid: 1)
        let slider = try #require(Self.flat(mapped.roots).first { $0.id == "slider-value-slider" })

        #expect(slider.role == .slider)
        #expect(slider.value == "25%")
        #expect(slider.label == "Slider Value Slider")
        guard case .android(let native) = slider.native else {
            Issue.record("expected Android attributes")
            return
        }
        #expect(native.stateDescription == "25%")
        #expect(mapped.index.entries.last?.range == HelperRange(type: "int", min: 0, max: 10000, current: 2500))
    }

    @Test("booleans become uiautomator's true and false, with enabled and visible-to-user true when absent")
    func rawBooleans() throws {
        let node = try JSONDecoder().decode(HelperNode.self, from: Data(#"{"i":0,"class":"android.widget.Button","bounds":[1,2,3,4],"clickable":true}"#.utf8))
        let raw = HelperTreeMapping.rawNode(node)
        #expect(raw["clickable"] == "true")
        #expect(raw["checkable"] == "false")
        #expect(raw["enabled"] == "true")
        #expect(raw["visible-to-user"] == "true")
        #expect(raw["bounds"] == "[1,2][3,4]")
        #expect(raw.attributes["range-type"] == nil)
    }

    @Test("a React Native mixed checkbox reads 2, is neither checked nor unchecked, and loses the suffix from its label")
    func reactNativeMixedCheckbox() throws {
        let boxes = [
            #"{"i":1,"class":"android.widget.CheckBox",\#(Self.package),"resourceId":"mixed","contentDescription":"Select All, mixed","bounds":[42,741,296,857],"clickable":true,"focusable":true}"#,
            #"{"i":2,"class":"android.widget.CheckBox",\#(Self.package),"resourceId":"plain","contentDescription":"Accept Terms","bounds":[42,468,376,584],"checkable":true,"checkedState":"unchecked","clickable":true,"focusable":true}"#,
            #"{"i":3,"class":"android.widget.TextView",\#(Self.package),"resourceId":"text","contentDescription":"Colours, mixed","bounds":[42,900,376,950],"focusable":true}"#,
        ].joined(separator: ",")
        let nodes = Self.flat(HelperTreeMapping.roots(from: try Self.dump(Self.appWindow(boxes)), scale: Self.scale, pid: 1).roots)
        let mixed = try #require(nodes.first { $0.id == "mixed" })
        #expect(mixed.role == .checkbox)
        #expect(mixed.label == "Select All")
        #expect(mixed.value == "2")
        #expect(mixed.state.checked == nil)

        let plain = try #require(nodes.first { $0.id == "plain" })
        #expect(plain.label == "Accept Terms")
        #expect(plain.value == "0")
        #expect(plain.state.checked == false)
        #expect(nodes.first { $0.id == "text" }?.label == "Colours, mixed")
    }
}
