import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Finding one app's home screen widget: the launcher's dump and `dumpsys appwidget` here are invented, in their real formats.
@Suite("Home screen widgets")
@MainActor
struct AndroidWidgetTests {
    static let phone = AndroidBackendHelperTests.phone
    static let app = "com.mpalmes.offsider.playground.rn"
    nonisolated static let other = "com.example.notes"
    nonisolated static let home = "com.example.launcher"
    static let serial = phone.rawValue

    static let placedDump = """
        host=HostId{user:0, app:10174, hostId:1024, pkg:\(home)}
        provider=ProviderId{user:0, app:10213, cmp:ComponentInfo{\(app)/\(app).StatusWidget}}
        host=HostId{user:0, app:10174, hostId:1024, pkg:\(home)}
        provider=ProviderId{user:0, app:10300, cmp:ComponentInfo{\(other)/\(other).NoteWidget}}

    """

    static let placed = [AndroidWidgets.Placed(host: home, provider: app), AndroidWidgets.Placed(host: home, provider: other)]

    /// A widget's host view with its views, in pixels; `package` names who drew them.
    static func host(_ index: Int, package: String?, bounds: String, label: String = "Status") -> String {
        let child = package.map { #"{"i":\#(index + 1),"class":"android.widget.TextView","package":"\#($0)","text":"Value","bounds":[\#(bounds)]}"# } ?? ""
        return #"{"i":\#(index),"class":"com.example.launcher.widget.LauncherAppWidgetHostView","package":"\#(home)","contentDescription":"\#(label)","bounds":[\#(bounds)],"children":[\#(child)]}"#
    }

    static func launcher(_ hosts: [String], extraWindows: String = "", active: Bool = true) throws -> UITree {
        let window = #"{"id":2314,"type":"application","layer":2,"title":"Home","displayId":0,"bounds":[0,0,1080,2424],"active":\#(active),"focused":\#(active),"root":{"i":0,"class":"android.widget.FrameLayout","package":"\#(home)","bounds":[0,0,1080,2424],"children":[\#(hosts.joined(separator: ","))]}}"#
        return try AndroidPhoneScopeTests.tree(extraWindows.isEmpty ? window : window + "," + extraWindows)
    }

    static func shown(_ tree: UITree, of package: String = app, placed: [AndroidWidgets.Placed] = placed) throws -> [HomeWidget] {
        try AndroidWidgets.shown(of: package, in: tree, home: home, placed: placed, on: serial)
    }

    @Test("placed widgets pair each host with its provider, and nothing else in the dump is read")
    func parsesPlaced() {
        #expect(AndroidWidgets.placed(in: Self.placedDump) == Self.placed)
        #expect(AndroidWidgets.placed(in: "  host=HostId{user:0, app:1, hostId:1, pkg:\(Self.home)}\n  provider=null\n").isEmpty)
        #expect(AndroidWidgets.placed(in: "").isEmpty)
    }

    @Test("only the app's own widget comes back, in dp from the device's bounds")
    func ownWidgetOnly() throws {
        let tree = try Self.launcher([
            Self.host(10, package: Self.other, bounds: "42,300,500,800", label: "Secret list"),
            Self.host(20, package: Self.app, bounds: "580,300,1038,800"),
        ])
        let widgets = try Self.shown(tree)
        #expect(widgets.count == 1)
        let scale = HelperTreeMappingTests.scale
        #expect(abs(widgets[0].frame.x - 580 / scale) < 0.01)
        #expect(abs(widgets[0].frame.y - 300 / scale) < 0.01)
        #expect(abs(widgets[0].frame.width - 458 / scale) < 0.01)
        #expect(abs(widgets[0].frame.height - 500 / scale) < 0.01)
        #expect(widgets[0].label == "Status")
    }

    @Test("a widget's label is redacted before anything can print it")
    func labelRedacted() throws {
        let tree = try Self.launcher([Self.host(10, package: Self.app, bounds: "42,300,500,800", label: "Sent to me@example.com")])
        #expect(try Self.shown(tree)[0].label?.contains("me@example.com") == false)
    }

    @Test("several come back top to bottom, then left to right")
    func readingOrder() throws {
        let tree = try Self.launcher([
            Self.host(10, package: Self.app, bounds: "580,900,1038,1200", label: "C"),
            Self.host(20, package: Self.app, bounds: "42,300,500,800", label: "A"),
            Self.host(30, package: Self.app, bounds: "580,300,1038,800", label: "B"),
        ])
        #expect(try Self.shown(tree).map(\.label) == ["A", "B", "C"])
    }

    @Test("a host with no views, or with views another app drew, is not the app's", arguments: [nil, other, home])
    func unprovenHost(package: String?) throws {
        let error = #expect(throws: AndroidError.self) { try Self.shown(try Self.launcher([Self.host(10, package: package, bounds: "42,300,500,800")])) }
        #expect(error?.reason == .widgetNotShown)
        #expect(error?.message.contains("not on this page") == true)
    }

    @Test("an image-only widget is proved from the read with hidden views; another app's, or a host only that read lists, is not the app's")
    func imageOnly() throws {
        let bounds = "42,300,500,800"
        let bare = try Self.launcher([Self.host(10, package: nil, bounds: bounds)])
        let own = try Self.launcher([Self.host(10, package: Self.app, bounds: bounds)])
        #expect(try AndroidWidgets.shown(of: Self.app, in: bare, everyView: own, home: Self.home, placed: Self.placed, on: Self.serial).count == 1)

        let others = try Self.launcher([Self.host(10, package: Self.other, bounds: bounds)])
        #expect(throws: AndroidError.self) { try AndroidWidgets.shown(of: Self.app, in: bare, everyView: others, home: Self.home, placed: Self.placed, on: Self.serial) }

        let coveredByFolder = try Self.launcher([])
        #expect(throws: AndroidError.self) { try AndroidWidgets.shown(of: Self.app, in: coveredByFolder, everyView: own, home: Self.home, placed: Self.placed, on: Self.serial) }
    }

    @Test("a launcher's plain button is never a widget, whatever its package says")
    func onlyHostViews() throws {
        let button = #"{"i":10,"class":"android.widget.Button","package":"\#(Self.app)","text":"Open","bounds":[42,300,500,800]}"#
        #expect(throws: AndroidError.self) { try Self.shown(try Self.launcher([button])) }
    }

    @Test("with none placed by this launcher, the fix is a person adding one, whatever the tree claims")
    func nonePlaced() throws {
        let tree = try Self.launcher([Self.host(10, package: Self.app, bounds: "42,300,500,800")])
        let elsewhere = [AndroidWidgets.Placed(host: "com.example.other.launcher", provider: Self.app)]
        for placed in [[], [AndroidWidgets.Placed(host: Self.home, provider: Self.other)], elsewhere] {
            let error = #expect(throws: AndroidError.self) { try Self.shown(tree, placed: placed) }
            #expect(error?.message.contains("has no widget") == true)
            #expect(error?.message.contains("Can you add one") == true)
        }
    }

    @Test("another widget overlapping it refuses, so a person's widget never shows in the crop")
    func otherWidgetOverlaps() throws {
        let tree = try Self.launcher([
            Self.host(10, package: Self.other, bounds: "400,300,700,800"),
            Self.host(20, package: Self.app, bounds: "580,300,1038,800"),
        ])
        let error = #expect(throws: AndroidError.self) { try Self.shown(tree) }
        #expect(error?.message.contains("overlaps") == true)
    }

    @Test("a window above that meets the widget refuses; one beside it does not")
    func windowsAbove() throws {
        let hosts = [Self.host(10, package: Self.app, bounds: "42,300,500,800")]
        let bubble = #"{"id":2500,"type":"application","layer":9,"title":"Bubble","displayId":0,"bounds":[100,400,300,600],"active":false,"focused":false,"root":{"i":90,"class":"android.widget.FrameLayout","package":"\#(Self.other)","bounds":[100,400,300,600],"children":[]}}"#
        let error = #expect(throws: AndroidError.self) { try Self.shown(try Self.launcher(hosts, extraWindows: bubble)) }
        #expect(error?.message.contains("overlaps") == true)

        let bar = #"{"id":2313,"type":"system","layer":9,"displayId":0,"bounds":[0,0,1080,142],"active":false,"focused":false}"#
        #expect(try Self.shown(try Self.launcher(hosts, extraWindows: bar)).count == 1)
    }

    @Test("the shade or a system window over the home screen refuses", arguments: [AndroidPhoneScopeTests.shade])
    func overTheHomeScreen(window: String) throws {
        let tree = try Self.launcher([Self.host(10, package: Self.app, bounds: "42,300,500,800")], extraWindows: window, active: false)
        let error = #expect(throws: AndroidError.self) { try Self.shown(tree) }
        #expect(error?.message.contains("com.android.systemui is over the home screen") == true)
    }

    @Test("with no window list, as with uiautomator, nothing proves the widget is clear, so nothing is captured")
    func uiautomatorRefused() throws {
        var tree = try Self.launcher([Self.host(10, package: Self.app, bounds: "42,300,500,800")])
        tree.windows = nil
        let error = #expect(throws: AndroidError.self) { try Self.shown(tree) }
        #expect(error?.message.contains("helper") == true)
    }

    // MARK: The backend

    static func backend(top: String, home: String? = "\(home)/.Home") throws -> (AndroidBackend, FakeAdbServer) {
        let server = AndroidDeviceStateTests.server(devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { command in
            if command == AndroidForeground.readScript {
                return FakeAdbServer.shell(stdout: "top=  topResumedActivity=ActivityRecord{1a2b u0 \(top) t12}\nhome=\(home ?? "")\n")
            }
            return FakeAdbServer.shell()
        }
        let backend = try AndroidBackendTests.backend(server)
        backend.appScopes[phone.rawValue] = AndroidAppScope(permitted: [app], managedCeiling: nil)
        return (backend, server)
    }

    @Test("with an app in front it says to go home, and reads no tree and takes no picture")
    func appInFront() async throws {
        let (backend, server) = try Self.backend(top: "\(Self.app)/.MainActivity")
        let error = await #expect(throws: AndroidError.self) { _ = try await backend.widgets(of: Self.app, on: Self.phone) }
        #expect(error?.reason == .widgetNotShown)
        #expect(error?.message.contains("offsider button home --device \(Self.serial)") == true)
        #expect(!server.services.contains { $0.contains("uiautomator") || $0.contains("screencap") || $0.contains("app_process") || $0.contains("appwidget") })
    }

    @Test("with no default home app, the chooser answering for it proves nothing", arguments: [nil, "android/com.android.internal.app.ResolverActivity"] as [String?])
    func noDefaultHome(home: String?) async throws {
        let (backend, _) = try Self.backend(top: "\(Self.home)/.Home", home: home)
        let error = await #expect(throws: AndroidError.self) { _ = try await backend.widgets(of: Self.app, on: Self.phone) }
        #expect(error?.message.contains("no default home screen") == true)
    }

    @Test("the launcher stays refused for everything but the widget read")
    func launcherElsewhere() async throws {
        let (backend, _) = try Self.backend(top: "\(Self.home)/.Home")
        await PhoneRead.$overSystemWindow.withValue(true) {
            await #expect(throws: AndroidError.self) { _ = try await backend.screenshotPNG(for: Self.phone) }
            await #expect(throws: AndroidError.self) { _ = try await backend.maskTree(for: Self.phone) }
        }
    }

    @Test("a widget read leaves the launcher out of the tree cache, so a later --diff cannot print a person's home screen")
    func notRecorded() async throws {
        let rig = try HelperRig()
        let ledger = DeviceActivityLedger()
        try await DeviceActivityLedger.$current.withValue(ledger) {
            _ = try await rig.backend.readTree(HelperRig.device, point: nil, recording: false)
            _ = try await rig.backend.widgetMaskTree(on: HelperRig.device)
            #expect(ledger.activities.isEmpty)
        }
    }
}
