import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Which app a permission dialog is for, from `dumpsys activity activities`. The dump is an Android 16 emulator's, cut to the lines the script keeps, with the playground as the caller.
@Suite("The app a permission dialog is for")
@MainActor
struct AndroidPromptOwnerTests {
    nonisolated static let app = "com.mpalmes.offsider.playground.rn"
    nonisolated static let controller = "com.google.android.permissioncontroller"
    static let phone = AndroidBackendHelperTests.phone

    nonisolated static func dump(
        caller: String? = app, callerUID: Int = 10221, appUID: String = "    appId=10221",
        action: String = "android.content.pm.action.REQUEST_PERMISSIONS", top: String = "\(controller)/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity"
    ) -> String {
        """
        uid=\(appUID)
            topResumedActivity=ActivityRecord{122893975 u0 \(top) t308}
            * Hist  #1: ActivityRecord{122893975 u0 \(top) t308}
              packageName=\(controller) processName=\(controller)
              launchedFromUid=\(callerUID) launchedFromPackage=\(caller ?? "null") launchedFromFeature=null userId=0
              app=ProcessRecord{3a21778 16470:\(controller)/u0a203}
              Intent { act=\(action) flg=0x800000 pkg=\(controller) cmp=\(top) (has extras) }
              rootOfTask=false task=Task{9dafd72 #308 type=standard A=10221:\(app)}
        --
            * Hist  #0: ActivityRecord{166152829 u0 \(app)/.MainActivity t308}
              packageName=\(app) processName=\(app)
              launchedFromUid=2000 launchedFromPackage=com.android.shell launchedFromFeature=null userId=0
              app=ProcessRecord{bd076b1 22246:\(app)/u0a221}
              Intent { act=android.intent.action.VIEW dat=example://screen flg=0x10000000 pkg=\(app) cmp=\(app)/.MainActivity }
        --
          ResumedActivity: ActivityRecord{122893975 u0 \(top) t308}

        """
    }

    @Test("the resumed dialog's record gives the caller's package and uid, its intent and a token; the app's own uid comes with it")
    func parses() throws {
        let read = AndroidPromptOwner.parse(Self.dump())
        let owner = try #require(read.owner)
        #expect(owner.component.hasPrefix(Self.controller + "/"))
        #expect(owner.token == "122893975")
        #expect(owner.launchedFromPackage == Self.app && owner.launchedFromUid == 10221)
        #expect(owner.action == AndroidPromptOwner.requestPermissions)
        #expect(read.appUID == 10221)
        #expect(owner.refusal(for: Self.app, appUID: read.appUID) == nil)
        #expect(AndroidPromptOwner.parse(Self.dump(appUID: "    userId=10221")).appUID == 10221)
    }

    @Test("the record read is the resumed one, never an older activity's beneath it")
    func readsTheResumedRecord() throws {
        let appInFront = Self.dump().replacingOccurrences(of: "topResumedActivity=ActivityRecord{122893975 u0 \(Self.controller)/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity t308}", with: "topResumedActivity=ActivityRecord{166152829 u0 \(Self.app)/.MainActivity t308}")
        let owner = try #require(AndroidPromptOwner.parse(appInFront).owner)
        #expect(owner.launchedFromPackage == "com.android.shell")
        #expect(owner.refusal(for: Self.app, appUID: 10221) == .notShown(front: Self.app))
    }

