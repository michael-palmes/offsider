import CoreGraphics
import Foundation
@testable import OffsiderAndroid
import OffsiderCore
import Testing
@testable import Offsider

/// What `screenshot --widget` writes, from a scripted widget read.
@MainActor
private final class WidgetBackend: FakeDeviceBackend, WidgetCapturing {
    /// Each read's answer in order, holding the last.
    let reads: [[HomeWidget]]
    let launcherTree: UITree
    var failure: AndroidError?
    private(set) var widgetReads = 0
    private(set) var askedApps: [String] = []
    private(set) var fullScreens = 0

    init(reads: [[HomeWidget]], tree: UITree = FakeUI.tree(platform: .android, width: 390, height: 844, [])) throws {
        self.reads = reads
        launcherTree = tree
        super.init(platform: .android, trees: [], screenshots: [try ScreenshotMaskTests.whitePNG()], screen: ScreenshotMaskTests.screen)
    }

    func widgets(of app: String, on id: DeviceID) async throws -> [HomeWidget] {
        if let failure { throw failure }
        askedApps.append(app)
        defer { widgetReads += 1 }
        return reads[min(widgetReads, reads.count - 1)]
    }

    func widgetMaskTree(on id: DeviceID) async throws -> UITree { launcherTree }

    func widgetFullScreenPNG(on id: DeviceID) async throws -> Data {
        fullScreens += 1
        return try ScreenshotMaskTests.whitePNG()
    }
}

@Suite("screenshot --widget")
@MainActor
struct ScreenshotWidgetTests {
    static let app = "com.mpalmes.offsider.playground.rn"
    nonisolated static let widget = HomeWidget(frame: UIFrame(x: 30, y: 100, width: 300, height: 200), label: "Status")
    nonisolated static let second = HomeWidget(frame: UIFrame(x: 30, y: 400, width: 150, height: 100), label: "Totals")

    fileprivate static func capture(_ extra: [String] = [], on backend: WidgetBackend, app: String = app) async throws -> (report: ScreenshotReport, image: CGImage, path: String) {
        try await ScreenshotMaskTests.capture(["--widget", "--app", app] + extra, on: backend, environment: [:])
    }

    @Test("the image holds the widget and nothing beyond it, a point inside its frame each side")
    func cropped() async throws {
        let backend = try WidgetBackend(reads: [[Self.widget]])
        let (report, image, _) = try await Self.capture(on: backend)
        #expect(image.width == 298 * 3)
        #expect(image.height == 198 * 3)
        #expect(report.region == PointRegion(x: 31, y: 101, width: 298, height: 198))
        #expect(backend.askedApps.first == Self.app)
        #expect(backend.screenshotReads == 0)
    }

    @Test("a crop stays inside a frame however the points land on pixels", arguments: [
        UIFrame(x: 433.64, y: 445.54, width: 377.85, height: 201.44),
        UIFrame(x: 0.34, y: 0.67, width: 10.1, height: 3.3),
        UIFrame(x: 100, y: 200, width: 1, height: 1),
    ])
    func cropInside(frame: UIFrame) throws {
        let chosen = ChosenWidget(capturer: try WidgetBackend(reads: [[]]), app: Self.app, widget: HomeWidget(frame: frame, label: nil), nth: 1, count: 1)
        for pixelsPerPoint in [1.0, 2.4375, 3.0] {
            let rect = try ScreenGeometry.pixelRect(for: chosen.crop, pixelsPerPoint: pixelsPerPoint, imageWidth: 3000, imageHeight: 3000)
            #expect(Double(rect.x) >= (frame.x * pixelsPerPoint).rounded(.down))
            #expect(Double(rect.y) >= (frame.y * pixelsPerPoint).rounded(.down))
            #expect(Double(rect.x + rect.width) <= ((frame.x + frame.width) * pixelsPerPoint).rounded(.up))
            #expect(Double(rect.y + rect.height) <= ((frame.y + frame.height) * pixelsPerPoint).rounded(.up))
        }
    }

