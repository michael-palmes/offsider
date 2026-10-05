import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android phone label")
struct AndroidPhoneLabelTests {
    nonisolated static let rows = """
    ZY22FAKE01             device usb:0-1 product:mumba_gn model:moto_g57 device:mumba transport_id:5
    R5CRFAKE03            unauthorized usb:1-2 transport_id:14
    emulator-5556          device product:sdk_gphone16k_arm64 model:sdk_gphone16k_arm64 device:emu64a16k transport_id:6

    """

    static func label(_ serial: String, manufacturer: FakeAdbServer.Reply = FakeAdbServer.shell(stdout: "motorola\n")) async throws -> (String?, FakeAdbServer) {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["ZY22FAKE01", "R5CRFAKE03", "emulator-5556"],
            host: { $0 == "host:devices-l" ? FakeAdbServer.okay(payload: rows) : $0 == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, _ in manufacturer }
        ))
        let host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        return (await AndroidPhoneLabel.label(serial: serial, host: host), server)
    }

    @Test("a connected phone is named by its maker and listed model")
    func connectedPhone() async throws {
        let (label, server) = try await Self.label("ZY22FAKE01")
        #expect(label == "Motorola moto g57")
        #expect(server.services.contains("shell,v2,raw:getprop ro.product.manufacturer"))
    }

    @Test("an unauthorised phone is never queried, an emulator or unknown serial gets no label, and a failed read falls back to the model")
    func fallbacks() async throws {
        let (unauthorised, server) = try await Self.label("R5CRFAKE03")
        #expect(unauthorised == nil)
        #expect(!server.requests.contains { $0.serial == "R5CRFAKE03" })
        #expect(try await Self.label("emulator-5556").0 == nil)
        #expect(try await Self.label("NOTLISTED").0 == nil)
        #expect(try await Self.label("ZY22FAKE01", manufacturer: FakeAdbServer.shell(status: 1)).0 == "moto g57")
    }
}
