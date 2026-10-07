import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("rn devmenu and rn tools off")
@MainActor
struct RNDevMenuTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    static let app = FakeUI.tree(platform: .android, [FakeUI.node(.button, id: "tab-home", label: "Home", frame: FakeUI.frame(0, 800, 134, 49), platform: .android)])

    static func expoMenu(platform: DevicePlatform = .android) -> UITree {
        FakeUI.tree(platform: platform, [
            FakeUI.node(.button, label: "Reload", frame: FakeUI.frame(16, 300, 370, 48), platform: platform),
            FakeUI.node(.button, label: "Go home", frame: FakeUI.frame(16, 350, 370, 48), platform: platform),
            FakeUI.node(.button, label: "Toggle performance monitor", frame: FakeUI.frame(16, 400, 370, 48), platform: platform),
            FakeUI.node(.button, label: "Toggle element inspector", frame: FakeUI.frame(16, 450, 370, 48), platform: platform),
            FakeUI.node(.switch, label: "Fast Refresh", frame: FakeUI.frame(16, 500, 370, 48), platform: platform),
            FakeUI.node(.button, label: "Close", frame: FakeUI.frame(350, 250, 36, 36), platform: platform),
        ])
    }

    static func perfShowing() -> UITree {
        FakeUI.tree(platform: .android, [FakeUI.node(.text, label: "UI: 60.0 fps", frame: FakeUI.frame(0, 60, 120, 20), platform: .android)])
    }

    /// A describe-ui capture from the React Native playground (Expo 57) on the Offsider E2E emulator.
    static func capture(_ name: String) throws -> UITree {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try UITree(jsonData: try Data(contentsOf: url))
    }

    @Test("the Expo menu captured on Android is read by its buttons, whose labels lead with the icon's name")
    func expoMenuOnAndroid() throws {
        let menu = try Self.capture("devmenu-expo-android")
        let state = try #require(DevMenu.read(menu))
        #expect(state.menu == "expo")
        #expect(state.items.map(\.label) == ["Close", "Reload", "Go home", "Toggle performance monitor", "Toggle element inspector", "Open DevTools", "Fast Refresh"])
        #expect(state.items.allSatisfy { $0.role == .button })
        #expect(DevMenu.node(for: .home, label: nil, in: menu)?.label == "Home Go home")
        #expect(DevMenu.node(for: .reload, label: nil, in: menu)?.role == .button)
        #expect(DevMenu.node(for: nil, label: "Open React Native dev menu", in: menu)?.label == "React Native dev menu Open React Native dev menu")
        #expect(DevMenu.tools(in: menu) == (inspector: false, perfMonitor: false))
    }

    @Test("React Native's own menu captured on Android is read under its title, though it has no close control")
    func reactNativeMenuOnAndroid() throws {
        let menu = try Self.capture("devmenu-rn-android")
        let state = try #require(DevMenu.read(menu))
        #expect(state.menu == "react-native")
        #expect(state.items.map(\.label) == ["Reload", "Open DevTools", "Toggle Element Inspector", "Disable Fast Refresh", "Show Perf Monitor"])
        #expect(DevMenu.node(for: .inspector, label: nil, in: menu)?.label == "Toggle Element Inspector")
        #expect(DevMenu.node(for: .close, label: nil, in: menu) == nil)
    }

    @Test("the element inspector's panel captured on Android shows as the inspector, and the app beneath it as no menu")
    func inspectorPanelOnAndroid() throws {
        let panel = try Self.capture("devtools-inspector-android")
        #expect(DevMenu.tools(in: panel) == (inspector: true, perfMonitor: false))
        #expect(DevMenu.read(panel) == nil)
    }

    @Test("the Expo menu is read with its items; an app screen is no menu")
    func readsMenu() {
        let state = DevMenu.read(Self.expoMenu())
        #expect(state?.menu == "expo")
        #expect(state?.items.map(\.label) == ["Reload", "Go home", "Toggle performance monitor", "Toggle element inspector", "Fast Refresh", "Close"])
        #expect(DevMenu.read(Self.app) == nil)
        #expect(DevMenu.jsonLine(state!).hasPrefix(#"{"version":1,"menu":"expo","items":[{"label":"Reload","role":"button"}"#))
    }

    /// A tree captured from the Expo 57 playground on an iOS 27 simulator, in `Tests/Fixtures`.
    static func captured(_ name: String) throws -> UITree {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        let capture = try RawTreeCapture(jsonData: try Data(contentsOf: url))
        return UITree(platform: .ios, device: "IOS-UDID", screen: capture.screen, roots: try IOSAccessibilityMapping.roots(fromJSON: capture.source))
    }

    @Test("the captured iOS Expo menu reads as expo with its real items, and Fast refresh maps to its switch")
    func capturedExpoMenu() throws {
        let menu = try Self.captured("devmenu-expo-ios")
        let state = try #require(DevMenu.read(menu))

        #expect(state.menu == "expo")
        #expect(state.items.map(\.label) == ["Close", "Reload", "Go home", "Toggle performance monitor", "Toggle element inspector", "Open DevTools", "Fast refresh"])
        #expect(DevMenu.node(for: .close, label: nil, in: menu)?.id == "xmark")
        #expect(DevMenu.node(for: .inspector, label: nil, in: menu)?.role == .button)
        let fastRefresh = try #require(DevMenu.node(for: .fastRefresh, label: nil, in: menu))
        #expect(fastRefresh.role == .switch && fastRefresh.children.isEmpty)
        #expect(DevMenu.node(for: .debugger, label: nil, in: menu)?.label == "Open DevTools")
        #expect(DevMenu.tools(in: menu) == (inspector: false, perfMonitor: false))
    }

    @Test("fast-refresh holds its switch rather than tapping it, since the Expo switch ignores a quick tap")
    func fastRefreshHoldsSwitch() async throws {
        let menu = try Self.captured("devmenu-expo-ios")
        let device = DeviceID(rawValue: "IOS-UDID", platform: .ios)
        let backend = FakeDeviceBackend(platform: .ios, trees: [menu, Self.app])
        let command = try RNDevMenu.parse(["fast-refresh", "--device", device.rawValue])

        _ = try await command.perform(on: DeviceRouter.Route(backend: backend, device: device), clock: ScriptedClock().poll)

        #expect(backend.session.calls.isEmpty)
        let steps = try #require(backend.detachedTouches.first)
        #expect(steps.count == 3)
        #expect(steps.contains(.hold(DevMenuDriver.switchHold)))
    }

    @Test("the captured iOS inspector panel and performance monitor are each read as showing, and neither is a menu")
    func capturedTools() throws {
        let inspector = try Self.captured("devmenu-inspector-ios")
        let perf = try Self.captured("devmenu-perf-monitor-ios")

        #expect(DevMenu.tools(in: inspector) == (inspector: true, perfMonitor: false))
        #expect(DevMenu.tools(in: perf) == (inspector: false, perfMonitor: true))
        #expect(DevMenu.read(inspector) == nil && DevMenu.read(perf) == nil)
    }

    @Test("each item maps to its label in the menu, and the close control also by its xmark id")
    func mapping() {
        let menu = Self.expoMenu()
        #expect(DevMenu.node(for: .reload, label: nil, in: menu)?.label == "Reload")
        #expect(DevMenu.node(for: .perfMonitor, label: nil, in: menu)?.label == "Toggle performance monitor")
        #expect(DevMenu.node(for: .fastRefresh, label: nil, in: menu)?.role == .switch)
        #expect(DevMenu.node(for: .debugger, label: nil, in: menu) == nil)
        let ios = FakeUI.tree([FakeUI.node(.button, label: "Reload", frame: FakeUI.frame(16, 300, 370, 48)), FakeUI.node(.button, id: "xmark", label: "Close", frame: FakeUI.frame(350, 250, 36, 36))])
        #expect(DevMenu.node(for: .close, label: nil, in: ios)?.id == "xmark")
    }

    /// An app's own screen with Reload and Close buttons, an xmark and a Go home link.
    static func appWithReload(platform: DevicePlatform = .android) -> UITree {
        FakeUI.tree(platform: platform, [
            FakeUI.node(.button, id: "xmark", label: "Close", frame: FakeUI.frame(350, 60, 36, 36), platform: platform),
            FakeUI.node(.button, id: "app-reload", label: "Reload", frame: FakeUI.frame(16, 700, 370, 48), platform: platform),
            FakeUI.node(.link, label: "Go home", frame: FakeUI.frame(16, 760, 370, 48), platform: platform),
        ])
    }

    @Test("an app screen with Reload, Close and one menu item is no menu, so rn devmenu reload opens the menu and taps its Reload")
    func appReloadIsNoMenu() async throws {
        #expect(DevMenu.read(Self.appWithReload()) == nil)
        #expect(DevMenu.read(Self.appWithReload(platform: .ios)) == nil)
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.appWithReload(), Self.expoMenu(), Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["reload", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .reload, label: "Reload"))
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu)), .perform(.tapAt(x: 201, y: 324))])
    }

    @Test("on a physical iPhone, which Offsider cannot open the menu on, the error says to shake it by hand and never suggests a two-finger touch")
    func physicalDeviceHint() async throws {
        let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["reload", "--device", phone.rawValue])
                .perform(on: DeviceRouter.Route(backend: NoDevMenuBackend(tree: Self.app), device: phone), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .notSupported)
        #expect(error?.userFacingDescription.contains("Shake the device by hand") == true)
        #expect(error?.userFacingDescription.contains("--fingers") == false)
    }

    @Test("on Android the menu key opens the menu as input, then reload is tapped and the menu closes")
    func opensAndChooses() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app, Self.expoMenu(), Self.app], advanceTreeOnInput: true)
        let command = try RNDevMenu.parse(["reload", "--device", Self.device.rawValue])

        let outcome = try await command.perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .reload, label: "Reload"))
        #expect(backend.devMenuOpens == 0)
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu)), .perform(.tapAt(x: 201, y: 324))])
    }

    @Test("a menu still sliding in is tapped where it comes to rest, not where the first read saw it")
    func waitsForMenuToSettle() async throws {
        let sliding = FakeUI.tree(platform: .android, Self.expoMenu().roots[0].children.map { node in
            var moved = node
            moved.frame = node.frame.map { FakeUI.frame($0.x, $0.y + 120, $0.width, $0.height) }
            return moved
        })
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app, sliding, Self.expoMenu(), Self.expoMenu(), Self.app])

        let outcome = try await RNDevMenu.parse(["reload", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .reload, label: "Reload"))
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu)), .perform(.tapAt(x: 201, y: 324))])
    }

    @Test("a Close the menu ignored while it was still presenting is tapped once more")
    func closeTappedAgain() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.expoMenu(), Self.expoMenu(), Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["close", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .close, label: "Close"))
        #expect(backend.session.calls == [.perform(.tapAt(x: 368, y: 268)), .perform(.tapAt(x: 368, y: 268))])
    }

    @Test("on an iOS simulator the menu opens by shake, not by a key")
    func iosOpensByShake() async throws {
        let simulator = DeviceID(rawValue: UUID().uuidString, platform: .ios)
        let backend = FakeDeviceBackend(platform: .ios, trees: [Self.app, Self.expoMenu(platform: .ios), Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["reload", "--device", simulator.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: simulator), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .reload, label: "Reload"))
        #expect(backend.devMenuOpens == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 324))])
    }

    @Test("in batch, rn devmenu reload sends the menu key and its tap through the batch's own session")
    func batchStep() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app, Self.expoMenu(), Self.app], advanceTreeOnInput: true)
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)

        let records = try await Batch.runSteps(["rn devmenu reload"], context: context, session: backend.session, continueOnError: false, logger: OffsiderLogger())

        #expect(records.map(\.ok) == [true])
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu)), .perform(.tapAt(x: 201, y: 324))])
        #expect(backend.openedSessions.isEmpty)
    }

    @Test("a batch rn step must be rn devmenu with an item or --label, and sends nothing otherwise", arguments: ["rn devmenu", "rn logbox dismiss", "rn"])
    func batchStepNeedsItem(step: String) async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app, Self.expoMenu()], advanceTreeOnInput: true)
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)

        let error = await #expect(throws: ReportedFailure.self) {
            try await Batch.runSteps([step], context: context, session: backend.session, continueOnError: false, logger: OffsiderLogger())
        }

        #expect(error?.exitCode == .usage)
        #expect(error?.userFacingDescription.contains(BatchStepParser.rnStepMessage) == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("choosing an item with --json prints one JSON object naming the menu, the item, the label tapped and that it closed")
    func choiceJSON() {
        let reload = RNDevMenu.Outcome.chose(menu: "expo", item: .reload, label: "Reload")
        #expect(reload.jsonLine() == #"{"version":1,"menu":"expo","item":"reload","label":"Reload","closed":true}"#)
        let byLabel = RNDevMenu.Outcome.chose(menu: "expo", item: nil, label: "Open React Native dev menu")
        #expect(byLabel.jsonLine() == #"{"version":1,"menu":"expo","item":null,"label":"Open React Native dev menu","closed":true}"#)
        #expect(byLabel.textLine() == "✓ Chose Open React Native dev menu and the dev menu closed")
    }

    @Test("a label that opens React Native's own menu from Expo's counts as chosen, with no close tap")
    func switchesMenus() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [try Self.capture("devmenu-expo-android"), try Self.capture("devmenu-rn-android")], advanceTreeOnInput: true)
        let command = try RNDevMenu.parse(["--label", "Open React Native dev menu", "--device", Self.device.rawValue])

        let outcome = try await command.perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: nil, label: "Open React Native dev menu"))
        #expect(backend.session.calls.count == 1)
    }

    @Test("an item the menu lacks is exit 2 with the menu's items as candidates")
    func absentItem() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.expoMenu()])
        let command = try RNDevMenu.parse(["debugger", "--device", Self.device.rawValue])
        let error = await #expect(throws: CLIError.self) {
            _ = try await command.perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .selectorNotFound)
        #expect(error?.candidates.map(\.label) == ["Reload", "Go home", "Toggle performance monitor", "Toggle element inspector", "Fast Refresh", "Close"])
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a menu that never opens is state_not_reached, as in a Release build")
    func neverOpens() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app])
        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--device", Self.device.rawValue]).perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .stateNotReached)
    }

    @Test("tools off turns off a showing performance monitor through the menu and leaves the inspector alone")
    func toolsOff() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.perfShowing(), Self.expoMenu(), Self.app], advanceTreeOnInput: true)
        let result = try await RNToolsOff.parse(["--device", Self.device.rawValue]).turnOff(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(result == (inspector: "off", perfMonitor: "turned-off"))
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu)), .perform(.tapAt(x: 201, y: 424))])
        #expect(DevMenu.toolsJSONLine(inspector: "off", perfMonitor: "turned-off") == #"{"version":1,"inspector":"off","perfMonitor":"turned-off"}"#)
    }

    @Test("tools off never toggles when the screen cannot be read")
    func unreadable() async throws {
        let backend = UnreadableBackend()
        let error = await #expect(throws: CLIError.self) {
            _ = try await RNToolsOff.parse(["--device", Self.device.rawValue]).turnOff(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .notSupported)
        #expect(backend.opens == 0)
    }
}

/// A backend with no way to open the dev menu, as on a physical iPhone; serves one tree.
@MainActor
private final class NoDevMenuBackend: DeviceBackend {
    let tree: UITree
    init(tree: UITree) { self.tree = tree }
    var platform: DevicePlatform { .ios }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Phone") }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree { tree }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
    func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] { points }
    func openInputSession(for id: DeviceID) async throws -> any InputSession { RecordingInputSession() }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { ScreenBands(top: 0, bottom: 0) }
}

@MainActor
private final class UnreadableBackend: ReactNativeDevMenuOpening {
    private(set) var opens = 0
    var platform: DevicePlatform { .android }
    func prepare() async throws {}
    func listDevices() async throws -> [DeviceSummary] { [] }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Unreadable") }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree { throw CLIError(errorDescription: "unreadable", reason: .treeReadFailed) }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
    func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] { points }
    func openInputSession(for id: DeviceID) async throws -> any InputSession { RecordingInputSession() }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { ScreenBands(top: 0, bottom: 0) }
    func openDevMenu(_ id: DeviceID) async throws { opens += 1 }
}
