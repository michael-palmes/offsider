import Foundation
import OffsiderCore
import Testing
@testable import OffsiderIOSDevice

/// `alert` on an iPhone through the runner's `/alert` and `/alert-tap`. The alert is shaped as the runner sent it on an iPhone running iOS 27, with the playground's names.
@Suite("alert on an iPhone or iPad")
@MainActor
struct IOSDeviceAlertTests {
    static let phone = RunnerClientTests.phone
    static let app = "com.mpalmes.offsider.playground"
    static let title = "Allow “Playground” to access your camera?"

    static func button(_ label: String, id: String, x: Double) -> [String: Any] {
        let frame: [String: Any] = ["x": x, "y": 556, "width": 140, "height": 48]
        // iOS lists each alert button inside a button of the same label and frame.
        return ["type": "Button", "AXLabel": label, "AXUniqueId": id, "frame": frame, "children": [["type": "Button", "AXLabel": label, "AXUniqueId": id, "frame": frame, "children": []]]]
    }

    static func alert(title: String = title, service: String = "kTCCServiceCamera") -> [String: Any] {
        [
            "type": "Alert", "AXLabel": title, "AXUniqueId": "\(service)-alert", "frame": ["x": 55, "y": 337, "width": 320, "height": 283],
            "children": [
                ["type": "StaticText", "AXLabel": title, "frame": ["x": 85, "y": 448, "width": 260, "height": 42], "children": []],
                ["type": "StaticText", "AXLabel": "Raises the prompt for a test.", "frame": ["x": 85, "y": 498, "width": 260, "height": 38], "children": []],
                button("Don’t Allow", id: "\(service)-deny-button", x: 71),
                button("Allow", id: "\(service)-allow-button", x: 219),
            ],
        ]
    }

    /// A test device's backend with the alert up over the playground, whose display name is `Playground`.
    static func backend(alert: [String: Any]? = nil, noAlert: Bool = false, testDevice: Bool = true) throws -> (IOSDeviceBackend, FakeRunnerTransport) {
        let alert = noAlert ? nil : alert ?? Self.alert()
        let transport = FakeRunnerTransport()
        transport.alert = alert
        transport.promptOverApp = alert?["AXLabel"] as? String
        var host = IOSDeviceHost.fake(try FakeDevicectl.listing("devicectl-list-xcode26.json"), usbmux: FakeUsbmuxListing.onUSB(phone.rawValue))
        host.runnerConnector = FakeRunnerConnector(transport: transport)
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        backend.input.coreDeviceVersion = { CoreDeviceVersion("518.24") }
        backend.pinPolicy = { _ in nil }
        backend.drivesWhole = testDevice
        backend.state.awakeChecked.insert(phone.rawValue)
        backend.state.appNames["\(phone.rawValue) \(app)"] = "Playground"
        return (backend, transport)
    }

    static func paths(_ transport: FakeRunnerTransport) -> [String] {
        transport.calls.map(\.path).filter { $0 != "/ping" }
    }

    @Test("the runner's alert is read as a prompt for the app beneath it, by its ids, and the app itself is never read")
    func readsTheAlert() async throws {
        let (backend, transport) = try Self.backend()
        let read = try await backend.appPrompt(for: Self.app, on: Self.phone)
        #expect(read.prompt.title == Self.title)
        #expect(read.prompt.message == "Raises the prompt for a test.")
        #expect(read.prompt.buttons.map(\.label) == ["Don’t Allow", "Allow"])
        #expect(read.prompt.buttons.map(\.role) == [.deny, .accept])
        #expect(read.prompt.source == "SpringBoard")
        #expect(Self.paths(transport) == ["/alert"])
        #expect(transport.calls.last?.body["app"] == AnyHashable(Self.app))
    }

