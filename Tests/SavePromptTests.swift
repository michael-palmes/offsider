import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Save-password prompt")
struct SavePromptTests {
    private let app = "com.example.app"

    @Test("Android's own save dialog is found by its ids, and its decline is the only control offered")
    func androidFrameworkDialog() throws {
        let tree = androidTree([
            android(.text, id: "android:id/autofill_save_title", label: "Save password to Example?", frame: FakeUI.frame(40, 1900, 900, 60)),
            android(.button, id: "android:id/autofill_save_no", label: "Not now", frame: FakeUI.frame(500, 2100, 200, 120)),
            android(.button, id: "android:id/autofill_save_yes", label: "Save", frame: FakeUI.frame(740, 2100, 200, 120)),
        ])
        let prompt = try #require(SavePrompts.android(in: tree, app: app))
        #expect(prompt.title == "Save password to Example?")
        #expect(prompt.declineLabel == "Not now")
        #expect(prompt.decline == UIPoint(x: 600, y: 2160))
        #expect(prompt.ask == "Can you tap Not now on the \"Save password to Example?\" prompt on \(PersonAsk.devicePlaceholder)?")
    }

    @Test("a decline that would last, such as Never, is not offered: the prompt is found and nothing can be tapped")
    func lastingDeclineIsNotOffered() throws {
        let tree = androidTree([
            android(.button, id: "android:id/autofill_save_no", label: "Never", frame: FakeUI.frame(500, 2100, 200, 120)),
            android(.button, id: "android:id/autofill_save_yes", label: "Save", frame: FakeUI.frame(740, 2100, 200, 120)),
        ])
        let prompt = try #require(SavePrompts.android(in: tree, app: app))
        #expect(prompt.decline == nil)
        #expect(prompt.declineLabel == nil)
    }

    @Test("a password manager's own sheet is found by its offer, its Save button and its Not now")
    func passwordManagerSheet() throws {
        let tree = androidTree([
            android(.header, id: "sheet-title", label: "Save password?", frame: FakeUI.frame(40, 1800, 900, 60), package: "com.example.passwords"),
            android(.button, id: "never", label: "Never", frame: FakeUI.frame(40, 2100, 200, 120), package: "com.example.passwords"),
            android(.button, id: "later", label: "Not now", frame: FakeUI.frame(300, 2100, 200, 120), package: "com.example.passwords"),
            android(.button, id: "save", label: "Save", frame: FakeUI.frame(740, 2100, 200, 120), package: "com.example.passwords"),
        ])
        let prompt = try #require(SavePrompts.android(in: tree, app: app))
        #expect(prompt.decline == UIPoint(x: 400, y: 2160))
    }

    @Test("the app's own buttons are never a save prompt, whatever they say")
    func appsOwnButtons() {
        let tree = androidTree([
            android(.text, id: "offer", label: "Save your password for next time?", frame: FakeUI.frame(40, 1800, 900, 60), package: app),
            android(.button, id: "later", label: "Not now", frame: FakeUI.frame(300, 2100, 200, 120), package: app),
            android(.button, id: "save", label: "Save", frame: FakeUI.frame(740, 2100, 200, 120), package: app),
        ])
        #expect(SavePrompts.android(in: tree, app: app) == nil)
    }

    @Test("buttons that name no package are never taken for another app's prompt")
    func unnamedPackageIsNotAPrompt() {
        let nodes = [
            UINode(role: .text, label: "Save password?", frame: FakeUI.frame(40, 1800, 900, 60), native: .android(AndroidNativeAttributes())),
            UINode(role: .button, label: "Not now", frame: FakeUI.frame(300, 2100, 200, 120), enabled: true, native: .android(AndroidNativeAttributes())),
            UINode(role: .button, label: "Save", frame: FakeUI.frame(740, 2100, 200, 120), enabled: true, native: .android(AndroidNativeAttributes())),
        ]
        let tree = UITree(platform: .android, device: "emulator-5554", roots: [UINode(role: .application, frame: FakeUI.frame(0, 0, 1080, 2400), native: .android(AndroidNativeAttributes()), children: nodes)])
        #expect(SavePrompts.android(in: tree, app: app) == nil)
    }

    @Test("another package's Not now with no save offer beside it is left alone")
    func declineAloneIsNotAPrompt() {
        let tree = androidTree([
            android(.text, id: "title", label: "Turn on notifications?", frame: FakeUI.frame(40, 1800, 900, 60), package: "com.android.systemui"),
            android(.button, id: "later", label: "Not now", frame: FakeUI.frame(300, 2100, 200, 120), package: "com.android.systemui"),
            android(.button, id: "allow", label: "Allow", frame: FakeUI.frame(740, 2100, 200, 120), package: "com.android.systemui"),
        ])
        #expect(SavePrompts.android(in: tree, app: app) == nil)
    }

