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

/// A UniversalHID link that keeps what it was handed; `beforeSend` runs before a report is counted, where a test ends the connection.
@MainActor
final class FakeHIDLink: UniversalHIDLink {
    private(set) var sentCount = 0
    var endedAfter: Int?
    var invalidatedAfter: Int?
    private(set) var reports: [Data] = []
    private(set) var closed = false
    var beforeSend: ((FakeHIDLink) -> Void)?

    func send(_ report: Data, to serviceID: UInt64) {
        beforeSend?(self)
        sentCount += 1
        if endedAfter == nil { reports.append(report) }
    }

    func confirm() async throws {
        sentCount += 1
        if endedAfter != nil { throw IOSDeviceError.hidFailed("iPhone", udid: IOSDeviceFixtures.phone, detail: "the link closed", sent: true) }
    }

    func close() { closed = true }
}

@Suite("Device session input on a link that ended")
@MainActor
struct DeviceSessionEndedLinkTests {
    static let key: [DeviceSessionStep] = [.key(4, down: true), .key(4, down: false)]

    /// Hardware whose HID opens hand out `links` in order.
    static func hardware(_ links: [FakeHIDLink]) throws -> CoreDeviceSessionHardware {
        // The one listing fixture that shows the phone on USB.
        let devicectl = FakeDevicectl(replies: ["list": try CoreDeviceSessionHardwareTests.listing("devicectl-list-xcode26.json")])
        let hardware = CoreDeviceSessionHardware(udid: IOSDeviceFixtures.phone, host: .fake(devicectl), version: CoreDeviceVersion("651.32"), log: { _, _ in })
        var remaining = links
        hardware.connectHID = { _, _, _, _ in
            guard !remaining.isEmpty else { throw IOSDeviceError.hidFailed("iPhone", udid: IOSDeviceFixtures.phone, detail: "no link left", sent: false) }
            return (remaining.removeFirst(), [])
        }
        return hardware
    }

    /// The connection is invalidated now: before the next message is handed over.
    static func invalidate(_ link: FakeHIDLink) {
        guard link.endedAfter == nil else { return }
        link.endedAfter = link.sentCount
        link.invalidatedAfter = link.sentCount
    }

    @Test("a link that reported any error while idle is replaced before the next input, which goes once, on the new link", arguments: [true, false])
    func endedWhileIdle(invalidated: Bool) async throws {
        let (first, second) = (FakeHIDLink(), FakeHIDLink())
        let hardware = try Self.hardware([first, second])
        try await hardware.keys(Self.key, abandoned: { false })
        first.endedAfter = first.sentCount
        if invalidated { first.invalidatedAfter = first.sentCount }

        try await hardware.keys(Self.key, abandoned: { false })
        #expect(first.reports.count == 2)
        #expect(first.closed)
        #expect(second.reports.count == 2)
    }

    @Test("a link invalidated before the input's first report was handed over resends the input once, on a new link")
    func endedBeforeFirstReport() async throws {
        let (first, second) = (FakeHIDLink(), FakeHIDLink())
        first.beforeSend = Self.invalidate
        let hardware = try Self.hardware([first, second])

        try await hardware.keys(Self.key, abandoned: { false })
        #expect(first.reports.isEmpty)
        #expect(second.reports.count == 2)
    }

    @Test("an error before the first report that is not an invalidation is never resent, as the link may still have carried the input")
    func errorWithoutInvalidation() async throws {
        let (first, second) = (FakeHIDLink(), FakeHIDLink())
        first.beforeSend = { link in if link.endedAfter == nil { link.endedAfter = link.sentCount } }
        let hardware = try Self.hardware([first, second])

        let failure = await #expect(throws: IOSDeviceError.self) { try await hardware.keys(Self.key, abandoned: { false }) }
        #expect(failure?.kind == .hidFailed)
        #expect(second.reports.isEmpty)
    }

    @Test("a link invalidated after the first report is never resent: the input fails, and no other link is sent it")
    func endedAfterFirstReport() async throws {
        let (first, second) = (FakeHIDLink(), FakeHIDLink())
        first.beforeSend = { link in if link.sentCount == 1 { Self.invalidate(link) } }
        let hardware = try Self.hardware([first, second])

        let failure = await #expect(throws: IOSDeviceError.self) { try await hardware.keys(Self.key, abandoned: { false }) }
        #expect(failure?.kind == .hidFailed)
        #expect(first.reports.count == 1)
        #expect(second.reports.isEmpty)
    }

    @Test("a second link that also ends before the first report fails the input instead of trying a third")
    func resendsOnlyOnce() async throws {
        let links = (0..<3).map { _ in FakeHIDLink() }
        for link in links.prefix(2) { link.beforeSend = Self.invalidate }
        let hardware = try Self.hardware(links)

        let failure = await #expect(throws: IOSDeviceError.self) { try await hardware.keys(Self.key, abandoned: { false }) }
        #expect(failure?.kind == .hidFailed)
        #expect(links[2].reports.isEmpty)
    }
}
