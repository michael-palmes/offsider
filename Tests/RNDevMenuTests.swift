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

    /// The Expo menu with the item labelled `label` moved below the 874 pt screen.
    static func expoMenu(below label: String) -> UITree {
        FakeUI.tree(platform: .android, Self.expoMenu().roots[0].children.map { node in
            var moved = node
            if node.label == label { moved.frame = node.frame.map { FakeUI.frame($0.x, 900, $0.width, $0.height) } }
            return moved
        })
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
        #expect(state.items.allSatisfy { $0.role == .button && !$0.custom })
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
        #expect(!DevMenu.jsonLine(state!).contains("custom"))
    }

    // MARK: Items the app registers

    /// `tree` with Expo's custom section before its TOOLS heading, as expo-dev-menu draws `registerDevMenuItems` items:
    /// a capitalised heading, then a button per item, held in one container on Android and beside the heading on iOS.
    static func withCustomItems(_ tree: UITree, _ labels: [String] = ["Clear cache", "Toggle mock data"]) -> UITree {
        let platform = tree.platform
        let buttons = labels.enumerated().map { offset, label in
            let frame = FakeUI.frame(24, 600 + Double(offset) * 64, 363, 64)
            let text = FakeUI.node(.text, label: label, frame: FakeUI.frame(40, frame.y + 23, 120, 17), platform: platform)
            return platform == .android
                ? FakeUI.node(.button, label: label, frame: frame, platform: platform, children: [FakeUI.node(.group, frame: frame, platform: platform, children: [text]), FakeUI.node(.button, frame: frame, platform: platform)])
                : FakeUI.node(.button, label: label, frame: frame, platform: platform, children: [text])
        }
        let heading = FakeUI.node(.text, label: "CUSTOM MENU ITEMS", frame: FakeUI.frame(24, 570, 150, 15), platform: platform)
        let section = platform == .android ? [heading, FakeUI.node(.group, frame: FakeUI.frame(24, 600, 363, 128), platform: platform, children: buttons)] : [heading] + buttons
        func insert(_ node: UINode) -> UINode {
            var copy = node
            if let tools = node.children.firstIndex(where: { $0.label == "TOOLS" }) {
                copy.children.insert(contentsOf: section, at: tools)
            } else {
                copy.children = node.children.map(insert)
            }
            return copy
        }
        var edited = tree
        edited.roots = tree.roots.map(insert)
        return edited
    }

    @Test("items an app registers with Expo are listed after Go home and marked custom, while the built-ins, Expo's other buttons and the app behind are as before", arguments: [DevicePlatform.android, .ios])
    func expoCustomItems(platform: DevicePlatform) throws {
        let plain = platform == .android ? try Self.capture("devmenu-expo-android") : try Self.captured("devmenu-expo-ios")
        let before = try #require(DevMenu.read(plain))
        let state = try #require(DevMenu.read(Self.withCustomItems(plain)))

        let fastRefresh = platform == .android ? "Fast Refresh" : "Fast refresh"
        #expect(state.menu == "expo")
        #expect(state.items.map(\.label) == ["Close", "Reload", "Go home", "Clear cache", "Toggle mock data", "Toggle performance monitor", "Toggle element inspector", "Open DevTools", fastRefresh])
        #expect(state.items.filter(\.custom).map(\.label) == ["Clear cache", "Toggle mock data"])
        #expect(state.items.filter { !$0.custom } == before.items)
        let others = ["Show Banner", "Clear Logs", "Start Clock", "Source code explorer", "Open React Native dev menu", "Copy system info", "Tools button"]
        #expect(state.items.allSatisfy { !others.contains($0.label) })
    }

    @Test("rn devmenu --json marks only the app's items custom, and its agent line lists them apart with their exact labels")
    func customListing() throws {
        let state = try #require(DevMenu.read(Self.withCustomItems(try Self.capture("devmenu-expo-android"))))
        let json = DevMenu.jsonLine(state)

        #expect(json.contains(#"{"label":"Go home","role":"button"},{"label":"Clear cache","role":"button","custom":true},{"label":"Toggle mock data","role":"button","custom":true},{"label":"Toggle performance monitor","role":"button"}"#))
        #expect(json.components(separatedBy: "custom").count == 3)
        #expect(RNDevMenu.Outcome.listed(state).textLine() == "expo dev menu: Close, Reload, Go home, Toggle performance monitor, Toggle element inspector, Open DevTools, Fast Refresh; custom: Clear cache, Toggle mock data")
    }

    @Test("rn devmenu --label chooses an item the app registered, then closes the menu Expo's Android menu leaves open")
    func choosesCustomItem() async throws {
        let menu = Self.withCustomItems(try Self.capture("devmenu-expo-android"))
        let close = try #require(DevMenu.node(for: .close, label: nil, in: menu)?.frame?.center)
        let backend = FakeDeviceBackend(platform: .android, trees: [menu, menu, Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["--label", "Toggle mock data", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: nil, label: "Toggle mock data"))
        #expect(backend.session.calls == [.perform(.tapAt(x: 205.5, y: 696)), .perform(.tapAt(x: close.x, y: close.y))])
    }

    @Test("a button behind the menu with an app item's label is neither listed nor tapped: the menu's own item is")
    func customItemOverAppButton() throws {
        var menu = Self.withCustomItems(try Self.captured("devmenu-expo-ios"))
        menu.roots[0].children.insert(FakeUI.node(.button, id: "app-clear-cache", label: "Clear cache", frame: FakeUI.frame(16, 120, 370, 44)), at: 0)

        let state = try #require(DevMenu.read(menu))
        let chosen = try #require(DevMenu.node(for: nil, label: "Clear cache", in: menu))

        #expect(state.items.filter { $0.label == "Clear cache" }.map(\.frame) == [FakeUI.frame(24, 600, 363, 64)])
        #expect(chosen.frame == FakeUI.frame(24, 600, 363, 64) && chosen.id == nil)
    }

    @Test("on Android an Expo menu whose app items push the tools below the fold still reads as the menu, listing only its own items")
    func customItemsHideTools() throws {
        let customs = (1...5).map { "Seed account \($0)" }
        let reload = FakeUI.node(.button, label: "Reload Reload", frame: FakeUI.frame(24, 461.33, 177.52, 64), platform: .android)
        let heading = FakeUI.node(.text, label: "CUSTOM MENU ITEMS", frame: FakeUI.frame(24, 557.33, 150, 15.62), platform: .android)
        let menu = FakeUI.tree(platform: .android, [
            FakeUI.node(.button, label: "Close", frame: FakeUI.frame(345.52, 391.62, 48, 48), platform: .android),
            FakeUI.node(.scrollView, frame: FakeUI.frame(0, 461.33, 411.43, 462.1), platform: .android, children: [
                reload,
                FakeUI.node(.button, label: "Home Go home", frame: FakeUI.frame(209.52, 461.33, 177.9, 64), platform: .android),
                heading,
                FakeUI.node(.group, frame: FakeUI.frame(24, 588.95, 363.43, 334.48), platform: .android, children: customs.enumerated().map { offset, label in
                    FakeUI.node(.button, label: label, frame: FakeUI.frame(24, 588.95 + Double(offset) * 64, 363.43, 64), platform: .android)
                }),
            ]),
            FakeUI.node(.button, id: "app-sync", label: "Sync now", frame: FakeUI.frame(16, 120, 370, 44), platform: .android),
        ])

        let state = try #require(DevMenu.read(menu))

        #expect(state.menu == "expo")
        #expect(state.items.map(\.label) == ["Close", "Reload", "Go home"] + customs)
        #expect(state.items.filter(\.custom).map(\.label) == customs)
        #expect(DevMenu.read(FakeUI.tree(platform: .android, [reload, heading])) == nil)
    }

    /// React Native's Android menu rows, under its title, as `AlertDialog` lists them.
    static func reactNativeMenu(_ rows: [String]) -> UITree {
        let list = rows.enumerated().map { offset, row in
            FakeUI.node(.text, id: "android:id/text1", label: row, frame: FakeUI.frame(26.67, 329.14 + Double(offset) * 48, 358.1, 48), platform: .android)
        }
        return FakeUI.tree(platform: .android, [
            FakeUI.node(.text, label: "React Native Dev Menu", frame: FakeUI.frame(26.67, 280.38, 358.1, 40.76), platform: .android),
            FakeUI.node(.list, id: "android:id/select_dialog_listview", frame: FakeUI.frame(26.67, 329.14, 358.1, 48 * Double(rows.count)), platform: .android, children: list),
        ])
    }

    @Test("React Native's Android menu marks custom the rows after its last built-in, Settings or Fast Refresh, and lists no other built-in rows")
    func reactNativeCustomRows() async throws {
        let legacy = Self.reactNativeMenu(["Reload", "Open DevTools", "Change Bundle Location", "Toggle Element Inspector", "Disable Fast Refresh", "Show Perf Monitor", "Settings", "Clear cache"])
        let newer = Self.reactNativeMenu(["Reload", "Open DevTools", "Start performance trace", "Show performance overlay", "Change Bundle Location", "Toggle Element Inspector", "Enable Fast Refresh", "Clear cache"])

        let old = try #require(DevMenu.read(legacy))
        #expect(old.menu == "react-native")
        #expect(old.items.map(\.label) == ["Reload", "Open DevTools", "Toggle Element Inspector", "Disable Fast Refresh", "Show Perf Monitor", "Clear cache"])
        #expect(old.items.filter(\.custom).map(\.label) == ["Clear cache"])
        #expect(DevMenu.read(newer)?.items.filter(\.custom).map(\.label) == ["Clear cache"])
        #expect(DevMenu.read(try Self.capture("devmenu-rn-android"))?.items.contains(where: \.custom) == false)
        var behind = legacy
        behind.roots.append(FakeUI.node(.group, frame: FakeUI.frame(0, 800, 411, 60), platform: .android, children: ["Home", "Settings", "Profile"].map {
            FakeUI.node(.button, label: $0, frame: FakeUI.frame(0, 800, 137, 60), platform: .android)
        }))
        #expect(DevMenu.read(behind)?.items.filter(\.custom).map(\.label) == ["Clear cache"], "the app's tabs behind the dialog are not the menu's")

        let backend = FakeDeviceBackend(platform: .android, trees: [legacy, Self.app], advanceTreeOnInput: true)
        let outcome = try await RNDevMenu.parse(["--label", "Clear cache", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        #expect(outcome == .chose(menu: "react-native", item: nil, label: "Clear cache"))
        let row = FakeUI.frame(26.67, 329.14 + 7 * 48, 358.1, 48).center
        #expect(backend.session.calls == [.perform(.tapAt(x: row.x, y: row.y))])
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

    /// The captured iOS Expo menu with a button of the app's listed before it, in the app's own branch of the tree.
    static func menu(withAppButton label: String, frame: UIFrame) throws -> UITree {
        var menu = try Self.captured("devmenu-expo-ios")
        menu.roots[0].children[0].children.insert(FakeUI.node(.button, id: "app-button", label: label, frame: frame), at: 0)
        return menu
    }

    static let iosDevice = DeviceID(rawValue: "IOS-UDID", platform: .ios)

    /// What the Expo sheet's dimmed area above it answers a hit-test with; the tree does not list it.
    static let dismissArea = FakeUI.node(.button, label: "Activate to dismiss pop-up window.", frame: FakeUI.frame(0, 0, 402, 373))

    @Test("an app button with an item's label is never tapped, wherever it sits behind the menu: the menu's own is, with no hit-test", arguments: [
        FakeUI.frame(16, 120, 370, 44), FakeUI.frame(16, 480, 370, 44),
    ])
    func menusOwnItemOverAppButton(frame: UIFrame) async throws {
        let menu = try Self.menu(withAppButton: "Reload", frame: frame)
        let backend = HitTestingFakeBackend(platform: .ios, trees: [menu, Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["reload", "--device", Self.iosDevice.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .reload, label: "Reload"))
        let own = try #require(try Self.captured("devmenu-expo-ios").roots[0].flattened().first { $0.role == .button && $0.label == "Reload" }?.frame)
        #expect(backend.session.calls == [.perform(.tapAt(x: own.center.x, y: own.center.y))])
        #expect(backend.hitTests == 0)
    }

    @Test("--label naming only a row of the app behind the menu is no item of the menu: nothing is tapped, whatever the hit-test answers", arguments: [
        (FakeUI.frame(16, 156, 370, 57), Self.dismissArea),
        (FakeUI.frame(16, 480, 370, 44), FakeUI.node(.group, frame: FakeUI.frame(8, 385, 386, 481))),
        (FakeUI.frame(16, 764, 370, 57), FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874))),
    ])
    func appRowIsNoItem(frame: UIFrame, hit: UINode) async throws {
        let backend = HitTestingFakeBackend(platform: .ios, trees: [try Self.menu(withAppButton: "Tap Test", frame: frame)])
        backend.hits = { _ in hit }

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--label", "Tap Test", "--device", Self.iosDevice.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .selectorNotFound)
        #expect(error?.userFacingDescription.hasPrefix("The expo dev menu has no --label 'Tap Test'.") == true)
        #expect(backend.session.calls.isEmpty)
        #expect(backend.hitTests == 1)
    }

    @Test("--label naming only an app row off screen behind the menu is no item either, so no swipe is suggested")
    func offScreenAppRowIsNoItem() async throws {
        let backend = HitTestingFakeBackend(platform: .ios, trees: [try Self.menu(withAppButton: "Key Press", frame: FakeUI.frame(16, 1000, 370, 57))])

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--label", "Key Press", "--device", Self.iosDevice.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .selectorNotFound)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("close with no xmark taps the menu's Close, listed before its Reload, not an app's item labelled Dismiss after it")
    func closeBeforeReload() async throws {
        let close = FakeUI.node(.button, label: "Close", frame: FakeUI.frame(350, 250, 36, 36), platform: .android)
        var menu = Self.expoMenu()
        menu.roots[0].children.removeAll { $0.label == "Close" }
        menu.roots[0].children.insert(close, at: 0)
        menu.roots[0].children.append(FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(16, 560, 370, 48), platform: .android))
        let backend = FakeDeviceBackend(platform: .android, trees: [menu, Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["close", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: .close, label: "Close"))
        #expect(backend.session.calls == [.perform(.tapAt(x: 368, y: 268))])
    }

    @Test("Close, listed before the menu's Reload, is still tapped when the hit-test answers with it, and a button of the app with its label is not")
    func closeByLabelOverAppButton() async throws {
        let menu = try Self.menu(withAppButton: "Close", frame: FakeUI.frame(16, 120, 370, 44))
        let close = try #require(menu.roots[0].flattened().last { $0.id == "xmark" })
        let backend = HitTestingFakeBackend(platform: .ios, trees: [menu, Self.app], advanceTreeOnInput: true)
        backend.hits = { point in close.frame?.contains(point) == true ? close : Self.dismissArea }

        let outcome = try await RNDevMenu.parse(["--label", "Close", "--device", Self.iosDevice.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)

        let frame = try #require(close.frame)
        #expect(outcome == .chose(menu: "expo", item: nil, label: "Close"))
        #expect(backend.session.calls == [.perform(.tapAt(x: frame.center.x, y: frame.center.y))])
    }

    @Test("Continue on Expo's first-run sheet, drawn after the menu, is tapped whatever a hit-test would answer, as it needs none")
    func onboardingContinue() async throws {
        var menu = try Self.captured("devmenu-expo-ios")
        let continueButton = FakeUI.node(.button, label: "Continue", frame: FakeUI.frame(23, 776, 355, 44))
        menu.roots[0].children.append(continueButton)
        let backend = HitTestingFakeBackend(platform: .ios, trees: [menu, menu, Self.app], advanceTreeOnInput: true)
        backend.hits = { _ in FakeUI.node(.button, label: "Toggle element inspector", frame: FakeUI.frame(23, 682, 355, 54)) }

        let outcome = try await RNDevMenu.parse(["--label", "Continue", "--device", Self.iosDevice.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: nil, label: "Continue"))
        #expect(backend.session.calls.first == .perform(.tapAt(x: 200.5, y: 798)))
        #expect(backend.hitTests == 0)
    }

    @Test("--label on a section heading says the tap did nothing and leaves the menu open, rather than closing it and reporting a choice")
    func headingDoesNothing() async throws {
        let menu = try Self.captured("devmenu-expo-ios")
        let backend = FakeDeviceBackend(platform: .ios, trees: [menu])

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--label", "TOOLS", "--device", Self.iosDevice.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .notVerified)
        #expect(error?.reason.exitCode == .unverified)
        #expect(error?.userFacingDescription.hasPrefix("Tapped \"TOOLS\", but nothing happened: it is not a control in the expo dev menu, which is still open.") == true)
        #expect(backend.session.calls.count == 1, "the heading's tap, and no Close")
    }

    @Test("a heading under the menu's scroll bar presses nothing, as a scroll bar is no control")
    func headingUnderScrollBar() {
        let frame = FakeUI.frame(16, 675, 370, 20)
        let heading = FakeUI.node(.text, label: "SYSTEM", frame: frame)
        let bar = FakeUI.node(.slider, label: "Horizontal scroll bar, 1 page", frame: FakeUI.frame(0, 670, 402, 30))
        let scroller = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 300, 402, 400), children: [heading, bar])
        let menu = FakeUI.tree(platform: .ios, Self.expoMenu(platform: .ios).roots[0].children + [scroller])

        #expect(DevMenu.pressesNothing(heading, at: frame.center, in: menu))
    }

    /// The Expo menu with `label` as plain text at `frame`, over `control` when one is given.
    static func expoMenu(text label: String, frame: UIFrame, over control: UINode? = nil) -> UITree {
        FakeUI.tree(platform: .ios, Self.expoMenu(platform: .ios).roots[0].children + [control].compactMap { $0 } + [FakeUI.node(.text, label: label, frame: frame)])
    }

    @Test("plain text on a control, or text whose tap changed the menu, may have done something, so the menu still closes as before")
    func textThatMayHaveActed() async throws {
        let frame = FakeUI.frame(16, 560, 370, 48)
        let onControl = Self.expoMenu(text: "Copy", frame: frame, over: FakeUI.node(.button, label: "Copy system info", frame: frame))
        let changing = Self.expoMenu(text: "SYSTEM", frame: frame)
        var changed = changing
        changed.roots[0].children[0].frame = FakeUI.frame(16, 310, 370, 48)
        for (label, trees) in [("Copy", [onControl, onControl, Self.app]), ("SYSTEM", [changing, changed, Self.app])] {
            let backend = FakeDeviceBackend(platform: .ios, trees: trees, advanceTreeOnInput: true)

            let outcome = try await RNDevMenu.parse(["--label", label, "--device", Self.iosDevice.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.iosDevice), clock: ScriptedClock().poll)

            #expect(outcome == .chose(menu: "expo", item: nil, label: label))
            #expect(backend.session.calls.count == 2, "the text's tap, then Close")
        }
    }

    @Test("perf-monitor on Android stops with person_required before anything is sent when the app may not draw over other apps", arguments: [
        ["perf-monitor"], ["--label", "Toggle Performance Monitor"],
    ])
    func perfMonitorNeedsOverlay(arguments: [String]) async throws {
        let backend = OverlayFakeBackend(platform: .android, trees: [Self.expoMenu(), Self.app])
        backend.foregrounds = [ForegroundActivities(top: "com.example.app/.MainActivity", home: nil)]
        backend.overlayAllowed = false

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(arguments + ["--device", Self.device.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .personRequired)
        #expect(error?.userFacingDescription.contains("com.example.app may not display over other apps") == true)
        #expect(error?.userFacingDescription.contains("Display over other apps") == true)
        #expect(backend.overlayChecks == ["com.example.app"])
        #expect(backend.session.calls.isEmpty)
        #expect(backend.treeReads == 1)
    }

    @Test("perf-monitor goes ahead when the app may draw over other apps or the device does not say, and other items never ask", arguments: [
        (["perf-monitor"], Bool?.some(true), 1),
        (["perf-monitor"], Bool?.none, 1),
        (["reload"], Bool?.some(false), 0),
    ])
    func perfMonitorAllowed(arguments: [String], allowed: Bool?, checks: Int) async throws {
        let backend = OverlayFakeBackend(platform: .android, trees: [Self.expoMenu(), Self.app], advanceTreeOnInput: true)
        backend.foregrounds = [ForegroundActivities(top: "com.example.app/.MainActivity", home: nil)]
        backend.overlayAllowed = allowed

        _ = try await RNDevMenu.parse(arguments + ["--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(backend.overlayChecks.count == checks)
        #expect(!backend.session.calls.isEmpty)
    }

    @Test("fast-refresh holds its switch rather than tapping it, since the Expo switch ignores a quick tap, and counts the hold as sent")
    func fastRefreshHoldsSwitch() async throws {
        let menu = try Self.captured("devmenu-expo-ios")
        let device = DeviceID(rawValue: "IOS-UDID", platform: .ios)
        let backend = FakeDeviceBackend(platform: .ios, trees: [menu, Self.app])
        let command = try RNDevMenu.parse(["fast-refresh", "--device", device.rawValue])
        let tracker = DispatchTracker()

        _ = try await DispatchTracker.$current.withValue(tracker) {
            try await command.perform(on: DeviceRouter.Route(backend: backend, device: device), clock: ScriptedClock().poll)
        }

        #expect(backend.session.calls.isEmpty)
        #expect(tracker.state == .yes)
        let steps = try #require(backend.detachedTouches.first)
        #expect(steps.count == 3)
        #expect(steps.contains(.hold(DevMenuDriver.switchHold)))
    }

    @Test(
        "an item past the fold of the captured iOS Expo menu gets no tap, so Close never passes for a choice, and the hint swipes the menu up from a spot clear of its switches",
        arguments: ["Open React Native dev menu", "Tools button"]
    )
    func offScreenItem(label: String) async throws {
        let menu = try Self.captured("devmenu-expo-ios")
        let device = DeviceID(rawValue: "IOS-UDID", platform: .ios)
        let backend = FakeDeviceBackend(platform: .ios, trees: [menu, menu, Self.app], advanceTreeOnInput: true)

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--label", label, "--device", device.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .targetOffScreen)
        #expect(error?.reason.exitCode == .selectorNotFound)
        #expect(error?.userFacingDescription.hasPrefix("\"\(label)\" is off screen, below the fold of the expo dev menu, so nothing was tapped.") == true)
        #expect(backend.session.calls.isEmpty && backend.detachedTouches.isEmpty)
        let hint = try #require(error?.hint)
        #expect(hint.hasPrefix("offsider swipe ") && hint.hasSuffix("--device IOS-UDID"))
        let swipe = try Swipe.parse(hint.split(separator: " ").dropFirst(2).map(String.init))
        let menuScrollView = 452.5...866.0
        #expect(swipe.startY > swipe.endY && menuScrollView.contains(swipe.startY) && menuScrollView.contains(swipe.endY))
        let start = UIPoint(x: swipe.startX, y: swipe.startY)
        #expect(!menu.roots.flatMap { $0.flattened() }.contains { $0.role == .switch && $0.frame?.contains(start) == true })
    }

    /// An Expo menu whose scroll view shows y 300 to 700, holding a Clear storage button at `clearStorageY`.
    static func scrolledMenu(clearStorageY: Double) -> UITree {
        let rows = ["Reload", "Go home", "Toggle performance monitor"].enumerated().map { index, label in
            FakeUI.node(.button, label: label, frame: FakeUI.frame(16, 320 + Double(index) * 60, 370, 48), platform: .android)
        }
        let extra = FakeUI.node(.button, label: "Clear storage", frame: FakeUI.frame(16, clearStorageY, 370, 48), platform: .android)
        return FakeUI.tree(platform: .android, [FakeUI.node(.scrollView, frame: FakeUI.frame(0, 300, 402, 400), platform: .android, children: rows + [extra])])
    }

    @Test("an item above the top of the menu's scroll view gets no tap, and the hint swipes the menu down")
    func itemAboveScrollView() async throws {
        let menu = Self.scrolledMenu(clearStorageY: 240)
        let backend = FakeDeviceBackend(platform: .android, trees: [menu, menu, Self.app], advanceTreeOnInput: true)

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--label", "Clear storage", "--device", Self.device.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .targetOffScreen)
        #expect(error?.userFacingDescription.contains("above the top of the expo dev menu") == true)
        #expect(error?.userFacingDescription.contains("Swipe the menu down") == true)
        let swipe = try Swipe.parse(try #require(error?.hint).split(separator: " ").dropFirst(2).map(String.init))
        #expect(swipe.startY < swipe.endY && (300...700).contains(swipe.startY) && (300...700).contains(swipe.endY))
        #expect(backend.session.calls.isEmpty)
    }

    @Test("an item the menu's scroll view cuts off is tapped on the part that shows, not past the edge")
    func clippedItemTappedWhereItShows() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.scrolledMenu(clearStorageY: 680), Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["--label", "Clear storage", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "expo", item: nil, label: "Clear storage"))
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 690))])
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

    @Test("close on React Native's own menu on Android, which has no close control, presses Back and checks the menu went")
    func closeReactNativeMenuWithBack() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [try Self.capture("devmenu-rn-android"), Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["close", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "react-native", item: .close, label: "Back"))
        #expect(backend.session.calls == [.perform(.shortButtonPress(.back))])
    }

    @Test("a React Native menu that Back leaves open is not verified, after exactly one Back")
    func backLeavesMenuOpen() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [try Self.capture("devmenu-rn-android")], advanceTreeOnInput: true)

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["close", "--device", Self.device.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .notVerified)
        #expect(backend.session.calls == [.perform(.shortButtonPress(.back))])
    }

    @Test("a React Native menu a toggle left open closes with Back, and one the toggle closed gets no Back")
    func toggleLeavesReactNativeMenuOpen() async throws {
        let menu = try Self.capture("devmenu-rn-android")
        let toggle = try #require(DevMenu.node(for: .inspector, label: nil, in: menu)?.frame?.center)
        let stillOpen = FakeDeviceBackend(platform: .android, trees: [menu, menu, Self.app], advanceTreeOnInput: true)

        let outcome = try await RNDevMenu.parse(["inspector", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: stillOpen, device: Self.device), clock: ScriptedClock().poll)

        #expect(outcome == .chose(menu: "react-native", item: .inspector, label: "Toggle Element Inspector"))
        #expect(stillOpen.session.calls == [.perform(.tapAt(x: toggle.x, y: toggle.y)), .perform(.shortButtonPress(.back))])

        let gone = FakeDeviceBackend(platform: .android, trees: [menu, Self.app], advanceTreeOnInput: true)
        _ = try await RNDevMenu.parse(["inspector", "--device", Self.device.rawValue])
            .perform(on: DeviceRouter.Route(backend: gone, device: Self.device), clock: ScriptedClock().poll)
        #expect(gone.session.calls == [.perform(.tapAt(x: toggle.x, y: toggle.y))])
    }

    /// An app screen whose notes field holds focus, as while typing.
    static let focusedField = FakeUI.tree(platform: .android, [
        FakeUI.node(.textField, id: "notes-field", label: "Notes", frame: FakeUI.frame(16, 200, 370, 44), state: UIState(focused: true), platform: .android),
    ])

    @Test("on Android an item React Native's menu lacks says a focused field can send the menu key there, and lists that menu's items")
    func reactNativeMenuLacksItem() async throws {
        let menu = try Self.capture("devmenu-rn-android")
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.focusedField, menu], advanceTreeOnInput: true)

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--label", "Clear Cache", "--device", Self.device.rawValue])
                .perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .selectorNotFound)
        #expect(error?.userFacingDescription.contains("while a text field has focus: move focus out of the field, or open Expo's menu with its Tools button") == true)
        #expect(error?.candidates.map(\.label) == DevMenu.read(menu)?.items.map(\.label))
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu))])
    }

    @Test("on Android a menu key that opens nothing while a text field has focus names the field as the likely cause")
    func focusedFieldOpensNothing() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.focusedField])

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--device", Self.device.rawValue]).perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .stateNotReached)
        #expect(error?.userFacingDescription.contains("A text field has focus") == true)
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu))])
    }

    @Test("an item the menu lacks is exit 2 with the menu's items as candidates, each marked on screen or not")
    func absentItem() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.expoMenu(below: "Fast Refresh")])
        let command = try RNDevMenu.parse(["debugger", "--device", Self.device.rawValue])
        let error = await #expect(throws: CLIError.self) {
            _ = try await command.perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .selectorNotFound)
        #expect(error?.candidates.map(\.label) == ["Reload", "Go home", "Toggle performance monitor", "Toggle element inspector", "Fast Refresh", "Close"])
        #expect(error?.candidates.map(\.onScreen) == [true, true, true, true, false, true])
        #expect(error?.userFacingDescription.contains("text field") == false)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a menu that never opens is state_not_reached, as in a Release build")
    func neverOpens() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.app])
        let error = await #expect(throws: CLIError.self) {
            _ = try await RNDevMenu.parse(["--device", Self.device.rawValue]).perform(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }
        #expect(error?.reason == .stateNotReached)
        #expect(error?.userFacingDescription.hasSuffix("Release builds have none; check this is a debug build.") == true)
    }

    @Test("tools off turns off a showing performance monitor through the menu and leaves the inspector alone")
    func toolsOff() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.perfShowing(), Self.expoMenu(), Self.app], advanceTreeOnInput: true)
        let result = try await RNToolsOff.parse(["--device", Self.device.rawValue]).turnOff(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)

        #expect(result == (inspector: "off", perfMonitor: "turned-off"))
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu)), .perform(.tapAt(x: 201, y: 424))])
        #expect(DevMenu.toolsJSONLine(inspector: "off", perfMonitor: "turned-off") == #"{"version":1,"inspector":"off","perfMonitor":"turned-off"}"#)
    }

    @Test("tools off stops with target_off_screen when the performance monitor's item is below the fold, after only the menu key")
    func toolsOffItemOffScreen() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.perfShowing(), Self.expoMenu(below: "Toggle performance monitor"), Self.app], advanceTreeOnInput: true)

        let error = await #expect(throws: CLIError.self) {
            _ = try await RNToolsOff.parse(["--device", Self.device.rawValue]).turnOff(on: DeviceRouter.Route(backend: backend, device: Self.device), clock: ScriptedClock().poll)
        }

        #expect(error?.reason == .targetOffScreen)
        #expect(error?.userFacingDescription.contains("then choose it again with `rn devmenu`, which uses the menu that is already open") == true)
        #expect(backend.session.calls == [.perform(.shortButtonPress(.menu))])
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

/// Answers whether the app in front may draw over other apps.
@MainActor
private final class OverlayFakeBackend: FakeDeviceBackend, OverlayPermissionReading {
    var overlayAllowed: Bool?
    private(set) var overlayChecks: [String] = []

    func canDrawOverlays(_ package: String, on id: DeviceID) async throws -> Bool? {
        overlayChecks.append(package)
        return overlayAllowed
    }
}