    @Test("only a whole decline label counts: Save, Allow, Never and a longer sentence do not", arguments: ["Save Password", "Save", "Allow", "Never", "Not now, remind me to save"])
    func onlyDeclineLabels(label: String) {
        #expect(!SavePrompts.isDecline(FakeUI.node(.button, label: label, frame: FakeUI.frame(0, 0, 100, 44))))
    }

    @Test("Not Now and No thanks decline, in any case, and a disabled or non-button one does not")
    func declineLabels() {
        #expect(SavePrompts.isDecline(FakeUI.node(.button, label: "Not Now", frame: FakeUI.frame(0, 0, 100, 44))))
        #expect(SavePrompts.isDecline(FakeUI.node(.button, label: "No thanks", frame: FakeUI.frame(0, 0, 100, 44))))
        #expect(!SavePrompts.isDecline(FakeUI.node(.button, label: "Not Now", frame: FakeUI.frame(0, 0, 100, 44), enabled: false)))
        #expect(!SavePrompts.isDecline(FakeUI.node(.text, label: "Not Now", frame: FakeUI.frame(0, 0, 100, 44))))
    }

    @Test("an iOS tree that lists the prompt gives its title and Not Now, and Not Now alone is no prompt")
    func iosPrompt() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.header, label: "Save Password?", frame: FakeUI.frame(100, 500, 200, 30)),
            FakeUI.node(.button, label: "Save Password", frame: FakeUI.frame(40, 700, 322, 50)),
            FakeUI.node(.button, label: "Not Now", frame: FakeUI.frame(40, 770, 322, 50)),
        ])
        let prompt = try #require(SavePrompts.ios(in: tree))
        #expect(prompt.decline == UIPoint(x: 201, y: 795))
        #expect(SavePrompts.ios(in: FakeUI.tree([FakeUI.node(.button, label: "Not Now", frame: FakeUI.frame(40, 770, 322, 50))])) == nil)
        #expect(SavePrompts.isIOSTitle("save password?"))
        #expect(!SavePrompts.isIOSTitle("Allow Paste?"))
    }

    @Test("a simulator's prompt is read in rows below its title, left then right then middle, closer together than a button is tall, and never off the screen")
    func probeRows() {
        let rows = SavePrompts.probeRows(below: FakeUI.frame(80, 439, 260, 20), in: FakeUI.frame(0, 0, 420, 912))
        #expect(rows.first == [UIPoint(x: 119, y: 489), UIPoint(x: 301, y: 489), UIPoint(x: 210, y: 489)])
        #expect(zip(rows, rows.dropFirst()).allSatisfy { $1[0].y - $0[0].y < 44 })
        #expect(rows.contains { row in row.contains { FakeUI.frame(66, 545, 140, 48).contains($0) } })
        let low = SavePrompts.probeRows(below: FakeUI.frame(80, 800, 260, 20), in: FakeUI.frame(0, 0, 420, 912))
        #expect(!low.isEmpty && low.allSatisfy { $0.allSatisfy { $0.y < 912 } })
    }

    @Test("a system window that is not a save prompt is asked about in plain words")
    func otherSystemWindow() {
        #expect(SavePrompt(savesPassword: false, title: nil).ask == "Can you answer a system prompt on \(PersonAsk.devicePlaceholder)?")
        #expect(SavePrompt(title: nil).ask == "Can you tap Not Now on the system's save-password prompt on \(PersonAsk.devicePlaceholder)?")
    }

    private func android(_ role: UIRole, id: String, label: String, frame: UIFrame, package: String = "android") -> UINode {
        UINode(role: role, id: id, label: label, frame: frame, enabled: true, native: .android(AndroidNativeAttributes(resourceId: id, package: package)))
    }

    private func androidTree(_ window: [UINode]) -> UITree {
        let form = UINode(role: .application, frame: FakeUI.frame(0, 0, 1080, 2400), native: .android(AndroidNativeAttributes(package: app)), children: [
            android(.secureTextField, id: "password-field", label: "Password", frame: FakeUI.frame(40, 600, 1000, 120), package: app),
        ])
        let over = UINode(role: .window, frame: FakeUI.frame(0, 1700, 1080, 700), native: .android(AndroidNativeAttributes(package: window.first.flatMap { node -> String? in
            guard case .android(let attributes) = node.native else { return nil }
            return attributes.package
        })), children: window)
        return UITree(platform: .android, device: "emulator-5554", roots: [form, over])
    }
}

