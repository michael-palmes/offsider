import Foundation
import Testing

@Suite("Android E2E guard")
struct AndroidE2EGuardTests {
    private let allowed: Set<String> = ["Offsider_E2E", "Offsider_E2E_Fold", "Offsider_E2E_API28"]

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

    @Test("the Android 9 AVD passes only when OFFSIDER_ANDROID_E2E_AVD names it")
    func android9AVD() throws {
        #expect(AndroidE2E.allowedAVDs.contains("Offsider_E2E_API28"))
        let named = AndroidE2EGuard.verdict(serial: "emulator-5560", avdName: "Offsider_E2E_API28", expected: "Offsider_E2E_API28", allowed: AndroidE2E.allowedAVDs)
        #expect(try named.get() == "emulator-5560")
        let unnamed = AndroidE2EGuard.verdict(serial: "emulator-5560", avdName: "Offsider_E2E_API28", expected: "Offsider_E2E", allowed: AndroidE2E.allowedAVDs)
        #expect(refused(unnamed)?.contains("Offsider_E2E_API28") == true)
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

@Suite("Physical device E2E allowance")
struct E2EDeviceAllowanceTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let phone = "R58M123ABC"

    static func status(expires: String?, apps: [String] = [], allowed: Bool = true, id: String = phone) -> String {
        let expiry = expires.map { "\"\($0)\"" } ?? "null"
        let list = apps.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"version":1,"devices":[{"platform":"android","id":"\#(id)","name":"Pixel 9","added":"2026-09-21T12:00:00Z","expires":\#(expiry),"apps":[\#(list)],"active":\#(allowed)}],"allowed":\#(allowed),"refusal":null}"#
    }

    @Test("a device the CLI refuses stops the run and quotes the exact command a person runs")
    func notAllowed() {
        let message = E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 7, json: "", now: Self.now)
        #expect(message?.contains("`offsider device-access allow --device R58M123ABC --expires 2h`") == true)
        #expect(message?.contains("Ask the user") == true)
    }

    @Test("an allowance ending within 30 minutes is refused; one lasting longer or never ending passes")
    func expiry() {
        #expect(E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 0, json: Self.status(expires: "2026-09-21T14:33:20Z"), now: Self.now)?.contains("within 30 minutes") == true)
        #expect(E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 0, json: Self.status(expires: "2026-09-21T15:13:20Z"), now: Self.now) == nil)
        #expect(E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 0, json: Self.status(expires: nil), now: Self.now) == nil)
    }

    @Test("a status that does not report the device as allowed is refused even with exit 0")
    func notReported() {
        #expect(E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 0, json: Self.status(expires: nil, allowed: false), now: Self.now) != nil)
        #expect(E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 0, json: Self.status(expires: nil, id: "OTHER123"), now: Self.now) != nil)
        #expect(E2EDeviceAllowance.verdict(device: Self.phone, exitCode: 0, json: "not json", now: Self.now) != nil)
    }
}

@Suite("Android E2E install marker")
struct AndroidInstallMarkerTests {
    private let digest = "4f1c0de2"
    private let package = AndroidE2E.package

    @Test("a marker written for an install is current for that install", arguments: [
        "package:/data/app/\(AndroidE2E.package)-AbC_12-x==/base.apk",
        "package:/data/app/~~Zx9-Q_w==/\(AndroidE2E.package)-Kp4_Lm==/base.apk",
    ])
    func currentForItsInstall(pmPath: String) throws {
        let marker = try #require(AndroidInstallMarker.line(digest: digest, pmPath: pmPath + "\n"))
        #expect(AndroidInstallMarker.isCurrent("\(marker)\n\(pmPath)\n", digest: digest))
    }

    @Test("a build installed after the marker leaves it stale, even when the marker names the expected digest")
    func reinstallLeavesMarkerStale() throws {
        let marker = try #require(AndroidInstallMarker.line(digest: digest, pmPath: "package:/data/app/~~old==/\(package)-a==/base.apk"))
        #expect(!AndroidInstallMarker.isCurrent("\(marker)\npackage:/data/app/~~new==/\(package)-b==/base.apk\n", digest: digest))
    }

    @Test("a stale marker's own path is never taken for the current install")
    func installLineSkipsMarker() {
        let state = "\(digest) package:/data/app/~~old==/\(package)-a==/base.apk\npackage:/data/app/~~new==/\(package)-b==/base.apk\n"
        #expect(AndroidInstallMarker.installLine(in: state) == "package:/data/app/~~new==/\(package)-b==/base.apk")
    }

    @Test("a marker with no install path, another digest, no marker or no package is stale")
    func staleStates() {
        let current = "package:/data/app/~~x==/\(package)-y==/base.apk"
        #expect(!AndroidInstallMarker.isCurrent("\(digest)\n\(current)\n", digest: digest))
        #expect(!AndroidInstallMarker.isCurrent("0ddba11 \(current)\n\(current)\n", digest: digest))
        #expect(!AndroidInstallMarker.isCurrent("\(current)\n", digest: digest))
        #expect(!AndroidInstallMarker.isCurrent("\(digest) \(current)\n", digest: digest))
        #expect(!AndroidInstallMarker.isCurrent("", digest: digest))
        #expect(AndroidInstallMarker.line(digest: digest, pmPath: "") == nil)
    }
}
