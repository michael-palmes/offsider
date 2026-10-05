import Darwin
import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("Device session hardware listing")
@MainActor
struct CoreDeviceSessionHardwareTests {
    static func listing(_ fixture: String) throws -> ProcessCaptureResult {
        ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text(fixture), stderr: "")
    }

    /// CoreDevice below the HID floor stops each open after it has picked the device to open, before anything reaches CoreDevice.
    static func hardware(_ devicectl: FakeDevicectl) -> CoreDeviceSessionHardware {
        CoreDeviceSessionHardware(udid: IOSDeviceFixtures.phone, host: .fake(devicectl), version: CoreDeviceVersion("518.24"), log: { _, _ in })
    }

    static func listings(_ devicectl: FakeDevicectl) -> Int {
        devicectl.calls.filter { $0.first == "list" }.count
    }

    @Test("a button link reopens only after a fresh listing; one showing the device off USB refuses the input and ends the broker")
    func reopenListsAgain() async throws {
        let devicectl = FakeDevicectl(
            replies: ["list": try Self.listing("devicectl-list-xcode27-connected.json")],
            queued: ["list": [try Self.listing("devicectl-list-xcode26.json")]]
        )
        let hardware = Self.hardware(devicectl)
        let first = await #expect(throws: IOSDeviceError.self) { try await hardware.press(usagePage: 12, usageCode: 0x40, hold: 0, abandoned: { false }) }
        #expect(first?.kind == .xcodeTooOld)
        #expect(await hardware.checkHealth())

        let reopen = await #expect(throws: IOSDeviceError.self) { try await hardware.press(usagePage: 12, usageCode: 0x40, hold: 0, abandoned: { false }) }
        #expect(reopen?.kind == .notWired)
        #expect(Self.listings(devicectl) == 2)
        #expect(await hardware.checkHealth() == false)
    }

    @Test("the touch input and stream opens at start share one device listing")
    func startListsOnce() async throws {
        let devicectl = FakeDevicectl(replies: ["list": try Self.listing("devicectl-list-xcode26.json")]) { arguments in
            if arguments.first == "list" { usleep(200_000) }
        }
        let hardware = Self.hardware(devicectl)
        await hardware.start()
        #expect(Self.listings(devicectl) == 1)
        #expect(hardware.label != nil)
    }
}
