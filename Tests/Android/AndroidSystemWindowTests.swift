import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// A system window over the allowed app on a phone: `describe-ui` and `screenshot` read it and name it; nothing else reads it and nothing taps it.
/// The dumps are invented, in the window manager's format.
@Suite("Reads over a system window")
@MainActor
struct AndroidSystemWindowTests {
    static let phone = AndroidBackendHelperTests.phone
    nonisolated static let app = "com.mpalmes.offsider.playground.rn"
    nonisolated static let systemTitle = "Keep this for later?"

    nonisolated static func focus(title: String = systemTitle, owner: String = "android", focusedApp: String? = app) -> String {
        """
              Window #0: WindowStateAnimator{512de66 com.example.wallpaper}
          mCurrentFocus=Window{a1b2c3 u0 \(title)}
          mFocusedApp=\(focusedApp.map { "ActivityRecord{55 u0 \($0)/.MainActivity t12}" } ?? "null")
          Window #0 Window{d4e5f6 u0 StatusBar}:
            mOwnerUid=10180 showForAllUsers=true package=com.android.systemui appop=NONE
          Window #1 Window{a1b2c3 u0 \(title)}:
            mOwnerUid=1000 showForAllUsers=true package=\(owner) appop=NONE
          Window #2 Window{778899 u0 \(app)/\(app).MainActivity}:
            mOwnerUid=10213 showForAllUsers=false package=\(app) appop=NONE

        """
    }

    static func backend(focus: String?, top: String = "\(app)/.MainActivity", scope: AndroidAppScope? = AndroidAppScope(permitted: [app], managedCeiling: nil)) async throws -> (AndroidBackend, FakeAdbServer) {
        let server = AndroidDeviceStateTests.server(devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { command in
            if command == AndroidForeground.readScript {
                return FakeAdbServer.shell(stdout: "top=  topResumedActivity=ActivityRecord{1a2b u0 \(top) t12}\nhome=com.example.launcher/.Home\n")
            }
            if command == AndroidWindowFocus.readScript { return FakeAdbServer.shell(stdout: focus ?? "") }
            if command == AndroidWindowFocus.keyboardScript { return FakeAdbServer.shell(stdout: "com.example.keyboard/.Service\n") }
            if command.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            return FakeAdbServer.shell()
        }
        let backend = try AndroidBackendTests.backend(server)
        backend.appScopes[phone.rawValue] = scope
        try await backend.prepare()
        return (backend, server)
    }

    static func focusReads(_ server: FakeAdbServer) -> Int {
        server.services.filter { $0 == "shell,v2,raw:" + AndroidWindowFocus.readScript }.count
    }

    /// A tree whose active window is owned by `package`, with the app's window beneath unless left out.
    static func covered(by package: String = "android", title: String = systemTitle, appListed: Bool = true) throws -> UITree {
        let sheet = #"{"id":2400,"type":"system","layer":5,"title":"\#(title)","displayId":0,"bounds":[0,1400,1080,2424],"active":true,"focused":true,"root":{"i":9,"class":"android.widget.FrameLayout","package":"\#(package)","bounds":[0,1400,1080,2424],"children":[]}}"#
        let beneath = HelperTreeMappingTests.appWindow(HelperTreeMappingTests.switchChildren, active: false)
        return try AndroidPhoneScopeTests.tree(appListed ? beneath + "," + sheet : sheet)
    }

    func read(_ tree: UITree, on backend: AndroidBackend) async throws -> UITreeContext.Window? {
        try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.requireReadableWindows(tree, on: Self.phone.rawValue) }
    }

    // MARK: The focus dump

    @Test("the focused window is named by its title, with the owner the window manager lists")
    func parsesSystemWindow() throws {
        let focus = try #require(AndroidWindowFocus.parse(Self.focus()))
        #expect(focus.title == Self.systemTitle)
        #expect(focus.owner == "android")
        #expect(focus.focusedApps == [Self.app])
    }