@MainActor
@Suite("Login's keyboard step and its check before the Keychain", .turnstileHistory)
struct LoginKeyboardStepTests {
    @Test("the keyboard's own way out is its hide key, or a Done in the bar on top of the keys, never a Done in the form")
    func closingControl() {
        let key = FakeUI.node(.button, label: "q", frame: FakeUI.frame(3, 597, 396, 200))
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 590, 402, 284), children: [key])
        let barDone = FakeUI.node(.button, label: "Done", frame: FakeUI.frame(330, 552, 60, 36))
        let formDone = FakeUI.node(.button, label: "Done", frame: FakeUI.frame(16, 300, 370, 44))
        let hide = FakeUI.node(.button, label: "Hide keyboard", frame: FakeUI.frame(340, 820, 50, 44))

        #expect(KeyboardDismiss.closingControl(in: FakeUI.tree([formDone, keyboard])) == nil)
        #expect(KeyboardDismiss.closingControl(in: FakeUI.tree([formDone, barDone, keyboard])) == UIPoint(x: 360, y: 570))
        #expect(KeyboardDismiss.closingControl(in: FakeUI.tree([formDone, barDone, keyboard, hide])) == UIPoint(x: 365, y: 842))
        #expect(KeyboardDismiss.closingControl(in: FakeUI.tree([formDone, barDone])) == nil)
    }

    @Test("on Android Back is sent only over docked keys: a toolbar alone, or no keyboard, sends nothing")
    func androidBackOnlyOverDockedKeys() async throws {
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let docked = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 1500, 1080, 900), platform: .android, children: [
            FakeUI.node(.button, label: "q", frame: FakeUI.frame(10, 1520, 1060, 860), platform: .android),
        ])
        let toolbar = FakeUI.node(.keyboard, frame: FakeUI.frame(300, 2200, 480, 120), platform: .android, children: [
            FakeUI.node(.button, label: "Paste", frame: FakeUI.frame(310, 2210, 460, 100), platform: .android),
        ])
        for (keys, expected) in [([docked], [RecordingInputSession.Call.perform(.shortButtonPress(.back))]), ([toolbar], []), ([], [])] {
            let tree = FakeUI.tree(platform: .android, width: 1080, height: 2400, keys)
            let backend = FakeDeviceBackend(platform: .android, trees: [tree])
            try await LoginCommand.hideKeyboard(in: tree, on: DeviceRouter.Route(backend: backend, device: device))
            #expect(backend.session.calls == expected)
        }
    }

    @Test("on iOS the step taps the keyboard's own Done and nothing when there is none: it never presses Return")
    func iosTapsOnlyTheClosingControl() async throws {
        let device = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
        let keyboard = FakeUI.node(.keyboard, frame: FakeUI.frame(0, 590, 402, 284), children: [
            FakeUI.node(.button, label: "q", frame: FakeUI.frame(3, 597, 396, 200)),
            FakeUI.node(.button, label: "Return", frame: FakeUI.frame(300, 810, 96, 50)),
        ])
        let bare = FakeUI.tree([keyboard])
        let none = FakeDeviceBackend(platform: .ios, trees: [bare])
        try await LoginCommand.hideKeyboard(in: bare, on: DeviceRouter.Route(backend: none, device: device))
        #expect(none.session.calls.isEmpty)

        let withBar = FakeUI.tree([FakeUI.node(.button, label: "Done", frame: FakeUI.frame(330, 552, 60, 36)), keyboard])
        let bar = FakeDeviceBackend(platform: .ios, trees: [withBar])
        try await LoginCommand.hideKeyboard(in: withBar, on: DeviceRouter.Route(backend: bar, device: device))
        #expect(bar.session.calls == [.perform(.tapAt(x: 360, y: 570))])
    }

    @Test("an unticked Turnstile box stops login before the password is read, so no Touch ID or Keychain prompt is spent on it; with no saved login, nobody is asked to tick")
    func untickedBoxStopsBeforeTheKeychain() async throws {
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let box = UINode(
            role: .checkbox, label: "Verify you are human", frame: FakeUI.frame(40, 900, 400, 60), enabled: true,
            native: .android(AndroidNativeAttributes(package: "com.example.app"))
        )
        let widget = UINode(role: .group, id: "cf-chl-widget-abc12", frame: FakeUI.frame(40, 880, 1000, 100), native: .android(AndroidNativeAttributes(package: "com.example.app")), children: [box])
        let root = UINode(role: .application, frame: FakeUI.frame(0, 0, 1080, 2400), native: .android(AndroidNativeAttributes(package: "com.example.app")), children: [widget])
        let backend = FakeDeviceBackend(platform: .android, trees: [UITree(platform: .android, device: device.rawValue, roots: [root])])
        let store = MemoryLoginCredentialStore()
        let attempt = {
            try #require(await #expect(throws: CLIError.self) {
                _ = try await LoginCommand.perform(
                    on: DeviceRouter.Route(backend: backend, device: device), profile: nil, key: "dev", timeout: 5, logger: OffsiderLogger(), store: store,
                    recordingLive: { _ in false }
                )
            })
        }

        let missing = try await attempt()
        #expect(missing.reason == .commandFailed)
        #expect(missing.userFacingDescription.contains("No login"))

        try store.save(try #require(LoginCredential(username: "ada@example.com", password: "s3cret-token")), app: "com.example.app", key: "dev", isDefault: true)
        let error = try await attempt()
        #expect(error.reason == .turnstileRequired)
        #expect(error.userFacingDescription.contains("Nothing was typed."))
        #expect(store.decrypts == 0)
        #expect(backend.session.calls.isEmpty)
    }
}