    @Test("--json names the widget and marks its label as the device's words")
    func json() async throws {
        let (report, _, _) = try await Self.capture(on: try WidgetBackend(reads: [[Self.widget]]))
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(report.jsonLine().utf8)) as? [String: Any])
        let widget = try #require(payload["widget"] as? [String: Any])
        #expect(widget["app"] as? String == Self.app)
        #expect(widget["label"] as? String == "Status")
        #expect(widget["nth"] as? Int == 1)
        #expect(widget["count"] as? Int == 1)
        #expect((payload["untrusted"] as? [String])?.contains("widget.label") == true)
    }

    @Test("masks paint as on any capture, in the launcher's coordinates, before the crop")
    func masked() async throws {
        let label = FakeUI.node(.text, label: "Balance 120", frame: FakeUI.frame(60, 150, 100, 30))
        let backend = try WidgetBackend(reads: [[Self.widget]], tree: FakeUI.tree(platform: .android, width: 390, height: 844, [label]))
        let (report, image, _) = try await Self.capture(["--mask-text", "Balance"], on: backend)
        #expect(report.maskedBy?[.text] == 1)
        #expect(ScreenshotMaskTests.pixel(image, (100 - 31) * 3, (160 - 101) * 3) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.pixel(image, 3, 3) == ScreenshotMaskTests.white)
    }

    @Test("password fields are masked by default, and a --mask-region paints too")
    func secureByDefault() async throws {
        let field = FakeUI.node(.secureTextField, label: "Code", frame: FakeUI.frame(60, 150, 100, 30))
        let backend = try WidgetBackend(reads: [[Self.widget]], tree: FakeUI.tree(platform: .android, width: 390, height: 844, [field]))
        let (report, image, _) = try await ScreenshotMaskTests.capture(["--widget", "--app", Self.app, "--mask-region", "200,200,50,50"], on: backend, environment: [:])
        #expect(report.maskedBy?[.secure] == 1)
        #expect(ScreenshotMaskTests.pixel(image, (100 - 31) * 3, (160 - 101) * 3) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.pixel(image, (220 - 31) * 3, (220 - 101) * 3) == ScreenshotMaskTests.black)
    }

    @Test("a page turned during the capture writes nothing", arguments: [[second], [widget, second], [HomeWidget(frame: UIFrame(x: 31, y: 100, width: 300, height: 200), label: "Status")]])
    func changedDuringCapture(after: [HomeWidget]) async throws {
        let backend = try WidgetBackend(reads: [[Self.widget], after])
        let path = ScreenshotMaskTests.temporaryPath()
        let command = try Screenshot.parse(["--output", path, "--device", ScreenshotMaskTests.device.rawValue, "--widget", "--app", Self.app])
        let error = await #expect(throws: CLIError.self) {
            _ = try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: ScreenshotMaskTests.device), masks: try command.maskPlan(environment: [:]))
        }
        #expect(error?.reason == .widgetNotShown)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("several widgets with no choice name each and capture nothing; --widget-nth picks one", arguments: [1, 2])
    func several(nth: Int) async throws {
        let backend = try WidgetBackend(reads: [[Self.widget, Self.second]])
        let path = ScreenshotMaskTests.temporaryPath()
        let command = try Screenshot.parse(["--output", path, "--device", ScreenshotMaskTests.device.rawValue, "--widget", "--app", Self.app])
        let route = DeviceRouter.Route(backend: backend, device: ScreenshotMaskTests.device)
        let error = await #expect(throws: CLIError.self) {
            _ = try await command.take(try command.request(), on: route, masks: try command.maskPlan(environment: [:]))
        }
        #expect(error?.reason == .selectorAmbiguous)
        #expect(error?.errorDescription?.contains("--widget-nth") == true)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(backend.fullScreens == 0)

        let (report, image, _) = try await Self.capture(["--widget-nth", String(nth)], on: backend)
        #expect(report.widget?.nth == nth)
        #expect(report.widget?.count == 2)
        #expect(image.width == (nth == 1 ? 298 : 148) * 3)
    }

    @Test("--widget-nth past the widgets on screen is a usage error")
    func nthTooHigh() async throws {
        let backend = try WidgetBackend(reads: [[Self.widget]])
        let error = await #expect(throws: CLIError.self) { _ = try await Self.capture(["--widget-nth", "2"], on: backend) }
        #expect(error?.reason == .usage)
        #expect(backend.fullScreens == 0)
    }

    @Test("a refusal from the device captures nothing")
    func refused() async throws {
        let backend = try WidgetBackend(reads: [[Self.widget]])
        backend.failure = AndroidError.widgetNotShown("Not here.")
        await #expect(throws: AndroidError.self) { _ = try await Self.capture(on: backend) }
        #expect(backend.fullScreens == 0)
    }

    @Test("the flags that would widen or contradict the crop are refused before anything runs", arguments: [
        (["--widget", "--region", "0,0,10,10"], "--region"),
        (["--widget", "--display", "cover"], "--display"),
        (["--widget-nth", "1"], "--widget-nth applies"),
        (["--widget", "--widget-nth", "0"], "counts from 1"),
    ])
    func validation(arguments: [String], message: String) {
        #expect(throws: (any Error).self) { _ = try Screenshot.parse(["--device", "emulator-5554"] + arguments) }
        let shown = Screenshot.message(for: arguments)
        #expect(shown.contains(message), "\(shown)")
    }

    @Test("a phone reads only an app its allowance permits, and the only pinned app needs no --app")
    func allowance() throws {
        let allowance = DeviceAllowance(platform: .android, key: "R58M123ABC", name: "Phone", added: Date(), expires: nil, apps: [Self.app])
        let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
        let route = DeviceRouter.Route(backend: try WidgetBackend(reads: [[]]), device: phone, allowance: allowance)
        let gate = DevicePolicyGate.fixed(PhysicalDevicePolicy(managed: ManagedDevicePolicy(), list: DeviceAllowList(entries: [allowance])))
        #expect(try Screenshot.widgetApp(nil, route: route, gate: gate, profile: { nil }) == Self.app)
        let refused = #expect(throws: CLIError.self) { try Screenshot.widgetApp("com.example.other", route: route, gate: gate, profile: { nil }) }
        #expect(refused?.reason == .appNotAllowed)
        let launcher = #expect(throws: CLIError.self) { try Screenshot.widgetApp("com.google.android.apps.nexuslauncher", route: route, gate: gate, profile: { nil }) }
        #expect(launcher?.reason == .appNotAllowed)
    }

    @Test("an emulator needs the app named")
    func emulatorNeedsApp() throws {
        let route = DeviceRouter.Route(backend: try WidgetBackend(reads: [[]]), device: ScreenshotMaskTests.device)
        let error = #expect(throws: CLIError.self) { try Screenshot.widgetApp(nil, route: route, profile: { nil }) }
        #expect(error?.reason == .usage)
    }

    @Test("a backend with no widget read, as iOS has, says so")
    func notAndroid() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([])], screenshots: [try ScreenshotMaskTests.whitePNG()], screen: ScreenshotMaskTests.screen)
        let command = try Screenshot.parse(["--device", ScreenshotMaskTests.device.rawValue, "--widget", "--app", Self.app])
        let error = await #expect(throws: CLIError.self) {
            _ = try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: ScreenshotMaskTests.device), masks: try command.maskPlan(environment: [:]))
        }
        #expect(error?.reason == .notSupported)
    }
}

