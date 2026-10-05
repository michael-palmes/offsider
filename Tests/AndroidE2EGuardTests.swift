import Foundation
import Testing

@Suite("Android E2E guard")
struct AndroidE2EGuardTests {
    private let allowed: Set<String> = ["Offsider_E2E", "Offsider_E2E_Fold"]

    private func refused(_ result: Result<String, AndroidE2EError>) -> String? {
        if case .failure(let error) = result { return error.description }
        return nil
    }

    @Test("a USB or network serial is refused before any adb call, even when OFFSIDER_ANDROID_DEVICE names it", arguments: [
        "R5CRFAKE03", "R58M123ABC", "192.168.1.5:5555", "emulator-", "emulator-55a4",
    ])
    func phoneRefused(serial: String) {
        let early = AndroidE2EGuard.preflight(serial: serial, expected: "Offsider_E2E", allowed: allowed)
        guard case .failure = early else {
            Issue.record("\(serial) passed the preflight")
            return
        }
        let message = refused(AndroidE2EGuard.verdict(serial: serial, avdName: "Offsider_E2E", expected: "Offsider_E2E", allowed: allowed))
        #expect(message?.contains("only emulator-N serials") == true)
    }

    @Test("an emulator answering another AVD name, or none, is refused")
    func otherAVDRefused() {
        #expect(refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: "Work_Pixel", expected: "Offsider_E2E", allowed: allowed))?.contains("Work_Pixel") == true)
        #expect(refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: nil, expected: "Offsider_E2E", allowed: allowed)) != nil)
        #expect(refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: "", expected: "Offsider_E2E", allowed: allowed)) != nil)
    }

    @Test("an OFFSIDER_ANDROID_E2E_AVD outside the allowed set is refused, even when the emulator answers it")
    func expectedOutsideAllowedRefused() {
        let message = refused(AndroidE2EGuard.verdict(serial: "emulator-5554", avdName: "Work_Pixel", expected: "Work_Pixel", allowed: allowed))
        #expect(message?.contains("is not one of the E2E AVDs") == true)
        guard case .failure = AndroidE2EGuard.preflight(serial: nil, expected: "Work_Pixel", allowed: allowed) else {
            Issue.record("an AVD-name lookup for a disallowed AVD passed the preflight")
            return
        }
    }

    @Test("only an emulator answering an allowed, expected AVD name passes")
    func allowedPasses() throws {
        #expect(try AndroidE2EGuard.verdict(serial: "emulator-5556", avdName: "Offsider_E2E", expected: "Offsider_E2E", allowed: allowed).get() == "emulator-5556")
        #expect(try AndroidE2EGuard.verdict(serial: "emulator-5558", avdName: "Offsider_E2E_Fold", expected: "Offsider_E2E_Fold", allowed: allowed).get() == "emulator-5558")
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
    R5CRFAKE01            device usb:1-1 product:f0ldksx model:SM_F000B device:f0ld transport_id:4
    R5CRFAKE01X           device usb:1-2 product:f0ldksx model:SM_F000B device:f0ld transport_id:5
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
        #expect(try AndroidPhoneGuard.verdict(requested: "R5CRFAKE01", emulatorFlags: [], devices: Self.devices).get() == "R5CRFAKE01")
    }

    @Test("a serial that is only a prefix of a listed one is refused, never matched to the longer serial")
    func prefixRefused() {
        #expect(refused(AndroidPhoneGuard.verdict(requested: "RFCRA0TCR5", emulatorFlags: [], devices: Self.devices))?.contains("does not list it") == true)
    }

    @Test("an unauthorised phone, or one with no usb: field, is refused")
    func stateAndTransportRefused() {
        #expect(refused(AndroidPhoneGuard.verdict(requested: "ZYFAKE0002", emulatorFlags: [], devices: Self.devices))?.contains("unauthorized") == true)
        #expect(refused(AndroidPhoneGuard.verdict(requested: "NOUSB0001", emulatorFlags: [], devices: Self.devices))?.contains("no usb: field") == true)
    }

    @Test("an emulator or network serial is refused before any adb call", arguments: ["emulator-5554", "192.168.1.5:5555", "R5 CR", "a;b"])
    func shapeRefused(serial: String) {
        guard case .failure = AndroidPhoneGuard.preflight(requested: serial, emulatorFlags: []) else {
            Issue.record("\(serial) passed the preflight")
            return
        }
    }

    @Test("the phone guard refuses to run beside any emulator suite, even for a listed phone", arguments: [
        "OFFSIDER_ANDROID_E2E", "OFFSIDER_ANDROID_FOLD_E2E", "OFFSIDER_ANDROID_LANDSCAPE_E2E", "OFFSIDER_ANDROID_BOOT_E2E",
    ])
    func refusesWithEmulatorSuites(flag: String) {
        let set = AndroidPhoneGuard.emulatorFlagsSet(in: [flag: "1", "OFFSIDER_ANDROID_PHONE": "R5CRFAKE01"])
        let message = refused(AndroidPhoneGuard.verdict(requested: "R5CRFAKE01", emulatorFlags: set, devices: Self.devices))
        #expect(message?.contains(flag) == true)
    }

    @Test("emulator switches set to 0 or left empty do not block the phone suites")
    func offSwitchesAllowed() throws {
        let set = AndroidPhoneGuard.emulatorFlagsSet(in: ["OFFSIDER_ANDROID_E2E": "0", "OFFSIDER_ANDROID_FOLD_E2E": ""])
        #expect(try AndroidPhoneGuard.verdict(requested: "R5CRFAKE01", emulatorFlags: set, devices: Self.devices).get() == "R5CRFAKE01")
    }

    @Test("every non-phone runner in test-runner.sh drops OFFSIDER_ANDROID_PHONE, and the phone runner turns the emulator suites off")
    func runnerDropsPhone() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("test-runner.sh")
        let script = try String(contentsOf: url, encoding: .utf8)
        func body(_ name: String) throws -> Substring {
            let start = try #require(script.range(of: "\n\(name)() {\n"))
            let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
            return script[start.upperBound..<end.lowerBound]
        }
        for runner in ["run_unit_tests", "run_rn_ios_tests", "run_android_tests", "run_android_fold_tests", "run_foldable_tests", "run_tests", "run_ios_device_tests"] {
            let text = try body(runner)
            #expect(text.split(separator: "\n").contains { $0.contains("unset ") && $0.contains("OFFSIDER_ANDROID_PHONE") }, "\(runner) leaves OFFSIDER_ANDROID_PHONE set")
        }
        let phone = try body("run_android_phone_tests")
        for flag in AndroidPhoneGuard.emulatorFlags {
            #expect(phone.contains("export \(flag)=0"), "run_android_phone_tests leaves \(flag) as it was")
        }
    }

    @Test("the phone suites never send emu commands")
    func phoneSuitesSendNoEmu() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AndroidE2E/AndroidPhoneTests.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("emu "), "AndroidPhoneTests.swift sends an emulator console command")
        #expect(!source.contains("emulatorClient"), "AndroidPhoneTests.swift reaches for the emulator gRPC client")
    }
}