    @Test("a device not driven whole is refused before the runner is asked anything")
    func personalPhone() async throws {
        let (backend, transport) = try Self.backend(testDevice: false)
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await backend.appPrompt(for: Self.app, on: Self.phone) }
        #expect(error?.kind == .appNotAllowed)
        #expect(error?.message.contains("is not a test device Offsider may drive whole") == true)
        await #expect(throws: IOSDeviceError.self) {
            try await backend.answer(AlertPromptTestsSupport.prompt, with: AlertPromptTestsSupport.prompt.buttons[0], on: Self.phone)
        }
        #expect(transport.calls.isEmpty)
    }

    @Test("an alert the app is not beneath, or one over another active app, is another app's, naming it")
    func anotherApp() async throws {
        let (behind, transport) = try Self.backend()
        transport.alertAppInFront = false
        transport.alertActive = ["com.apple.springboard", "com.example.other"]
        await #expect { _ = try await behind.appPrompt(for: Self.app, on: Self.phone) } throws: { error in
            guard case .otherApp("com.example.other", let why) = error as? AppPromptRefusal else { return false }
            return why.hasPrefix("\(Self.app) is not the app beneath the alert")
        }

        let (over, other) = try Self.backend()
        other.alertActive = ["com.apple.springboard", "com.example.other", Self.app]
        await #expect { _ = try await over.appPrompt(for: Self.app, on: Self.phone) } throws: { error in
            guard case .otherApp("com.example.other", _) = error as? AppPromptRefusal else { return false }
            return true
        }
    }

    @Test("no alert is not shown, a prompt drawn by its own process is not a permission one, and a title naming another app first is refused")
    func otherRefusals() async throws {
        let (none, _) = try Self.backend(noAlert: true)
        await #expect(throws: AppPromptRefusal.notShown(front: Self.app)) { _ = try await none.appPrompt(for: Self.app, on: Self.phone) }

        let (hosted, transport) = try Self.backend()
        transport.alertHosted = "Contacts access"
        await #expect { _ = try await hosted.appPrompt(for: Self.app, on: Self.phone) } throws: { error in
            guard case .notPermission(let what) = error as? AppPromptRefusal else { return false }
            return what.hasPrefix("Contacts access")
        }

        let (renamed, _) = try Self.backend(alert: Self.alert(title: "Allow “Browser” to access your camera?"))
        await #expect { _ = try await renamed.appPrompt(for: Self.app, on: Self.phone) } throws: { error in
            guard case .otherApp = error as? AppPromptRefusal else { return false }
            return true
        }
    }

    @Test("an alert with no privacy id whose title is not a permission request reads with no button accept or deny would pick")
    func titleShape() async throws {
        var alert = Self.alert(title: "“Playground” Needs to Be Updated")
        alert["AXUniqueId"] = nil
        alert["children"] = [Self.button("Later", id: "", x: 71), Self.button("Update", id: "", x: 219)].map { node -> [String: Any] in
            var node = node
            node["AXUniqueId"] = nil
            return node
        }
        let (backend, _) = try Self.backend(alert: alert)
        let read = try await backend.appPrompt(for: Self.app, on: Self.phone)
        #expect(read.prompt.buttons.map(\.role) == [.other, .other])
    }

    @Test("answer is one runner call that names the title, the label and the frame read; a changed alert is foreground_changed")
    func answerByLabel() async throws {
        let (backend, transport) = try Self.backend()
        let prompt = try await backend.appPrompt(for: Self.app, on: Self.phone).prompt
        let allow = try prompt.button(for: .accept)
        try await backend.answer(prompt, with: allow, on: Self.phone)
        let tap = try #require(transport.calls.last)
        #expect(tap.path == "/alert-tap")
        #expect(tap.body["title"] == AnyHashable(Self.title))
        #expect(tap.body["label"] == AnyHashable("Allow"))
        #expect(tap.body["frame"] == AnyHashable(["x": 219, "y": 556, "width": 140, "height": 48] as [String: AnyHashable]))

        transport.failure = ("/alert-tap", 409, "alert_changed")
        let error = await #expect(throws: IOSDeviceError.self) { try await backend.answer(prompt, with: allow, on: Self.phone) }
        #expect(error?.kind == .promptChanged)
        #expect(error?.reason == .foregroundChanged)
    }

    @Test("on a test device held to the app, a look-only read proves the prompt and reads the alert in the app's place, named read only; input still meets the refusal")
    func readOnlyCapture() async throws {
        let (backend, transport) = try Self.backend()
        backend.selectApp(Self.app, on: Self.phone)

        let proved = try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.promptOverSelectedApp(on: Self.phone) }
        #expect(proved?.title == Self.title)
        let tree = try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.accessibilityTree(for: Self.phone) }
        #expect(tree.systemWindow == UITreeContext.Window(title: Self.title, kind: .system, package: "SpringBoard", readOnly: true))
        #expect(tree.roots.first?.children.first?.id == "kTCCServiceCamera-alert")
        #expect(!Self.paths(transport).contains("/snapshot"))
        #expect(backend.systemWindow(for: Self.phone)?.title == Self.title)

        let input = await #expect(throws: IOSDeviceError.self) { _ = try await backend.accessibilityTree(for: Self.phone) }
        #expect(input?.kind == .systemPromptOnTestDevice)
        #expect(input?.message.contains("`offsider alert show --app \(Self.app) --device \(Self.phone.rawValue)`") == true)
    }

    @Test("outside a look-only read, on a phone in personal use, or with no app named, nothing is proved and the runner is not asked")
    func nothingProved() async throws {
        let (acting, actingTransport) = try Self.backend()
        acting.selectApp(Self.app, on: Self.phone)
        #expect(try await acting.promptOverSelectedApp(on: Self.phone) == nil)

        let (personal, personalTransport) = try Self.backend(testDevice: false)
        personal.selectApp(Self.app, on: Self.phone)
        let none = try await PhoneRead.$overSystemWindow.withValue(true) { try await personal.promptOverSelectedApp(on: Self.phone) }
        #expect(none == nil)

        let (unnamed, unnamedTransport) = try Self.backend()
        let nothing = try await PhoneRead.$overSystemWindow.withValue(true) { try await unnamed.promptOverSelectedApp(on: Self.phone) }
        #expect(nothing == nil)
        for transport in [actingTransport, personalTransport, unnamedTransport] {
            #expect(!transport.calls.contains { $0.path == "/alert" })
        }
    }

    @Test("a proof is good for five seconds; after that a look-only read asks the runner for the app again")
    func proofExpires() async throws {
        let (backend, transport) = try Self.backend()
        backend.selectApp(Self.app, on: Self.phone)
        let prompt = try await backend.appPrompt(for: Self.app, on: Self.phone).prompt
        backend.state.provenPrompts[Self.phone.rawValue] = (Date().addingTimeInterval(-IOSDeviceBackend.promptReadLifetime - 1), prompt, Data("[]".utf8))
        await #expect(throws: IOSDeviceError.self) {
            _ = try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.accessibilityTree(for: Self.phone) }
        }
        #expect(transport.calls.last?.path == "/snapshot")
    }

    @Test("the bundled runner serves the alert routes, outside the routes a prompt refuses")
    func runnerServesAlertRoutes() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Offsider/Resources/runner/UITests/Commands.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains(#"static let alertRoutes: Set<String> = ["/alert", "/alert-tap"]"#))
        #expect(text.contains(#"request.path == "/alert" { return alert(body) }"#))
        #expect(text.contains(#"request.path == "/alert-tap" { return alertTap(body) }"#))
    }
}

/// A prompt for a refusal that must come before any read.
enum AlertPromptTestsSupport {
    static let prompt = AppPrompt(app: IOSDeviceAlertTests.app, title: IOSDeviceAlertTests.title, buttons: [
        AppPrompt.Button(label: "Allow", role: .accept, frame: UIFrame(x: 219, y: 556, width: 140, height: 48)),
    ], frame: UIFrame(x: 55, y: 337, width: 320, height: 283), source: "SpringBoard")
}
