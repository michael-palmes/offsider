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

    @Test("the Expo menu is read with its items; an app screen is no menu")
    func readsMenu() {
        let state = DevMenu.read(Self.expoMenu())
        #expect(state?.menu == "expo")
        #expect(state?.items.map(\.label) == ["Reload", "Go home", "Toggle performance monitor", "Toggle element inspector", "Fast Refresh", "Close"])
        #expect(DevMenu.read(Self.app) == nil)
        #expect(DevMenu.jsonLine(state!).hasPrefix(#"{"version":1,"menu":"expo","items":[{"label":"Reload","role":"button"}"#))
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

    @Test("an app screen opens the menu, then reload is tapped and the menu closes")
    func opensAndChooses() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app, Self.expoMenu(), Self.app], advanceTreeOnInput: true)
        let command = try RNDevMenu.parse(["reload", "--device", Self.device.rawValue])

        let state = try await command.perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(state == nil)
        #expect(backend.devMenuOpens == 1)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 324))])
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
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 424))])
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
