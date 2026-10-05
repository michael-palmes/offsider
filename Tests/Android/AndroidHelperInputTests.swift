import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// Input on a device without gRPC (the rig's emulator refuses it), routed by `OFFSIDER_ANDROID_INPUT`.
@Suite("Android input through the helper")
@MainActor
struct AndroidHelperInputTests {
    static let device = HelperRig.device
    static let forced = ["OFFSIDER_ANDROID_INPUT": "helper"]

    static func inputScripts(_ rig: HelperRig) -> [String] {
        AndroidReplaceTextTests.inputScripts(rig)
    }

    static func session(_ rig: HelperRig) async throws -> AndroidInputSession {
        try #require(try await rig.backend.openInputSession(for: Self.device) as? AndroidInputSession)
    }

    @Test("auto with no helper running taps with `input` and never starts the helper")
    func autoWithoutHelper() async throws {
        let rig = try HelperRig()
        let session = try await Self.session(rig)
        try await session.perform(.tapAt(x: 5, y: 6))
        await session.close()
        await rig.backend.close()

        #expect(Self.inputScripts(rig) == ["input tap 5 6"])
        #expect(rig.startShells == 0)
    }

    @Test("helper starts the helper for input alone and sends the tap as one inject")
    func forcedTap() async throws {
        let rig = try HelperRig(environment: Self.forced)
        let session = try await Self.session(rig)
        try await session.perform(.tapAt(x: 5, y: 6))
        await session.close()
        await rig.backend.close()

        #expect(rig.device.ops == ["hello", "inject", "quit"])
        #expect(rig.device.injected == ["tap 5 6"])
        #expect(Self.inputScripts(rig).isEmpty)
    }

    @Test("a physical tap through the helper is one inject: down, a 100 ms hold on the device, up")
    func physicalTap() async throws {
        let rig = try HelperRig(environment: Self.forced)
        let session = try await Self.session(rig)
        try await session.performPhysicalTap(at: (x: 100, y: 200), preDelay: nil, postDelay: nil)
        await session.close()
        await rig.backend.close()

        #expect(rig.device.ops.filter { $0 == "inject" }.count == 1)
        #expect(rig.device.injected == ["touch down 100 200", "pause 100", "touch up 100 200"])
    }

    @Test("ASCII text goes through the helper as text and key steps, never `input text`")
    func typeText() async throws {
        let rig = try HelperRig(environment: Self.forced)
        let session = try await Self.session(rig)
        try await session.typeText("hi you\n")
        await session.close()
        await rig.backend.close()

        #expect(rig.device.injected == ["text hi you", "key press 66 meta 0"])
        #expect(Self.inputScripts(rig).isEmpty)
    }

    @Test("a refused inject is an input error, and close lifts nothing, since the helper already cancelled the finger")
    func refusedLeavesNothingDown() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, json in
            op == "inject" && json.contains(#""phase":"move""#) ? .error(code: "inject-refused", message: "Android did not dispatch step 0 (touch)") : nil
        }
        let rig = try HelperRig(device, environment: Self.forced)
        let session = try await Self.session(rig)
        let drag = InputEvent.composite([.touch(direction: .down, x: 10, y: 10)])
        try await session.perform(drag)

        let error = await #expect(throws: AndroidError.self) { try await session.perform(.touch(direction: .down, x: 60, y: 10)) }
        #expect(error?.kind == .inputFailed)
        #expect(error?.message == "Input on emulator-5556 failed: the UiAutomation helper reported inject-refused: Android did not dispatch step 0 (touch). Check that the device is still connected with `offsider list-devices`.")
        await session.close()
        await rig.backend.close()