    @Test("another app's dialog, a caller whose uid is not the app's, or a dump that names no caller is refused", arguments: [
        (dump(caller: "com.example.other", callerUID: 10300), "com.example.other raised it"),
        (dump(callerUID: 10300), "the caller's uid (10300) is not \(app)'s"),
        (dump(appUID: ""), "the caller's uid (10221) is not \(app)'s"),
        (dump(caller: nil), "Android did not say which app raised it"),
    ])
    func refusesAnotherCaller(dump: String, why: String) throws {
        let read = AndroidPromptOwner.parse(dump)
        guard case .otherApp(_, let reason) = try #require(read.owner).refusal(for: Self.app, appUID: read.appUID) else {
            Issue.record("expected another app's prompt")
            return
        }
        #expect(reason == why)
    }

    @Test("the controller's other screens are not a permission request, and any other app in front is no prompt")
    func refusesOtherWindows() throws {
        let settings = AndroidPromptOwner.parse(Self.dump(action: "android.intent.action.MANAGE_APP_PERMISSIONS"))
        guard case .notPermission = try #require(settings.owner).refusal(for: Self.app, appUID: settings.appUID) else {
            Issue.record("expected not a permission request")
            return
        }
        let launcher = AndroidPromptOwner.parse(Self.dump(top: "com.example.launcher/.Home"))
        #expect(try #require(launcher.owner).refusal(for: Self.app, appUID: launcher.appUID) == .notShown(front: "com.example.launcher"))
        #expect(AndroidPromptOwner.parse("uid=\n").owner == nil)
    }

    static func backend(top: String, owner: String, scope: AndroidAppScope?) async throws -> (AndroidBackend, FakeAdbServer) {
        // The fake answers every `dumpsys package` script with `dumpsys`, so the owner's dump goes there too.
        let server = AndroidDeviceStateTests.server(dumpsys: owner, devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { command in
            if command == AndroidForeground.readScript {
                return FakeAdbServer.shell(stdout: "top=  topResumedActivity=ActivityRecord{1a2b u0 \(top) t12}\nhome=com.example.launcher/.Home\n")
            }
            if command == AndroidPromptOwner.ownerScript { return FakeAdbServer.shell(stdout: owner) }
            return FakeAdbServer.shell()
        }
        let backend = try AndroidBackendTests.backend(server)
        backend.appScopes[phone.rawValue] = scope
        try await backend.prepare()
        return (backend, server)
    }

    static let testDevice = AndroidAppScope(permitted: [], managedCeiling: nil, wholeDevice: true)

    @Test("a phone in personal use never has a prompt read, whichever scope it has", arguments: [
        AndroidAppScope(permitted: [app], managedCeiling: nil),
        AndroidAppScope(permitted: [], managedCeiling: nil, needsTarget: true, target: app),
    ])
    func personalPhoneIsRefused(scope: AndroidAppScope) async throws {
        let (backend, server) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(), scope: scope)
        let sent = server.services.count
        await #expect(throws: AndroidError.self) { _ = try await backend.appPrompt(for: Self.app, on: Self.phone) }
        let proved = try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.promptOverSelectedApp(on: Self.phone) }
        #expect(proved == nil)
        #expect(server.services.count == sent)
    }

    @Test("a test device held to an app refuses its permission dialog to input and to plain reads, naming alert show")
    func testDeviceNamesAlert() async throws {
        let (backend, _) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(), scope: Self.testDevice)
        backend.selectApp(Self.app, on: Self.phone.rawValue)
        let error = await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        #expect(error?.isOtherAppInFront == true)
        #expect(error?.hint == "offsider alert show --app \(Self.app) --device \(Self.phone.rawValue)")
        #expect(error?.message.contains("A permission dialog is in front on \(Self.phone.rawValue)") == true)
    }

    @Test("once a look-only read proved the dialog is the named app's, reads pass and name it read only; input is still refused")
    func provenPromptOpensReadsOnly() async throws {
        let (backend, _) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(), scope: Self.testDevice)
        backend.selectApp(Self.app, on: Self.phone.rawValue)
        let window = UITreeContext.Window(title: "Allow Playground to take pictures?", kind: .system, package: Self.controller, readOnly: true)
        backend.promptReads[Self.phone.rawValue] = (ContinuousClock.now, Self.controller, window)

        try await PhoneRead.$overSystemWindow.withValue(true) {
            try await backend.requireDrivableForeground(Self.phone.rawValue)
            #expect(backend.provenPrompt(Self.phone.rawValue, package: Self.controller) == window)
            #expect(backend.provenPrompt(Self.phone.rawValue, package: "com.example.other") == nil)
        }
        await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        await #expect(throws: AndroidError.self) {
            try await PhoneRead.$overSystemWindow.withValue(true) {
                try await AndroidForegroundCheck.$beforeInput.withValue(true) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
            }
        }

        backend.promptReads[Self.phone.rawValue] = (ContinuousClock.now - AndroidBackend.promptReadLifetime - .seconds(1), Self.controller, window)
        await #expect(throws: AndroidError.self) {
            try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        }
    }

    @Test("a dialog another app raised is never proved for the named app, so its capture stays refused")
    func anotherAppsDialogStaysRefused() async throws {
        let (backend, _) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(caller: "com.example.other", callerUID: 10300), scope: Self.testDevice)
        backend.selectApp(Self.app, on: Self.phone.rawValue)
        try await PhoneRead.$overSystemWindow.withValue(true) {
            let proved = try await backend.promptOverSelectedApp(on: Self.phone)
            #expect(proved == nil)
            await #expect(throws: AndroidError.self) { try await backend.requireDrivableForeground(Self.phone.rawValue) }
        }
        #expect(backend.promptReads[Self.phone.rawValue] == nil)
        let refusal = await #expect(throws: AppPromptRefusal.self) { _ = try await backend.appPrompt(for: Self.app, on: Self.phone) }
        #expect(refusal == .otherApp(requester: "com.example.other", why: "com.example.other raised it"))
    }

    @Test("a dialog the named app raised is proved, but the proof is withdrawn when the prompt itself cannot then be read")
    func proofWithdrawnWhenThePromptCannotBeRead() async throws {
        let (backend, server) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(), scope: Self.testDevice)
        backend.selectApp(Self.app, on: Self.phone.rawValue)
        let proved = try await PhoneRead.$overSystemWindow.withValue(true) { try await backend.promptOverSelectedApp(on: Self.phone) }
        #expect(proved == nil)
        #expect(server.services.contains { $0.contains("dumpsys package \(Self.app)") })
        #expect(backend.promptReads[Self.phone.rawValue] == nil)
    }

    @Test("with no app named, outside a look-only read, or with the app itself in front, a test device asks nothing more of the phone")
    func nothingToProve() async throws {
        let (free, freeServer) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(), scope: Self.testDevice)
        var sent = freeServer.services.count
        let unnamed = try await PhoneRead.$overSystemWindow.withValue(true) { try await free.promptOverSelectedApp(on: Self.phone) }
        #expect(unnamed == nil)
        #expect(freeServer.services.count == sent)

        let (input, inputServer) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(), scope: Self.testDevice)
        input.selectApp(Self.app, on: Self.phone.rawValue)
        sent = inputServer.services.count
        let acting = try await input.promptOverSelectedApp(on: Self.phone)
        #expect(acting == nil)
        #expect(inputServer.services.count == sent)

        let (held, server) = try await Self.backend(top: "\(Self.app)/.MainActivity", owner: Self.dump(), scope: Self.testDevice)
        held.selectApp(Self.app, on: Self.phone.rawValue)
        try await PhoneRead.$overSystemWindow.withValue(true) {
            let front = try await held.promptOverSelectedApp(on: Self.phone)
            #expect(front == nil)
            try await held.requireDrivableForeground(Self.phone.rawValue)
        }
        #expect(AndroidBackendHelperTests.foregroundReads(server) == 1)
        #expect(!server.services.contains { $0.contains("dumpsys package") })
    }

    @Test("the app's uid is read once: a second owner read runs the activity dump alone, and still holds the caller to that uid")
    func uidReadOnce() async throws {
        let (backend, server) = try await Self.backend(top: "\(Self.controller)/.Grant", owner: Self.dump(callerUID: 10300), scope: Self.testDevice)
        for _ in 0..<2 {
            let refusal = await #expect(throws: AppPromptRefusal.self) { _ = try await backend.appPrompt(for: Self.app, on: Self.phone) }
            #expect(refusal == .otherApp(requester: nil, why: "the caller's uid (10300) is not \(Self.app)'s"))
        }
        let owners = server.services.filter { $0.hasSuffix(AndroidPromptOwner.ownerScript) }
        #expect(owners.count == 2, "\(server.services)")
        #expect(owners.filter { $0.contains("dumpsys package") }.count == 1)
    }
}