    @Test("an activity's own window has its owner; no focus, or a focus line the list leaves out, proves nothing")
    func parsesOthers() throws {
        let own = "  mCurrentFocus=Window{9f u0 com.example.app/com.example.app.Main}\n  mFocusedApp=ActivityRecord{1 u0 com.example.app/.Main t2}\n  Window #1 Window{9f u0 com.example.app/com.example.app.Main}:\n    mOwnerUid=10100 showForAllUsers=false package=com.example.app appop=NONE\n"
        #expect(AndroidWindowFocus.parse(own)?.owner == "com.example.app")
        #expect(AndroidWindowFocus.parse("  mCurrentFocus=null\n  mFocusedApp=null\n") == nil)
        #expect(AndroidWindowFocus.parse("") == nil)
        #expect(AndroidWindowFocus.parse("  mCurrentFocus=Window{9f u0 Sheet}\n")?.owner == nil)
    }

    @Test("a foldable's other display reports null, and only the focused activities are kept")
    func multiDisplay() {
        let dump = "  mCurrentFocus=null\n  mFocusedApp=null\n  mCurrentFocus=Window{9f u0 Sheet}\n  mFocusedApp=ActivityRecord{1 u0 com.example.app/.Main t2}\n  Window #1 Window{9f u0 Sheet}:\n    mOwnerUid=1000 package=android appop=NONE\n"
        let focus = AndroidWindowFocus.parse(dump)
        #expect(focus?.owner == "android")
        #expect(focus?.focusedApps == ["com.example.app"])
    }

    // MARK: Reads

    @Test("a pinned phone reads over a window owned by android while the allowed app holds focus, and names it")
    func pinnedReads() async throws {
        let (backend, _) = try await Self.backend(focus: Self.focus())
        let window = try await read(try Self.covered(), on: backend)
        #expect(window?.title == Self.systemTitle)
        #expect(window?.package == "android")
        #expect(window?.kind == .system)
        #expect(window?.readOnly == true)
        #expect(backend.systemWindow(for: Self.phone) == window)
    }

    @Test("the output names the window and says it is read only")
    func outputNames() throws {
        var tree = try Self.covered()
        tree.systemWindow = UITreeContext.Window(title: Self.systemTitle, kind: .system, package: "android", readOnly: true)
        let header = try #require(tree.context.headerLines.first { $0.hasPrefix("# window:") })
        #expect(header.contains(Self.systemTitle))
        #expect(header.hasSuffix("(system, read only)"))
        let json = try #require(try JSONSerialization.jsonObject(with: tree.jsonData()) as? [String: Any])
        let window = try #require((json["context"] as? [String: Any])?["window"] as? [String: Any])
        #expect(window["readOnly"] as? Bool == true)
        #expect(window["package"] as? String == "android")
        #expect(window["title"] as? String == Self.systemTitle)
    }

