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
    /// A drag that holds still for 200 ms before it moves, as `drag --hold-ms 200` does.
    static let heldDrag = InputEvent.composite([
        .touch(direction: .down, x: 100, y: 500), .delay(0.2), .touch(direction: .down, x: 100, y: 600), .touch(direction: .up, x: 100, y: 600),
    ])
    static let heldDragScript = "input motionevent DOWN 100 500 && sleep 0.2 && input motionevent MOVE 100 600 && input motionevent UP 100 600"

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

    @Test("from API 29, or with an unread level, a physical tap is one swipe in place and a drag that never rests stays on `input`", arguments: ["29", "36", ""])
    func recentPlainDragStaysOnInput(apiLevel: String) async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: apiLevel)
        try await Self.physicalTap(on: rig)
        try await Self.perform([Self.drag], on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == [
            "input swipe 100 200 100 200 100",
            "input motionevent DOWN 100 500 && sleep 0.05 && input motionevent MOVE 100 600 && input motionevent UP 100 600",
        ])
        #expect(rig.startShells == 0)
    }

    @Test("from API 29 a drag that holds still starts the helper, which reports the resting finger every 50 ms and confirms the lift on its own")
    func recentHeldDragUsesHelper() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "34")
        try await Self.perform([.composite([
            .touch(direction: .down, x: 100, y: 500), .delay(0.2), .touch(direction: .down, x: 100, y: 600), .delay(0.12),
            .touch(direction: .up, x: 100, y: 600),
        ])], on: rig)
        await rig.backend.close()

        #expect(rig.device.injected == [
            "touch down 100 500", "pause 48", "touch move 100 500", "pause 48", "touch move 100 500", "pause 48", "touch move 100 500", "pause 50",
            "touch move 100 600", "pause 48", "touch move 100 600", "pause 48", "touch move 100 600", "pause 20",
            "touch up 100 600",
        ])
        #expect(rig.device.ops.filter { $0 == "inject" }.count == 2)
        #expect(AndroidHelperInputTests.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 1)
    }

    @Test("from API 29, with the helper unavailable, a drag that holds still goes through `input motionevent` with one warning that the hold sends nothing")
    func recentHeldDragFallsBack() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "34", environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        try await Self.perform([Self.heldDrag, Self.heldDrag], on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == [Self.heldDragScript, Self.heldDragScript])
        #expect(rig.log.warnings.filter { $0.contains("held touch goes through `input motionevent`") }.count == 1)
        #expect(rig.startShells == 0)
    }

    @Test("from API 29, a setting the helper cannot start under leaves a drag that holds still on `input`, with the warning, instead of failing it")
    func recentHeldDragSurvivesBadSetting() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "34", environment: ["OFFSIDER_ANDROID_TREE": "bogus"])
        try await Self.perform([Self.heldDrag], on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == [Self.heldDragScript])
        #expect(rig.log.warnings.contains { $0.contains("held touch goes through `input motionevent`") })
    }

    @Test("from API 29, OFFSIDER_ANDROID_INPUT=input keeps a drag that holds still on `input motionevent` and warns nothing")
    func recentHeldDragOnInput() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "34", environment: ["OFFSIDER_ANDROID_INPUT": "input"])
        try await Self.perform([Self.heldDrag], on: rig)
        await rig.backend.close()

        #expect(AndroidHelperInputTests.inputScripts(rig) == [Self.heldDragScript])
        #expect(rig.log.warnings.isEmpty)
        #expect(rig.startShells == 0)
    }

    @Test("a touch already down on `input` keeps its route for a later hold, so one finger never goes through two injectors")
    func heldTouchKeepsItsRoute() async throws {
        let rig = try AndroidKeyCombinationTests.rig(apiLevel: "34")
        try await Self.perform([.touch(direction: .down, x: 100, y: 500), .composite([.delay(0.3), .touch(direction: .up, x: 100, y: 500)])], on: rig)
        await rig.backend.close()

        let scripts = rig.server.services.filter { $0.contains("input motionevent") }.map { String($0.dropFirst("shell,v2,raw:".count)) }
        #expect(scripts == ["input motionevent DOWN 100 500", "sleep 0.3 && input motionevent UP 100 500"])
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

    @Test("a batch touch --down --up is one held touch, a swipe in place whose moves report the resting finger, on every release", arguments: [
        ("28", "input swipe 263 525 263 525 800"), ("36", "input swipe 263 525 263 525 800"),
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
