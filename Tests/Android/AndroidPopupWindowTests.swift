import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// A dropdown that does not take focus: an application window over the app's own, which a dump lists as neither active nor focused.
@Suite("Android popup windows")
@MainActor
struct AndroidPopupWindowTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let package = HelperTreeMappingTests.package

    static let form = [
        #"{"i":1,"class":"android.widget.Button",\#(package),"resourceId":"country-field","text":"Country","bounds":[42,400,1038,516],"clickable":true,"focusable":true,"drawingOrder":1}"#,
        #"{"i":2,"class":"android.widget.Button",\#(package),"resourceId":"submit","text":"Submit","bounds":[42,640,1038,740],"clickable":true,"focusable":true,"drawingOrder":2}"#,
    ].joined(separator: ",")

    /// A dropdown of two rows under the country field; `short` holds only the first, ending above the submit button.
    static func popup(layer: Int = 1, package: String = AndroidPopupWindowTests.package, short: Bool = false, rootBounds: String? = nil) -> String {
        let bottom = short ? 632 : 748
        let australia = #"{"i":11,"class":"android.widget.TextView",\#(package),"resourceId":"country-au","text":"Australia","bounds":[42,516,1038,632],"clickable":true,"focusable":true,"drawingOrder":1}"#
        let newZealand = #"{"i":12,"class":"android.widget.TextView",\#(package),"resourceId":"country-nz","text":"New Zealand","bounds":[42,632,1038,748],"clickable":true,"focusable":true,"drawingOrder":2}"#
        let rows = short ? australia : australia + "," + newZealand
        let root = rootBounds ?? "42,516,1038,\(bottom)"
        return #"{"id":2320,"type":"application","layer":\#(layer),"title":"PopupWindow","bounds":[42,516,1038,\#(bottom)],"active":false,"focused":false,"root":{"i":10,"class":"android.widget.ListView",\#(package),"bounds":[\#(root)],"children":[\#(rows)]}}"#
    }

    static func roots(_ windows: [String]) throws -> [UINode] {
        HelperTreeMapping.roots(from: try HelperTreeMappingTests.dump(windows.joined(separator: ",")), scale: HelperTreeMappingTests.scale, pid: 1).roots
    }

    @Test("the app's own window above its main one gets a tree after the app's, before the keyboard, so its rows can be found")
    func popupIsRead() throws {
        let keyboard = #"{"id":2337,"type":"inputMethod","layer":3,"title":"Gboard","bounds":[0,1187,1080,2424],"active":false,"focused":false,"root":{"i":20,"class":"android.widget.FrameLayout","package":"com.google.android.inputmethod.latin","bounds":[0,1187,1080,2424]}}"#
        let roots = try Self.roots([HelperTreeMappingTests.statusBar, keyboard, Self.popup(), HelperTreeMappingTests.appWindow(Self.form)])

        #expect(roots.map(\.role) == [.application, .window, .keyboard])
        #expect(roots[1].label == "PopupWindow")
        let found = AccessibilityTargetResolver.candidates(roots: roots, query: .label("New Zealand"), elementType: nil)
        #expect(found.onScreen.map(\.id) == ["country-nz"])
    }

    @Test("a window at or below the app's layer, or another app's, stays out of the tree", arguments: [
        (0, AndroidPopupWindowTests.package), (1, #""package":"com.example.other""#),
    ])
    func othersLeftOut(layer: Int, package: String) throws {
        let roots = try Self.roots([Self.popup(layer: layer, package: package), HelperTreeMappingTests.appWindow(Self.form)])

        #expect(roots.map(\.role) == [.application])
    }

    @Test("a selector tap on a control the popup is drawn over refuses target_covered and sends nothing")
    func controlBeneathRefuses() async throws {
        let roots = try Self.roots([Self.popup(), HelperTreeMappingTests.appWindow(Self.form)])
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: Self.device.rawValue, roots: roots)])

        let error = await #expect(throws: CLIError.self) {
            try await Tap.parse(["--id", "submit", "--no-settle", "--device", Self.device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
        }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.id == "country-nz")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a popup's root view, padded past the window that takes its touches, is cut to that window, so it is no cover beside it")
    func rootPaddingIsNoCover() async throws {
        let roots = try Self.roots([Self.popup(rootBounds: "0,300,1080,900"), HelperTreeMappingTests.appWindow(Self.form)])
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: Self.device.rawValue, roots: roots)])

        let frame = try #require(roots[1].frame)
        #expect([frame.x, frame.y, frame.width, frame.height].map { ($0 * 100).rounded() / 100 } == [16, 196.57, 379.43, 88.38])
        try await Tap.parse(["--id", "country-field", "--fail-if-covered", "--no-settle", "--device", Self.device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
        #expect(backend.session.calls.count == 1)
    }

    @Test("a popup beside the target, clear of its point, does not refuse it")
    func popupBesideTaps() async throws {
        let roots = try Self.roots([Self.popup(short: true), HelperTreeMappingTests.appWindow(Self.form)])
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: Self.device.rawValue, roots: roots)])

        try await Tap.parse(["--id", "submit", "--no-settle", "--device", Self.device.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())

        #expect(backend.session.calls.count == 1)
    }
}
