import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// Touch phases on an `input` route: Android added `input motionevent` in 10 (API 29), and earlier `input` drops one silently.
@Suite("Android touch phases over adb")
@MainActor
struct AndroidMotionEventTests {
    static let device = HelperRig.device
    static let drag = InputEvent.composite([
        .touch(direction: .down, x: 100, y: 500), .delay(0.05), .touch(direction: .down, x: 100, y: 600), .touch(direction: .up, x: 100, y: 600),
    ])

    static func perform(_ events: [InputEvent], on rig: HelperRig) async throws {
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? AndroidInputSession)
        do {
            for event in events {
                try await session.perform(event)
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    static func physicalTap(on rig: HelperRig) async throws {
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? AndroidInputSession)
        try await session.performPhysicalTap(at: (x: 100, y: 200), preDelay: nil, postDelay: nil)
        await session.close()
    }

    @Test("on API 28 a drag starts the helper and goes through it, never `input`")
    func api28DragUsesHelper() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        try await Self.perform([Self.drag], on: rig)
        await rig.backend.close()

        #expect(rig.device.injected == ["touch down 100 500", "pause 50", "touch move 100 600", "touch up 100 600"])
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 1)
    }

    @Test("on API 28 a touch held across separate steps, as batch touch steps send it, goes down and up through the helper")
    func api28SeparateStepsUseHelper() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        try await Self.perform([.touch(direction: .down, x: 100, y: 200), .touch(direction: .up, x: 120, y: 200)], on: rig)
        await rig.backend.close()

        #expect(rig.device.injected == ["touch down 100 200", "touch up 120 200"])
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
    }

    @Test("with OFFSIDER_ANDROID_INPUT=input, API 28 refuses a drag and sends nothing")
    func api28DragRefusedOnInput() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28", environment: ["OFFSIDER_ANDROID_INPUT": "input"])
        let error = await #expect(throws: AndroidError.self) { try await Self.perform([Self.drag], on: rig) }
        await rig.backend.close()

        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message == "emulator-5556 runs API 28, where `input` has no motionevent (Android 10, API 29, added it), so Offsider sent nothing. A drag, or a touch held across other steps, goes through the UiAutomation helper there, and OFFSIDER_ANDROID_INPUT is input: unset it, then retry.")
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 0)
    }

    @Test("on API 28 a physical tap is one swipe that stays put for the hold, with no helper, whatever OFFSIDER_ANDROID_INPUT allows", arguments: ["auto", "input"])
    func api28PhysicalTapSwipes(policy: String) async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28", environment: ["OFFSIDER_ANDROID_INPUT": policy])
        try await Self.physicalTap(on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input swipe 100 200 100 200 100"])
        #expect(rig.startShells == 0)
    }

    @Test("from API 29, or with an unread level, a physical tap and a drag stay motion events and never start the helper", arguments: ["29", "36", ""])
    func recentKeepsMotionEvents(apiLevel: String) async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: apiLevel)
        try await Self.physicalTap(on: rig)
        try await Self.perform([Self.drag], on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == [
            "input motionevent DOWN 100 200",
            "input motionevent UP 100 200",
            "input motionevent DOWN 100 500 && sleep 0.05 && input motionevent MOVE 100 600 && input motionevent UP 100 600",
        ])
        #expect(rig.startShells == 0)
    }

    @Test("an API level the display probe already read needs no `getprop` of its own")
    func levelFromProbe() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        let other = rig.device.other
        rig.device.other = { service in
            service.hasSuffix(AndroidDisplayGeometry.probeScript)
                ? FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput + "\nAPI level: 28\n") : other(service)
        }
        try await Self.physicalTap(on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input swipe 100 200 100 200 100"])
        #expect(AndroidKeyCombinationTests.apiLevelReads(rig) == 0)
    }

    @Test("on API 28 a touch a failed swipe may leave down is reported, not lifted with a motionevent `input` would ignore")
    func api28CloseWarns() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        let other = rig.device.other
        rig.device.other = { service in
            service.contains(":input swipe") ? FakeAdbServer.shell(stderr: "Error: injection failed\n", status: 1) : other(service)
        }
        let session = try #require(try await rig.backend.openInputSession(for: Self.device) as? AndroidInputSession)
        await #expect(throws: AndroidError.self) { try await session.performPhysicalTap(at: (x: 100, y: 200), preDelay: nil, postDelay: nil) }
        await session.close()
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input swipe 100 200 100 200 100"])
        #expect(rig.log.warnings.contains { $0.hasPrefix("Could not lift the touch left down on emulator-5556: `input` there has no motionevent") })
    }

    @Test("a batch touch --down --up is one held touch: a swipe in place on API 28, one motionevent script from API 29", arguments: [
        ("28", "input swipe 263 525 263 525 800"), ("36", "input motionevent DOWN 263 525 && sleep 0.8 && input motionevent UP 263 525"),
    ])
    func batchHeldTouch(apiLevel: String, script: String) async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: apiLevel)
        let batch = try Batch.parse(["--device", "emulator-5556", "--step", "touch -x 100 -y 200 --down --up --delay 0.8"])
        try await batch.run(on: DeviceRouter.Route(backend: rig.backend, device: Self.device), logger: OffsiderLogger())
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == [script])
        #expect(rig.startShells == 0)
    }

    @Test("taps and swipes never read the API level")
    func noTouchPhaseNoRead() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        try await Self.perform([.tapAt(x: 5, y: 6), .swipe(10, yStart: 20, xEnd: 10, yEnd: 200, delta: 50, duration: 0.3)], on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input tap 5 6", "input swipe 10 20 10 200 300"])
        #expect(AndroidKeyCombinationTests.apiLevelReads(rig) == 0)
    }

    @Test("on API 28 a touch left down for a later command is refused before anything is sent", arguments: [
        [DetachedTouchStep.down(x: 10, y: 20)], [.hold(0.25), .up(x: 10, y: 20)],
    ])
    func api28DetachedRefused(steps: [DetachedTouchStep]) async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        let error = await #expect(throws: AndroidError.self) { try await rig.backend.sendDetachedTouch(steps, to: Self.device) }
        await rig.backend.close()

        #expect(error?.kind == .notSupported)
        #expect(error?.message == "emulator-5556 runs API 28, where `input` has no motionevent (Android 10, API 29, added it), so a touch cannot stay down between commands, and Offsider sent nothing. Use `touch --down --up` in one command (with --delay for a long press), or both touch steps in one `batch`.")
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 0)
    }

    @Test("on API 28 touch --down --up in one command is one swipe that stays put for the delay")
    func api28DetachedHeldTap() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "28")
        try await rig.backend.sendDetachedTouch([.down(x: 10, y: 20), .hold(0.8), .up(x: 10, y: 20)], to: Self.device)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input swipe 10 20 10 20 800"])
    }

    @Test("from API 29 a detached touch stays a motion event", arguments: ["29", "36"])
    func recentDetachedKeepsMotionEvent(apiLevel: String) async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: apiLevel)
        try await rig.backend.sendDetachedTouch([.down(x: 10, y: 20)], to: Self.device)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == ["input motionevent DOWN 10 20"])
    }
}