private extension Screenshot {
    /// The validation message `parse` would print for `arguments`.
    static func message(for arguments: [String]) -> String {
        do {
            _ = try parse(["--device", "emulator-5554"] + arguments)
            return ""
        } catch {
            return fullMessage(for: error)
        }
    }
}

/// The system window a capture names, on stderr and in `--json`.
@MainActor
private final class CoveredBackend: FakeDeviceBackend, SystemWindowReporting, MaskTreeReading {
    let window = UITreeContext.Window(title: "Keep this for later?", kind: .system, package: "android", readOnly: true)
    let maskTreeValue: UITree

    init(tree: UITree) throws {
        maskTreeValue = tree
        super.init(platform: .android, trees: [tree], screenshots: [try ScreenshotMaskTests.whitePNG()], screen: ScreenshotMaskTests.screen)
    }

    func systemWindow(for id: DeviceID) -> UITreeContext.Window? { window }
    func maskTree(for id: DeviceID) async throws -> UITree { maskTreeValue }
}

@Suite("screenshot under a system window")
@MainActor
struct ScreenshotSystemWindowTests {
    static func tree(appListed: Bool) -> UITree {
        var tree = FakeUI.tree(platform: .android, width: 390, height: 844, [])
        tree.systemWindow = UITreeContext.Window(title: "Keep this for later?", kind: .system, package: "android", readOnly: true)
        let sheet = UIWindowInfo(id: 2, kind: "system", layer: 5, title: "Keep this for later?", active: true, focused: true, package: "android", bounds: FakeUI.frame(0, 500, 390, 344))
        let app = UIWindowInfo(id: 1, kind: "application", layer: 0, title: "Playground", active: false, focused: false, package: "com.example.app", bounds: FakeUI.frame(0, 0, 390, 844))
        tree.windows = appListed ? [app, sheet] : [sheet]
        return tree
    }

    @Test("the capture names the window in JSON and on stderr, and marks its title as the device's words")
    func named() async throws {
        let capture = ConsoleCapture()
        let (report, _, _) = try await Console.$current.withValue(AgentOutputTests.agentConsole(capture)) {
            try await ScreenshotMaskTests.capture([], on: try CoveredBackend(tree: Self.tree(appListed: true)), environment: [:])
        }
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(report.jsonLine().utf8)) as? [String: Any])
        let window = try #require(payload["systemWindow"] as? [String: Any])
        #expect(window["title"] as? String == "Keep this for later?")
        #expect(window["package"] as? String == "android")
        #expect(window["readOnly"] as? Bool == true)
        #expect((payload["untrusted"] as? [String])?.contains("systemWindow.title") == true)
        #expect(capture.err.contains("Keep this for later?"))
        #expect(capture.err.contains("input stays refused"))
    }

    @Test("when Android lists nothing beneath the window, masks are unproven; with the app listed they are proven")
    func unproven() async throws {
        #expect(ScreenCapture.unproven(Self.tree(appListed: true)) == nil)
        #expect(ScreenCapture.unproven(Self.tree(appListed: false)) == "modal")
        let (report, _, _) = try await ScreenshotMaskTests.capture([], on: try CoveredBackend(tree: Self.tree(appListed: false)), environment: [:])
        #expect(report.maskUnproven == "modal")
    }

    @Test("a password field in the app beneath is painted")
    func painted() async throws {
        var tree = Self.tree(appListed: true)
        tree.roots = [FakeUI.node(.secureTextField, label: "Code", frame: FakeUI.frame(60, 150, 100, 30))]
        let (report, image, _) = try await ScreenshotMaskTests.capture([], on: try CoveredBackend(tree: tree), environment: [:])
        #expect(report.maskedBy?[.secure] == 1)
        #expect(ScreenshotMaskTests.point(image, 100, 160) == ScreenshotMaskTests.black)
    }
}
