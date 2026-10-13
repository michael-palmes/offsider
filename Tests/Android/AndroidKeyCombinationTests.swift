import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// Key combinations on an `input` route: Android added `input keycombination` in 12 (API 31), and earlier `input` drops one silently.
@Suite("Android key combinations over adb")
@MainActor
struct AndroidKeyCombinationTests {
    static let device = HelperRig.device
    static let selectAllInjected = ["key down 113 meta 12288", "key press 29 meta 12288", "key up 113 meta 0", "pause 50", "key press 67 meta 0"]

    /// The rig's emulator without gRPC, answering `getprop ro.build.version.sdk` with `apiLevel`.
    static func rig(apiLevel: String, _ device: FakeHelperDevice = FakeHelperDevice(), environment: [String: String] = [:]) throws -> HelperRig {
        let rig = try HelperRig(device, environment: environment)
        let other = device.other
        device.other = { service in
            service.hasSuffix(":getprop ro.build.version.sdk") ? FakeAdbServer.shell(stdout: "\(apiLevel)\n") : other(service)
        }
        return rig
    }

    static func apiLevelReads(_ rig: HelperRig) -> Int {
        rig.server.services.filter { $0.hasSuffix(":getprop ro.build.version.sdk") }.count
    }

    static func selectAllAndDelete(on rig: HelperRig) async throws {
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? AndroidInputSession)
        do {
            try await session.perform(InputEvent.selectAllAndDelete(modifier: InputEvent.controlKey))
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    @Test("on API 28 a key combination starts the helper and goes through it, never `input`")
    func api28UsesHelper() async throws {
        let rig = try Self.rig(apiLevel: "28")
        try await Self.selectAllAndDelete(on: rig)
        await rig.backend.close()

        #expect(rig.device.injected == Self.selectAllInjected)
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 1)
    }

    @Test("with OFFSIDER_ANDROID_INPUT=input, API 28 refuses a key combination and sends nothing")
    func api28RefusedOnInput() async throws {
        let rig = try Self.rig(apiLevel: "28", environment: ["OFFSIDER_ANDROID_INPUT": "input"])
        let error = await #expect(throws: AndroidError.self) { try await Self.selectAllAndDelete(on: rig) }
        await rig.backend.close()

        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message == "emulator-5556 runs API 28, where `input` has no key combinations (Android 12, API 31, added them), so Offsider sent nothing. Combinations go through the UiAutomation helper there, and OFFSIDER_ANDROID_INPUT is input: unset it, then retry.")
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 0)
    }

    @Test("with OFFSIDER_ANDROID_TREE=uiautomator, API 30 refuses a key combination, naming that variable")
    func api30RefusedOnUIAutomator() async throws {
        let rig = try Self.rig(apiLevel: "30", environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        let error = await #expect(throws: AndroidError.self) { try await Self.selectAllAndDelete(on: rig) }
        await rig.backend.close()

        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message.hasSuffix("and OFFSIDER_ANDROID_TREE is uiautomator: unset it, then retry.") == true)
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 0)
    }

    @Test("a helper that cannot start on API 28 refuses the key combination with its reason and sends nothing")
    func api28HelperUnavailable() async throws {
        let rig = try Self.rig(apiLevel: "28", FakeHelperDevice(starts: [.exit(status: 6, stderr: "java.lang.VerifyError: bad dex\n")]))
        let error = await #expect(throws: AndroidError.self) { try await Self.selectAllAndDelete(on: rig) }
        await rig.backend.close()

        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message.hasSuffix("which is unavailable on emulator-5556 (it exited with status 6 before it was ready: java.lang.VerifyError: bad dex).") == true)
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
    }

    @Test("API 31 and later, or an unread level, keep `input keycombination` and never start the helper", arguments: ["31", "36", ""])
    func recentKeepsInput(apiLevel: String) async throws {
        let rig = try Self.rig(apiLevel: apiLevel)
        try await Self.selectAllAndDelete(on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input keycombination 113 29 && sleep 0.05 && input keyevent 67"])
        #expect(rig.startShells == 0)
        #expect(Self.apiLevelReads(rig) == 1)
    }

    @Test("input with no key combination never reads the API level")
    func noCombinationNoRead() async throws {
        let rig = try Self.rig(apiLevel: "28")
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? AndroidInputSession)
        try await session.perform(.composite([.shortKeyPress(40), .keyboard(direction: .down, keyCode: 40), .delay(1), .keyboard(direction: .up, keyCode: 40)]))
        await session.close()
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input keyevent 66 && input keyevent --longpress 66"])
        #expect(Self.apiLevelReads(rig) == 0)
    }

    @Test("type --replace on API 28 with OFFSIDER_ANDROID_INPUT=input refuses its Ctrl+A fallback before Delete or any text is sent")
    func replaceFallbackRefused() async throws {
        let rig = try AndroidReplaceTextTests.rig(
            environment: ["OFFSIDER_ANDROID_INPUT": "input"],
            setText: .error(code: "action-unsupported", message: "android.widget.EditText does not offer ACTION_SET_TEXT")
        )
        let other = rig.device.other
        rig.device.other = { service in
            service.hasSuffix(":getprop ro.build.version.sdk") ? FakeAdbServer.shell(stdout: "28\n") : other(service)
        }
        let error = await #expect(throws: AndroidError.self) { try await AndroidReplaceTextTests.replace("bye", on: rig) }
        await rig.backend.close()

        #expect(error?.kind == .helperUnavailable)
        #expect(AndroidReplaceTextTests.inputScripts(rig).isEmpty)
        #expect(rig.device.injected.isEmpty)
    }
}