        #expect(rig.device.ops.filter { $0 == "inject" }.count == 2)
        #expect(!rig.device.injected.contains { $0.hasPrefix("touch up") })
    }

    @Test("a helper lost before it answers an inject is never sent the input again, and the failure reports dispatched unknown")
    func lostInjectNotResent() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "inject" ? .hangUp : nil }
        let rig = try HelperRig(device, environment: Self.forced)
        let session = TrackedInputSession.wrapping(try await Self.session(rig))
        let tracker = DispatchTracker()

        let error = await #expect(throws: AndroidError.self) {
            try await DispatchTracker.$current.withValue(tracker) { try await session.perform(.tapAt(x: 5, y: 6)) }
        }
        await session.close()
        await rig.backend.close()

        #expect(error?.kind == .helperCrashed)
        #expect(error?.message.contains("The input may have reached the device, so Offsider did not send it again") == true)
        #expect(tracker.state == .unknown)
        #expect(rig.device.ops.filter { $0 == "inject" }.count == 1)
        #expect(rig.device.startedProcesses == 1)
    }

    @Test("a crash bye in answer to an inject is not resent either")
    func crashByeInjectNotResent() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "inject" ? .bye("crash") : nil }
        let rig = try HelperRig(device, environment: Self.forced)
        let session = try await Self.session(rig)

        await #expect(throws: AndroidError.self) { try await session.typeText("hello") }
        await session.close()
        await rig.backend.close()

        #expect(rig.device.ops.filter { $0 == "inject" }.count == 1)
    }

    @Test("helper with a helper that cannot start is an error naming OFFSIDER_ANDROID_INPUT, and nothing goes through `input`")
    func forcedUnavailable() async throws {
        let rig = try HelperRig(FakeHelperDevice(starts: [.exit(status: 6, stderr: "java.lang.VerifyError: bad dex\n")]), environment: Self.forced)
        let session = try await Self.session(rig)

        let error = await #expect(throws: AndroidError.self) { try await session.perform(.tapAt(x: 1, y: 1)) }
        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message == "The UiAutomation helper is unavailable on emulator-5556 (it exited with status 6 before it was ready: java.lang.VerifyError: bad dex), and OFFSIDER_ANDROID_INPUT is helper. Unset it to send input with `input` instead.")
        #expect(Self.inputScripts(rig).isEmpty)
        await rig.backend.close()
    }

    @Test("helper with OFFSIDER_ANDROID_TREE=uiautomator is refused, since the tree setting keeps the helper off")
    func forcedButTreeOff() async throws {
        let rig = try HelperRig(environment: Self.forced.merging(["OFFSIDER_ANDROID_TREE": "uiautomator"]) { $1 })
        let session = try await Self.session(rig)

        let error = await #expect(throws: AndroidError.self) { try await session.perform(.tapAt(x: 1, y: 1)) }
        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message.contains("(OFFSIDER_ANDROID_TREE is uiautomator)") == true)
        #expect(rig.startShells == 0)
        await rig.backend.close()
    }

    @Test("helper with another UiAutomation client connected is the busy error, not a silent `input` fallback")
    func forcedBusy() async throws {
        let rig = try HelperRig(FakeHelperDevice(starts: [AndroidBackendHelperTests.busy]), environment: Self.forced)
        let session = try await Self.session(rig)

        let error = await #expect(throws: AndroidError.self) { try await session.perform(.tapAt(x: 1, y: 1)) }
        #expect(error?.kind == .helperBusy)
        #expect(Self.inputScripts(rig).isEmpty)
        await rig.backend.close()
    }

    @Test("input keeps `input` even when the helper already runs for the tree")
    func inputPolicy() async throws {
        let rig = try HelperRig(environment: ["OFFSIDER_ANDROID_INPUT": "input"])
        _ = try await rig.read()
        let session = try await Self.session(rig)
        try await session.perform(.tapAt(x: 5, y: 6))
        await session.close()
        await rig.backend.close()

        #expect(rig.device.ops == ["hello", "dump", "quit"])
        #expect(Self.inputScripts(rig) == ["input tap 5 6"])
    }

    @Test("detached touches stay on `input motionevent` even when the helper is forced")
    func detachedTouch() async throws {
        let rig = try HelperRig(environment: Self.forced)
        try await rig.backend.sendDetachedTouch([.down(x: 10, y: 20)], to: Self.device)
        await rig.backend.close()

        #expect(Self.inputScripts(rig) == ["input motionevent DOWN 10 20"])
        #expect(rig.startShells == 0)
    }

    @Test("two fingers on an `input` route go through the helper when the policy allows it")
    func twoFingersUseHelper() async throws {
        let rig = try HelperRig()
        let session = try await Self.session(rig)
        try await session.perform(.composite([
            .twoFingerTouch(direction: .down, x1: 100, y1: 500, x2: 160, y2: 500), .delay(1),
            .twoFingerTouch(direction: .up, x1: 100, y1: 500, x2: 160, y2: 500),
        ]))
        await session.close()
        await rig.backend.close()

        #expect(rig.device.injected == ["touch down 100 500", "touch down p1 160 500", "pause 1000", "touch up p1 160 500", "touch up 100 500"])
        #expect(Self.inputScripts(rig).isEmpty)
    }

    @Test("OFFSIDER_ANDROID_INPUT=input refuses two fingers and sends nothing")
    func twoFingersRefusedOnInput() async throws {
        let rig = try HelperRig(environment: ["OFFSIDER_ANDROID_INPUT": "input"])
        let session = try await Self.session(rig)
        let error = await #expect(throws: AndroidError.self) {
            try await session.perform(.twoFingerTouch(direction: .down, x1: 100, y1: 500, x2: 160, y2: 500))
        }
        await session.close()
        await rig.backend.close()

        #expect(error?.kind == .notSupported)
        #expect(Self.inputScripts(rig).isEmpty)
        #expect(rig.startShells == 0)
    }
}