    @Test("an app's own window in JSON carries no readOnly key")
    func ordinaryWindowKeepsShape() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: try AndroidPhoneScopeTests.tree(HelperTreeMappingTests.appWindow(HelperTreeMappingTests.switchChildren)).jsonData()) as? [String: Any])
        let window = try #require((json["context"] as? [String: Any])?["window"] as? [String: Any])
        #expect(window["readOnly"] == nil)
    }

    @Test("a phone allowed for any app reads only for the app the command names")
    func anyAppNeedsItNamed() async throws {
        let (backend, _) = try await Self.backend(focus: Self.focus(), scope: AndroidAppScope(permitted: [], managedCeiling: nil, needsTarget: true))
        let unnamed = await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(), on: backend) }
        #expect(unnamed?.reason == .appNotAllowed)

        backend.selectApp(Self.app, on: Self.phone.rawValue)
        #expect(try await read(try Self.covered(), on: backend)?.readOnly == true)

        backend.selectApp("com.example.other", on: Self.phone.rawValue)
        let other = await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(), on: backend) }
        #expect(other?.isOtherAppInFront == true)
    }

    @Test("the read is refused unless an allowed app holds focus and android owns the focused window", arguments: [
        focus(focusedApp: nil),
        focus(focusedApp: "com.example.other"),
        focus(focusedApp: "android"),
        focus(owner: "com.example.other"),
        focus(owner: "com.android.systemui"),
        "",
        "  mCurrentFocus=null\n  mFocusedApp=null\n",
    ])
    func refusedWithoutProof(dump: String) async throws {
        let (backend, _) = try await Self.backend(focus: dump)
        let error = await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(), on: backend) }
        #expect(error?.reason == .appNotAllowed)
    }

    @Test("a package that only starts with android's name gains nothing, and the shade stays refused", arguments: ["com.android.systemui", "android.example", "com.example.other"])
    func onlyAndroidItself(package: String) async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus(owner: package))
        let error = await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(by: package), on: backend) }
        #expect(error?.reason == .appNotAllowed)
        #expect(Self.focusReads(server) == 0)
    }

    @Test("any other active window beside the system window still has to be allowed")
    func otherActiveWindow() async throws {
        let (backend, _) = try await Self.backend(focus: Self.focus())
        let sheet = #"{"id":2400,"type":"system","layer":5,"title":"x","displayId":0,"bounds":[0,1400,1080,2424],"active":true,"focused":true,"root":{"i":9,"class":"android.widget.FrameLayout","package":"android","bounds":[0,1400,1080,2424],"children":[]}}"#
        let tree = try AndroidPhoneScopeTests.tree(sheet + "," + AndroidPhoneScopeTests.shade)
        await #expect(throws: AndroidError.self) { _ = try await read(tree, on: backend) }
    }

    @Test("managed policy holds: a denied android or a list without it refuses the read, and listing it allows it")
    func managedPolicy() async throws {
        let (denied, _) = try await Self.backend(focus: Self.focus())
        await SystemAppDenyList.$managedOverride.withValue(["android"]) {
            let error = await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(), on: denied) }
            #expect(error?.message.contains("denied list") == true)
        }

        let (ceiling, ceilingServer) = try await Self.backend(focus: Self.focus(), scope: AndroidAppScope(permitted: [Self.app], managedCeiling: [Self.app]))
        let error = await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(), on: ceiling) }
        #expect(error?.message.contains("managed policy") == true)
        #expect(Self.focusReads(ceilingServer) == 0)

        let (listed, _) = try await Self.backend(focus: Self.focus(), scope: AndroidAppScope(permitted: [Self.app], managedCeiling: [Self.app, "android"]))
        #expect(try await read(try Self.covered(), on: listed)?.readOnly == true)
    }

    @Test("a test device reads as before: no focus read, nothing refused, nothing named", arguments: [true, false])
    func testDevice(inReadCommand: Bool) async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus(), scope: AndroidAppScope(permitted: [], managedCeiling: nil, wholeDevice: true))
        let tree = try Self.covered()
        let window = try await PhoneRead.$overSystemWindow.withValue(inReadCommand) { try await backend.requireReadableWindows(tree, on: Self.phone.rawValue) }
        #expect(window == nil)
        #expect(Self.focusReads(server) == 0)
        try await PhoneRead.$overSystemWindow.withValue(inReadCommand) { try await backend.requireReadableFocus(Self.phone.rawValue) }
        #expect(Self.focusReads(server) == 0)
    }

    @Test("a test device held to a named app reads over a system window only while that app holds focus")
    func testDeviceHeld() async throws {
        let (backend, _) = try await Self.backend(focus: Self.focus(), scope: AndroidAppScope(permitted: [], managedCeiling: nil, wholeDevice: true))
        backend.holdToApp("com.example.other", on: Self.phone.rawValue)
        await #expect(throws: AndroidError.self) { _ = try await read(try Self.covered(), on: backend) }
        backend.holdToApp(Self.app, on: Self.phone.rawValue)
        #expect(try await read(try Self.covered(), on: backend)?.readOnly == true)
    }

    @Test("an emulator never reads the focus")
    func emulator() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus())
        let window = try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.requireReadableWindows(try Self.covered(), on: "emulator-5556") }
        #expect(window == nil)
        #expect(Self.focusReads(server) == 0)
    }

    @Test("with the allowed app in front and active, a read costs no focus read")
    func ordinaryReadIsFree() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus())
        let tree = try AndroidPhoneScopeTests.tree(HelperTreeMappingTests.appWindow(HelperTreeMappingTests.switchChildren))
        #expect(try await read(tree, on: backend) == nil)
        #expect(Self.focusReads(server) == 0)
    }

    // MARK: The chooser and the launcher stay refused

    @Test("the chooser stays refused: an activity owned by android is what is in front, not a window over the app")
    func chooserRefused() async throws {
        let (backend, _) = try await Self.backend(focus: Self.focus(focusedApp: "android"), top: "android/com.android.internal.app.ResolverActivity")
        await PhoneRead.$overSystemWindow.withValue(true) {
            let tree = await #expect(throws: AndroidError.self) { _ = try await backend.requireDrivableForeground(Self.phone.rawValue) }
            #expect(tree?.isOtherAppInFront == true)
            let shot = await #expect(throws: AndroidError.self) { _ = try await backend.screenshotPNG(for: Self.phone) }
            #expect(shot?.message.contains("android is in front") == true)
        }
    }

    @Test("a launcher in front stays refused for a read of the screen", arguments: ["com.example.launcher/.Home", "com.google.android.apps.nexuslauncher/.Launcher"])
    func launcherRefused(top: String) async throws {
        let (backend, _) = try await Self.backend(focus: nil, top: top)
        await PhoneRead.$overSystemWindow.withValue(true) {
            await #expect(throws: AndroidError.self) { _ = try await backend.screenshotPNG(for: Self.phone) }
            await #expect(throws: AndroidError.self) { _ = try await backend.accessibilityTree(for: Self.phone, point: nil) }
        }
    }

    // MARK: Every other command stays refused

    @Test("outside describe-ui and screenshot a read is refused without asking who has focus, and says what can read it")
    func otherReadsRefused() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus())
        let error = await #expect(throws: AndroidError.self) { _ = try await backend.requireReadableWindows(try Self.covered(), on: Self.phone.rawValue) }
        #expect(error?.isOtherAppInFront == true)
        #expect(error?.message.contains(Self.systemTitle) == true)
        #expect(error?.message.contains("`describe-ui` and `screenshot`") == true)
        #expect(Self.focusReads(server) == 0)
    }

    @Test("a capture that is not describe-ui or screenshot reads no focus, as a video frame or a verify does not")
    func otherCaptures() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus())
        _ = try? await backend.screenshotPNG(for: Self.phone)
        #expect(Self.focusReads(server) == 0)
    }

    // MARK: Input

    @Test("a coordinate tap under a system window is refused and nothing is sent, even inside a read command")
    func tapRefused() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus())
        let session = try await backend.openInputSession(for: Self.phone)
        for scoped in [false, true] {
            let error = await #expect(throws: AndroidError.self) {
                try await PhoneRead.$overSystemWindow.withValue(scoped) { try await session.perform(.tapAt(x: 10, y: 10)) }
            }
            #expect(error?.isOtherAppInFront == true)
            #expect(error?.message.contains(Self.systemTitle) == true)
        }
        #expect(!server.services.contains { $0.contains("input ") })
    }

    @Test("keys and held touches are refused under a system window too")
    func otherInputRefused() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus())
        let session = try await backend.openInputSession(for: Self.phone)
        await #expect(throws: AndroidError.self) { try await session.perform(.shortKeyPress(4)) }
        await #expect(throws: AndroidError.self) { try await backend.sendDetachedTouch([.down(x: 10, y: 10)], to: Self.phone) }
        #expect(!server.services.contains { $0.contains("input ") })
    }

    @Test("input with the notification shade focused over an allowed app is refused")
    func shadeRefused() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus(title: "NotificationShade", owner: "com.android.systemui"))
        let session = try await backend.openInputSession(for: Self.phone)
        let error = await #expect(throws: AndroidError.self) { try await session.perform(.tapAt(x: 10, y: 10)) }
        #expect(error?.message.contains("com.android.systemui") == true)
        #expect(!server.services.contains { $0.contains("input ") })
    }

    @Test("input reaches the app's own window, the keyboard, or a phone with no focus to read", arguments: [
        focus(title: "\(app)/\(app).MainActivity", owner: app),
        focus(title: "InputMethod", owner: "com.example.keyboard"),
        "",
    ])
    func inputGoesThrough(dump: String) async throws {
        let (backend, server) = try await Self.backend(focus: dump)
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 10, y: 10))
        #expect(server.services.contains { $0.contains("input ") })
    }

    @Test("an app that titles its own window InputMethod is not the keyboard")
    func titleIsNotTheKeyboard() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus(title: "InputMethod", owner: "com.example.other"))
        let session = try await backend.openInputSession(for: Self.phone)
        let error = await #expect(throws: AndroidError.self) { try await session.perform(.tapAt(x: 10, y: 10)) }
        #expect(error?.message.contains("com.example.other") == true)
        #expect(!server.services.contains { $0.contains("input ") })
    }

    @Test("input forgets the last focus read, so the capture after it reads again")
    func inputForgetsFocus() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus(title: "\(Self.app)/\(Self.app).MainActivity", owner: Self.app))
        try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.requireReadableFocus(Self.phone.rawValue) }
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 10, y: 10))
        let before = Self.focusReads(server)
        try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.requireReadableFocus(Self.phone.rawValue) }
        #expect(Self.focusReads(server) == before + 1)
    }

    @Test("a title that holds an email is redacted wherever it is shown")
    func titleRedacted() async throws {
        let (backend, _) = try await Self.backend(focus: Self.focus(title: "Saved for me@example.com"))
        let window = try await read(try Self.covered(title: "Saved for me@example.com"), on: backend)
        #expect(window?.title?.contains("me@example.com") == false)
        let refusal = await #expect(throws: AndroidError.self) { _ = try await backend.requireReadableWindows(try Self.covered(title: "Saved for me@example.com"), on: Self.phone.rawValue) }
        #expect(refusal?.message.contains("me@example.com") == false)
    }

    @Test("a test device's input asks nobody who has focus")
    func testDeviceInput() async throws {
        let (backend, server) = try await Self.backend(focus: Self.focus(), scope: AndroidAppScope(permitted: [], managedCeiling: nil, wholeDevice: true))
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 10, y: 10))
        #expect(Self.focusReads(server) == 0)
        #expect(server.services.contains { $0.contains("input ") })
    }

    @Test("a capture that read no tree still refuses the shade and names a system window")
    func unmaskedCapture() async throws {
        let (shaded, _) = try await Self.backend(focus: Self.focus(title: "NotificationShade", owner: "com.android.systemui"))
        await PhoneRead.$overSystemWindow.withValue(true) {
            let error = await #expect(throws: AndroidError.self) { try await shaded.requireReadableFocus(Self.phone.rawValue) }
            #expect(error?.message.contains("com.android.systemui") == true)
        }

        let (backend, server) = try await Self.backend(focus: Self.focus())
        try await PhoneRead.$overSystemWindow.withValue(true) {
            try await backend.requireReadableFocus(Self.phone.rawValue)
            try await backend.requireReadableFocus(Self.phone.rawValue)
        }
        #expect(backend.systemWindow(for: Self.phone)?.title == Self.systemTitle)
        #expect(Self.focusReads(server) == 1)
    }
}
