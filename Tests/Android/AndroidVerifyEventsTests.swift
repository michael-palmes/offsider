import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android verify events")
@MainActor
struct AndroidVerifyEventsTests {
    static let device = HelperRig.device
    nonisolated static let oneEvent = #"{"events":[{"seq":4,"type":2048,"package":"com.mpalmes.offsider.playground.rn","windowId":2292}],"eventSeq":4}"#
    nonisolated static let noEvents = #"{"events":[],"eventSeq":3}"#

    static func rig(events: String) throws -> HelperRig {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "events" ? .ok(events) : nil }
        return try HelperRig(device)
    }

    static func eventsRequest(_ rig: HelperRig) throws -> NSDictionary {
        let frame = try #require(rig.device.frames.first { $0.op == "events" })
        return try #require(try JSONSerialization.jsonObject(with: Data(frame.json.utf8)) as? NSDictionary)
    }

    @Test("the wait asks for events since the last dump, for as long as the poll interval, and wakes on one")
    func wakesOnEvent() async throws {
        let rig = try Self.rig(events: Self.oneEvent)
        _ = try await rig.read()

        let changed = try await rig.backend.waitForAccessibilityChange(on: Self.device, timeout: .milliseconds(200))

        #expect(changed)
        let request = try Self.eventsRequest(rig)
        #expect(request["since"] as? Int == 3)
        #expect(request["waitMs"] as? Int == 200)
        #expect(rig.sleeps.sleeps.isEmpty)
        await rig.backend.close()
    }

    @Test("no events within the wait is no change, and the helper did the waiting")
    func noEvents() async throws {
        let rig = try Self.rig(events: Self.noEvents)
        _ = try await rig.read()

        #expect(try await rig.backend.waitForAccessibilityChange(on: Self.device, timeout: .milliseconds(200)) == false)
        #expect(rig.sleeps.sleeps.isEmpty)
        await rig.backend.close()
    }

    @Test("with no helper running, the wait sleeps the interval and starts nothing")
    func noHelper() async throws {
        let rig = try Self.rig(events: Self.oneEvent)

        #expect(try await rig.backend.waitForAccessibilityChange(on: Self.device, timeout: .milliseconds(200)) == false)
        #expect(rig.sleeps.sleeps == [.milliseconds(200)])
        #expect(rig.server.connectionAttempts == 0)
    }

    @Test("under the uiautomator fallback, the wait sleeps the interval")
    func fallback() async throws {
        let rig = try HelperRig(environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        _ = try await rig.read()

        #expect(try await rig.backend.waitForAccessibilityChange(on: Self.device, timeout: .milliseconds(200)) == false)
        #expect(rig.sleeps.sleeps == [.milliseconds(200)])
        #expect(!rig.device.ops.contains("events"))
    }

    @Test("an events request the helper refuses falls back to sleeping the interval")
    func refused() async throws {
        let device = FakeHelperDevice()
        let rig = try HelperRig(device)
        _ = try await rig.read()

        #expect(try await rig.backend.waitForAccessibilityChange(on: Self.device, timeout: .milliseconds(200)) == false)
        #expect(rig.device.ops.contains("events"))
        #expect(rig.sleeps.sleeps == [.milliseconds(200)])
        await rig.backend.close()
    }
}
