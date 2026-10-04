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
        "R58TEST0001", "R58M123ABC", "192.168.1.5:5555", "emulator-", "emulator-55a4",
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
