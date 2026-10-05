import Foundation
import Testing

@Suite("Android E2E guard")
struct AndroidE2EGuardTests {
    private let allowed: Set<String> = ["Offsider_E2E_Pixel_9", "Offsider_E2E_Pixel_9_Pro_Fold"]

    private func refused(_ result: Result<String, AndroidE2EError>) -> String? {
        if case .failure(let error) = result { return error.description }
        return nil
    }

    @Test("a USB or network serial is refused before any adb call, even when OFFSIDER_ANDROID_DEVICE names it", arguments: [
        "R5CRFAKE03", "R58M123ABC", "192.168.1.5:5555", "emulator-", "emulator-55a4",
    ])
    func phoneRefused(serial: String) {
        let early = AndroidE2EGuard.preflight(serial: serial, expected: "Offsider_E2E_Pixel_9", allowed: allowed)
        guard case .failure = early else {
            Issue.record("\(serial) passed the preflight")
            return
        }
        let message = refused(AndroidE2EGuard.verdict(serial: serial, avdName: "Offsider_E2E_Pixel_9", expected: "Offsider_E2E_Pixel_9", allowed: allowed))
        #expect(message?.contains("only emulator-N serials") == true)
    }

    @Test("an emulator answering another AVD name, or none, is refused")
    func otherAVDRefused() {
        #expect(refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: "Pixel_9a_Native", expected: "Offsider_E2E_Pixel_9", allowed: allowed))?.contains("Pixel_9a_Native") == true)
        #expect(refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: nil, expected: "Offsider_E2E_Pixel_9", allowed: allowed)) != nil)
        #expect(refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: "", expected: "Offsider_E2E_Pixel_9", allowed: allowed)) != nil)
    }

    @Test("an OFFSIDER_ANDROID_E2E_AVD outside the allowed set is refused, even when the emulator answers it")
    func expectedOutsideAllowedRefused() {
        let message = refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: "Pixel_9a_Native", expected: "Pixel_9a_Native", allowed: allowed))
        #expect(message?.contains("is not one of the E2E AVDs") == true)
        guard case .failure = AndroidE2EGuard.preflight(serial: nil, expected: "Pixel_9a_Native", allowed: allowed) else {
            Issue.record("an AVD-name lookup for a disallowed AVD passed the preflight")
            return
        }
    }

    @Test("only an emulator answering an allowed, expected AVD name passes")
    func allowedPasses() throws {
        #expect(try AndroidE2EGuard.verdict(serial: "emulator-5556", avdName: "Offsider_E2E_Pixel_9", expected: "Offsider_E2E_Pixel_9", allowed: allowed).get() == "emulator-5556")
        #expect(try AndroidE2EGuard.verdict(serial: "emulator-5558", avdName: "Offsider_E2E_Pixel_9_Pro_Fold", expected: "Offsider_E2E_Pixel_9_Pro_Fold", allowed: allowed).get() == "emulator-5558")
    }

    @Test("E2E suites reach Android devices only through the guard")
    func suitesUseTheGuard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try ["AndroidE2E", "ReactNativeE2E"].flatMap { folder in
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
        }
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AndroidE2ESupport.swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("\"-s\"") || line.contains("-s \\(") {
                #expect(line.contains("AndroidE2E.serial()"), "\(file.lastPathComponent) passes a serial to adb without the guard: \(line)")
            }
            #expect(!source.contains("environment[\"OFFSIDER_ANDROID_DEVICE\"]"), "\(file.lastPathComponent) reads OFFSIDER_ANDROID_DEVICE directly")
        }
    }
}

@Suite("Android phone E2E guard")
struct AndroidPhoneGuardTests {
    private static let devices = """
    List of devices attached
    emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
    R5CRFAKE01            device usb:1-1 product:q2qksx model:SM_F926B device:q2q transport_id:4
    R5CRFAKE01X           device usb:1-2 product:q2qksx model:SM_F926B device:q2q transport_id:5
    ZYFAKE0002             unauthorized usb:2-1 transport_id:6
    192.168.1.5:5555       device product:pixel model:Pixel_8 device:shiba transport_id:7
    NOUSB0001              device product:x model:y device:z transport_id:8
    """

    private func refused(_ result: Result<String, AndroidE2EError>) -> String? {
        if case .failure(let error) = result { return error.description }
        return nil
    }

    @Test("the exact serial in state device with a usb: field passes, and only that serial is returned")
    func exactUSBSerialPasses() throws {
        #expect(try AndroidPhoneGuard.verdict(requested: "R5CRFAKE01", emulatorE2E: false, devices: Self.devices).get() == "R5CRFAKE01")
    }

    @Test("a serial that is only a prefix of a listed one is refused, never matched to the longer serial")
    func prefixRefused() {
        #expect(refused(AndroidPhoneGuard.verdict(requested: "RFCRA0TCR5", emulatorE2E: false, devices: Self.devices))?.contains("does not list it") == true)
    }

    @Test("an unauthorised phone, or one with no usb: field, is refused")
    func stateAndTransportRefused() {
        #expect(refused(AndroidPhoneGuard.verdict(requested: "ZYFAKE0002", emulatorE2E: false, devices: Self.devices))?.contains("unauthorized") == true)
        #expect(refused(AndroidPhoneGuard.verdict(requested: "NOUSB0001", emulatorE2E: false, devices: Self.devices))?.contains("no usb: field") == true)
    }

    @Test("an emulator or network serial is refused before any adb call", arguments: ["emulator-5554", "192.168.1.5:5555", "R5 CR", "a;b"])
    func shapeRefused(serial: String) {
        guard case .failure = AndroidPhoneGuard.preflight(requested: serial, emulatorE2E: false) else {
            Issue.record("\(serial) passed the preflight")
            return
        }
    }

    @Test("the phone guard refuses to run beside the emulator suites, even for a listed phone")
    func refusesWithEmulatorE2E() {
        let message = refused(AndroidPhoneGuard.verdict(requested: "R5CRFAKE01", emulatorE2E: true, devices: Self.devices))
        #expect(message?.contains("OFFSIDER_ANDROID_E2E") == true)
    }

    @Test("the phone suites never send emu commands")
    func phoneSuitesSendNoEmu() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AndroidE2E/AndroidPhoneTests.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("emu "), "AndroidPhoneTests.swift sends an emulator console command")
        #expect(!source.contains("emulatorClient"), "AndroidPhoneTests.swift reaches for the emulator gRPC client")
    }
}
