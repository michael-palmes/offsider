import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android text over gRPC")
@MainActor
struct AndroidGrpcTextTests {
    static let device = AndroidGrpcInputTests.device

    static func session(_ rig: AndroidGrpcInputTests.Rig) async throws -> any TextInputSession {
        try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
    }

    @Test("ASCII goes as gRPC text chunks, with Return as a USB key, and nothing over adb")
    func asciiOverGrpc() async throws {
        let rig = try AndroidGrpcInputTests.rig()
        try await Self.session(rig).typeText("hello world\n")

        #expect(rig.emulator.calls == [.key(.text("hello world")), .key(.usb(0x070028, .press))])
        #expect(rig.adbScripts.isEmpty)
    }

    @Test("non-ASCII text is pasted: save, set, paste over adb, restore, with the settles between")
    func pasteSequence() async throws {
        let rig = try AndroidGrpcInputTests.rig(emulator: FakeEmulator(clipboard: "sentinel"))
        try await Self.session(rig).typeText("héllo 日本")

        #expect(rig.emulator.calls == [.getClipboard, .setClipboard("héllo 日本"), .setClipboard("sentinel")])
        #expect(rig.adbScripts.filter { $0.hasPrefix("input") } == ["input keyevent 279"])
        #expect(rig.sleeps.sleeps == [.milliseconds(150), .milliseconds(300)])
        #expect(rig.emulator.clipboardNow == "sentinel")
    }

    @Test("the clipboard is restored even when the paste key fails")
    func restoreAfterFailedPaste() async throws {
        let rig = try AndroidGrpcInputTests.rig(emulator: FakeEmulator(clipboard: "sentinel"), failingScript: { $0 == "input keyevent 279" })

        let error = await #expect(throws: AndroidError.self) { try await Self.session(rig).typeText("日本") }
        #expect(error?.kind == .inputFailed)
        #expect(rig.emulator.calls == [.getClipboard, .setClipboard("日本"), .setClipboard("sentinel")])
        #expect(rig.emulator.clipboardNow == "sentinel")
    }

    @Test("a failed restore is a warning, not an error")
    func failedRestoreWarns() async throws {
        let failure = AndroidError.grpcDeadlineExceeded(method: "setClipboard", seconds: 2)
        let emulator = FakeEmulator(clipboard: "sentinel") { $0 == .setClipboard("sentinel") ? failure : nil }
        let rig = try AndroidGrpcInputTests.rig(emulator: emulator)
        try await Self.session(rig).typeText("🙂")

        #expect(rig.logs.warnings == ["Could not restore the emulator's clipboard after pasting: \(failure.message)"])
    }

    @Test("a resized display still pastes through the gRPC clipboard and types ASCII over adb")
    func resizedDisplay() async throws {
        let rig = try AndroidGrpcInputTests.rig(geometry: AndroidGrpcInputTests.resized, emulator: FakeEmulator(clipboard: "x"))
        let session = try await Self.session(rig)
        try await session.typeText("ok")
        try await session.typeText("é")

        #expect(rig.adbScripts.filter { $0.hasPrefix("input") } == ["input text 'ok'", "input keyevent 279"])
        #expect(rig.emulator.calls == [.getClipboard, .setClipboard("é"), .setClipboard("x")])
    }

    @Test("with the transport forced to adb, non-ASCII text says how to get gRPC back and touches nothing")
    func forcedAdb() async throws {
        let rig = try AndroidGrpcInputTests.rig(environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb"])

        let error = await #expect(throws: AndroidError.self) { try await Self.session(rig).typeText("héllo") }
        #expect(error?.message == "Typing non-ASCII text on Android needs the emulator's gRPC endpoint, and OFFSIDER_ANDROID_TRANSPORT is adb. Unset it, or type ASCII only.")
        #expect(rig.adbScripts.isEmpty)
        #expect(rig.emulator.calls.isEmpty)
    }

    @Test("an endpoint that failed its probe is named in the non-ASCII error")
    func failedProbe() async throws {
        let rig = try AndroidGrpcInputTests.rig()
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write("avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n", to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini", in: home)
        let host = AndroidTestHost.make(home: home, adb: rig.server, emulator: .refusing, liveProcesses: [50144])
        let backend = AndroidBackend(host: host) { _, _ in }
        let session = try #require(try await backend.openInputSession(for: Self.device) as? any TextInputSession)

        let error = await #expect(throws: AndroidError.self) { try await session.typeText("é") }
        #expect(error?.message == "Typing non-ASCII text on Android needs the emulator's gRPC endpoint, and emulator-5556 has one, but it failed (The emulator's gRPC endpoint on port 8556 did not answer on 127.0.0.1 or [::1]; it may be shutting down). Restart it with `offsider boot Offsider_E2E_Pixel_9`, or type ASCII only.")
    }
}
