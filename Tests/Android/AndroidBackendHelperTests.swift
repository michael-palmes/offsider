import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android backend with the helper")
@MainActor
struct AndroidBackendHelperTests {
    static let device = HelperRig.device

    @Test("describe-ui makes one server check, one start shell, one socket (hello and dump, then quit on close) and one display status shell")
    func describeUISequence() async throws {
        let rig = try HelperRig()
        try await rig.backend.prepare()
        let tree = try await rig.read()
        let info = try await rig.backend.screenInfo(for: Self.device)
        _ = try await rig.backend.deviceCoordinates(for: [(x: 10, y: 10)], tree: tree, on: Self.device)

        #expect(rig.server.services == [
            "host:version",
            "host:transport:emulator-5556", "shell,v2,raw:" + HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil),
            "host:transport:emulator-5556", "localabstract:offsider-fake-1",
            "host:transport:emulator-5556", "shell,v2,raw:" + AndroidDisplayStatus.script,
        ])
        #expect(rig.device.ops == ["hello", "dump"])
        #expect(info == UIScreenInfo(width: 411.43, height: 923.43, scale: 2.625, rotation: .portrait, rotationDegrees: 0))
        #expect(tree.roots.map(\.label) == ["OffsiderPlaygroundRN"])
        #expect(tree.roots.first?.children.map(\.id) == ["BackButton", "tap-count"])

        await rig.backend.close()

        #expect(rig.device.ops == ["hello", "dump", "quit"])
        #expect(rig.server.services.count == 7)
        #expect(rig.device.kills.isEmpty)
    }

    @Test("type --replace makes one server check, one start shell and one socket: hello and setText, then quit, and no display probe")
    func replaceSequence() async throws {
        let rig = try AndroidReplaceTextTests.rig()
        try await AndroidReplaceTextTests.replace("abc", on: rig)
        await rig.backend.close()

        #expect(rig.server.services == [
            "host:version",
            "host:transport:emulator-5556", "shell,v2,raw:" + HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil),
            "host:transport:emulator-5556", "localabstract:offsider-fake-1",
        ])
        #expect(rig.device.ops == ["hello", "setText", "quit"])
    }

    @Test("type --replace with a trailing newline takes the display from the helper and presses Return through it, with no probe or shell")
    func replaceSubmitSequence() async throws {
        let rig = try AndroidReplaceTextTests.rig()
        try await AndroidReplaceTextTests.replace("abc\n", on: rig)
        await rig.backend.close()

        #expect(rig.server.services == [
            "host:version",
            "host:transport:emulator-5556", "shell,v2,raw:" + HelperLauncher.startScript(FakeHelperDevice.dex, pushedFrom: nil),
            "host:transport:emulator-5556", "localabstract:offsider-fake-1",
        ])
        #expect(rig.device.ops == ["hello", "setText", "display", "inject", "quit"])
    }

    @Test("tap --id reads the tree, then taps through the same helper: hello, dump, inject, quit")
    func tapAfterReadSequence() async throws {
        let rig = try HelperRig()
        _ = try await rig.read()
        let session = try await rig.backend.openInputSession(for: Self.device)
        try await session.perform(.tapAt(x: 100, y: 200))
        await session.close()
        await rig.backend.close()

        #expect(rig.device.ops == ["hello", "dump", "inject", "quit"])
        #expect(rig.device.injected == ["tap 100 200"])
        #expect(rig.startShells == 1)
        #expect(!rig.server.services.contains { $0.hasPrefix("shell,v2,raw:input ") })
    }

    @Test("later reads in the command reuse the same helper")
    func reuse() async throws {
        let rig = try HelperRig()
        _ = try await rig.read()
        _ = try await rig.read()
        _ = try await rig.backend.accessibilityTree(for: Self.device, point: UIPoint(x: 20, y: 70))

        #expect(rig.startShells == 1)
        #expect(rig.device.ops == ["hello", "dump", "dump", "dump"])
        await rig.backend.close()
    }

    @Test("with a point, the deepest node there across the roots is the only root")
    func point() async throws {
        let rig = try HelperRig()
        let tree = try await rig.backend.accessibilityTree(for: Self.device, point: UIPoint(x: 20, y: 70))
        #expect(tree.roots.map(\.id) == ["BackButton"])
        await rig.backend.close()
    }

    nonisolated static let noWindowDump = #"{"generation":1,"idle":true,\#(FakeHelperDevice.display),"windows":[\#(FakeHelperDevice.statusBar),{"id":1,"type":"application","layer":0,"title":"X","bounds":[0,0,1080,2424],"active":true,"focused":true,"root":null}],"truncated":false,"eventSeq":1}"#

    @Test("a dump with no window is read once more after 500 ms, then reported as transient so polling callers retry")
    func noWindow() async throws {
        let device = FakeHelperDevice()
        device.dump = Self.noWindowDump
        let rig = try HelperRig(device)

        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.kind == .noWindow)
        #expect(error?.message == "Offsider found no window on emulator-5556. Unlock the emulator and bring an app to the front.")
        #expect(error?.isTransientFailure == true)
        #expect(rig.device.ops.filter { $0 == "dump" }.count == 2)
        #expect(rig.sleeps.sleeps == [.milliseconds(500)])
        await rig.backend.close()
    }

    @Test("a window that appears by the second read gives the tree")
    func noWindowThenTree() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, json in op == "dump" && json.contains(#""id":2"#) ? .ok(Self.noWindowDump) : nil }
        let rig = try HelperRig(device)

        let tree = try await rig.read()

        #expect(tree.roots.first?.children.first?.id == "BackButton")
        await rig.backend.close()
    }

    static let busy = FakeHelperDevice.Start.exit(status: 4, stdout: HelperLauncherTests.busyJSON + "\n")

    @Test("busy with an Offsider helper that stays past 2 s names its pid and how to stop it, and kills nothing")
    func busyStaleHelper() async throws {
        let device = FakeHelperDevice(starts: [Self.busy])
        device.pidof = { _ in "4242\n" }
        let rig = try HelperRig(device)

        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.message == "An earlier Offsider helper (pid 4242) still holds UiAutomation on emulator-5556. It exits within 10 s of losing its command; to free it now, run `adb -s emulator-5556 shell kill 4242`.")
        #expect(rig.sleeps.total == .seconds(2))
        #expect(rig.device.kills.isEmpty)
        #expect(rig.startShells == 1)
    }

    @Test("busy with an Offsider helper that leaves within 2 s starts again once and reads the screen")
    func busyHelperLeaves() async throws {
        let device = FakeHelperDevice(starts: [Self.busy, .ready])
        device.pidof = { call in call == 1 ? "4242\n" : "" }
        let rig = try HelperRig(device)

        let tree = try await rig.read()

        #expect(tree.roots.first?.label == "OffsiderPlaygroundRN")
        #expect(rig.startShells == 2)
        #expect(rig.sleeps.sleeps == [.milliseconds(250)])
        await rig.backend.close()
    }

    @Test("busy with no Offsider helper running blames another UiAutomation client at once")
    func busyOtherTool() async throws {
        let rig = try HelperRig(FakeHelperDevice(starts: [Self.busy]))
        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.message == "Another UiAutomation client is connected to emulator-5556 (Appium, Maestro, uiautomator, an instrumentation test or Layout Inspector), so Offsider cannot read its screen. Stop that client, then retry.")
        #expect(rig.sleeps.sleeps.isEmpty)
    }

    @Test("a truncated dump warns once per command")
    func truncated() async throws {
        let device = FakeHelperDevice()
        device.dump = FakeHelperDevice.tapTestDump.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":true"#)
        let rig = try HelperRig(device)
        _ = try await rig.read()
        _ = try await rig.read()

        #expect(rig.log.warnings == ["The screen on emulator-5556 has more than 20,000 accessibility nodes; describe-ui shows the first 20,000."])
        await rig.backend.close()
    }

    @Test("a resized display reported by the helper keeps input on adb, as the probe's override does")
    func resizedDisplay() async throws {
        let device = FakeHelperDevice()
        device.dump = FakeHelperDevice.tapTestDump.replacingOccurrences(of: #""logicalWidthPx":1080,"logicalHeightPx":2424"#, with: #""logicalWidthPx":720,"logicalHeightPx":1616"#)
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        let emulator = FakeEmulator()
        let rig = try HelperRig(device, emulator: FakeEmulatorConnector(.success(emulator)), home: home)
        _ = try await rig.read()

        try await rig.backend.perform(.tapAt(x: 10, y: 20), on: Self.device)

        #expect(!emulator.calls.contains { if case .touch = $0 { return true } else { return false } })
        #expect(rig.log.warnings.contains("The display of emulator-5556 is resized (`wm size` reports an override), so its input goes over adb in this command."))
        #expect(!rig.server.services.contains { $0.hasSuffix(AndroidDisplayGeometry.probeScript) })
        await rig.backend.close()
    }

    // MARK: Secrets, pastes and the phone deny-list

    static func inputScripts(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix("shell,v2,raw:input ") }.map { String($0.dropFirst("shell,v2,raw:".count)) }
    }

    @Test("a password on an adb route goes through the helper as key events, never as an input text argument")
    func secretThroughHelper() async throws {
        let rig = try HelperRig()
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
        try await InputSecrecy.$isSecret.withValue(true) { try await session.typeText("hunter2") }
        await session.close()

        #expect(rig.device.injected == ["text hunter2"])
        #expect(Self.inputScripts(rig.server).isEmpty)
        #expect(!rig.server.services.contains { $0.contains("hunter2") })
    }

    @Test("a password with OFFSIDER_ANDROID_INPUT=input or forced uiautomator is helper_unavailable, with nothing typed", arguments: [
        ["OFFSIDER_ANDROID_INPUT": "input"], ["OFFSIDER_ANDROID_TREE": "uiautomator"],
    ])
    func secretWithoutHelper(environment: [String: String]) async throws {
        let rig = try HelperRig(environment: environment)
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
        let error = await #expect(throws: AndroidError.self) {
            try await InputSecrecy.$isSecret.withValue(true) { try await session.typeText("hunter2") }
        }
        await session.close()

        #expect(error?.reason == .helperUnavailable)
        #expect(error?.message.contains("Nothing was typed") == true)
        #expect(rig.device.injected.isEmpty)
        #expect(Self.inputScripts(rig.server).isEmpty)
    }

    @Test("ordinary text into a focused password field on an adb route also goes through the helper")
    func focusedPasswordThroughHelper() async throws {
        let device = FakeHelperDevice()
        device.dump = AndroidReplaceTextTests.fieldDump(text: "", password: true)
        let rig = try HelperRig(device)
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
        try await session.typeText("abc")
        await session.close()

        #expect(rig.device.injected == ["text abc"])
        #expect(Self.inputScripts(rig.server).isEmpty)
    }

    @Test("ordinary text into an ordinary field on an adb route is still typed with input text")
    func plainTextThroughInput() async throws {
        let device = FakeHelperDevice()
        device.dump = AndroidReplaceTextTests.fieldDump(text: "")
        let rig = try HelperRig(device, environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
        try await session.typeText("abc")
        await session.close()

        #expect(Self.inputScripts(rig.server) == ["input text 'abc'"])
    }

    @Test("non-ASCII text with the helper running is appended with setText, never through a clipboard")
    func nonASCIIThroughSetText() async throws {
        let device = FakeHelperDevice()
        device.dump = AndroidReplaceTextTests.fieldDump(text: "ab")
        device.answer = { _, op, _ in op == "setText" ? .ok(#"{"className":"android.widget.EditText","resourceId":"amount","length":4}"#) : nil }
        let rig = try HelperRig(device)
        _ = try await rig.read()
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
        try await session.typeText("é日")
        await session.close()

        #expect(try AndroidReplaceTextTests.sentText(rig) == "abé日")
        #expect(Self.inputScripts(rig.server).isEmpty)
    }

    @Test("a paste is refused when the focused field cannot be read, before the clipboard is touched")
    func unknownFocusRefusesPaste() async throws {
        let rig = try AndroidGrpcInputTests.rig(emulator: FakeEmulator(clipboard: "saved"), environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        let session = try #require(try await rig.backend.openInputSession(for: AndroidGrpcTextTests.device) as? any TextInputSession)
        let error = await #expect(throws: AndroidError.self) { try await session.typeText("héllo") }

        #expect(error?.kind == .securePasteRefused)
        #expect(error?.message.hasPrefix("Offsider could not confirm the focused field on emulator-5556 is not a password field") == true)
        #expect(rig.emulator.calls.isEmpty)
    }

    @Test("a password is never pasted through the clipboard, even into a plain field")
    func secretNeverPasted() async throws {
        let plain = AndroidSecureTextTests.passwordNode(text: "", focused: true).replacingOccurrences(of: #"password="true""#, with: #"password="false""#)
        let rig = try AndroidGrpcInputTests.rig(
            emulator: FakeEmulator(clipboard: "saved"), environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"], uiautomatorDump: AndroidSecureTextTests.xml(plain)
        )
        let session = try #require(try await rig.backend.openInputSession(for: AndroidGrpcTextTests.device) as? any TextInputSession)
        let error = await #expect(throws: AndroidError.self) {
            try await InputSecrecy.$isSecret.withValue(true) { try await session.typeText("pässwörd") }
        }

        #expect(error?.kind == .securePasteRefused)
        #expect(rig.emulator.calls.isEmpty)
    }

    static let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)

    /// The foreground read on a phone showing an ordinary app, for tests about something else.
    nonisolated static let ordinaryForeground = FakeAdbServer.shell(
        stdout: "top=  topResumedActivity=ActivityRecord{1a2b u0 com.example.app/.MainActivity t12}\nhome=com.example.launcher/.Home\n"
    )

    static func phoneBackend(top: String?) throws -> (AndroidBackend, FakeAdbServer) {
        let server = AndroidDeviceStateTests.server(devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { command in
            guard command == AndroidForeground.readScript else { return FakeAdbServer.shell() }
            let line = top.map { "top=  topResumedActivity=ActivityRecord{1a2b u0 \($0) t12}" } ?? "top="
            return FakeAdbServer.shell(stdout: line + "\nhome=com.example.launcher/.Home\n")
        }
        return (try AndroidBackendTests.backend(server), server)
    }

    static func foregroundReads(_ server: FakeAdbServer) -> Int {
        server.services.filter { $0 == "shell,v2,raw:" + AndroidForeground.readScript }.count
    }

    @Test("on a phone, a tree read, a screenshot or input with a deny-listed app in front is app_not_allowed, and nothing else is sent", arguments: [
        "com.android.settings/.Settings", "com.android.chrome/com.google.android.apps.chrome.Main", "com.google.android.gm/.ConversationListActivityGmail",
    ])
    func phoneDenyList(top: String) async throws {
        let (backend, server) = try Self.phoneBackend(top: top)
        let treeError = await #expect(throws: AndroidError.self) { _ = try await backend.accessibilityTree(for: Self.phone, point: nil) }
        let shotError = await #expect(throws: AndroidError.self) { _ = try await backend.screenshotPNG(for: Self.phone) }
        let session = try await backend.openInputSession(for: Self.phone)
        let tapError = await #expect(throws: AndroidError.self) { try await session.perform(.tapAt(x: 10, y: 10)) }

        for error in [treeError, shotError, tapError] {
            #expect(error?.reason == .appNotAllowed)
            #expect(error?.message.contains("on a physical phone, so Offsider did nothing on R58M123ABC") == true)
        }
        #expect(Self.foregroundReads(server) >= 1)
        #expect(!server.services.contains { $0.contains("uiautomator") || $0.contains("screencap") || $0.contains("input ") || $0.contains("app_process") })
    }

    @Test("on a phone an unreadable front app is refused, and an emulator is never checked")
    func phoneUnknownForeground() async throws {
        let (backend, server) = try Self.phoneBackend(top: nil)
        let error = await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        #expect(error?.reason == .appNotAllowed)
        #expect(error?.message.hasPrefix("Offsider could not tell which app is in front on R58M123ABC") == true)

        try await backend.requireDrivableForeground("emulator-5556")
        #expect(Self.foregroundReads(server) == 1)
    }

    @Test("on a phone your own app passes, and checks within a second share one read")
    func phoneOwnApp() async throws {
        let (backend, server) = try Self.phoneBackend(top: "com.example.app/.MainActivity")
        try await backend.requireDrivableForeground(Self.phone.rawValue)
        try await backend.requireDrivableForeground(Self.phone.rawValue)
        #expect(Self.foregroundReads(server) == 1)
    }

    @Test("on a phone with pinned apps, a tree read, a screenshot or typed text with another app in front is app_not_allowed, naming the allow command")
    func pinnedAppsRefuseOthers() async throws {
        let (backend, server) = try Self.phoneBackend(top: "com.example.app/.MainActivity")
        backend.appScopes[Self.phone.rawValue] = AndroidAppScope(permitted: ["com.example.pinned"], managedCeiling: nil)
        let treeError = await #expect(throws: AndroidError.self) { _ = try await backend.accessibilityTree(for: Self.phone, point: nil) }
        let shotError = await #expect(throws: AndroidError.self) { _ = try await backend.screenshotPNG(for: Self.phone) }
        let session = try #require(try await backend.openInputSession(for: Self.phone) as? any TextInputSession)
        let typeError = await #expect(throws: AndroidError.self) { try await session.typeText("x") }

        for error in [treeError, shotError, typeError] {
            #expect(error?.reason == .appNotAllowed)
            #expect(error?.message.contains("com.example.app is in front on R58M123ABC") == true)
            #expect(error?.hint == "offsider device-access allow --device R58M123ABC --app com.example.app")
        }
        #expect(!server.services.contains { $0.contains("uiautomator") || $0.contains("screencap") || $0.contains("input ") || $0.contains("app_process") })
    }

    @Test("an app outside the managed ceiling is refused without an allow command, and a pinned app in front passes")
    func managedCeilingAndPinnedPass() async throws {
        let (backend, _) = try Self.phoneBackend(top: "com.example.app/.MainActivity")
        backend.appScopes[Self.phone.rawValue] = AndroidAppScope(permitted: [], managedCeiling: ["com.example.managed"])
        let error = await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        #expect(error?.message.contains("managed policy on this Mac does not list it") == true)
        #expect(error?.hint == nil)

        backend.appScopes[Self.phone.rawValue] = AndroidAppScope(permitted: ["com.example.app"], managedCeiling: nil)
        backend.foregroundChecks = [:]
        try await backend.requireDrivableForeground(Self.phone.rawValue)
    }

    @Test("buttons such as Home skip the foreground check, so a phone can always be sent away from a deny-listed app")
    func buttonsSkipCheck() {
        #expect(AndroidInputSession.onlyButtons(.shortButtonPress(.home)))
        #expect(AndroidInputSession.onlyButtons(.composite([.button(direction: .down, button: .home), .delay(0.1), .button(direction: .up, button: .home)])))
        #expect(!AndroidInputSession.onlyButtons(.tapAt(x: 1, y: 1)))
        #expect(!AndroidInputSession.onlyButtons(.shortKeyPress(4)))
    }
}
