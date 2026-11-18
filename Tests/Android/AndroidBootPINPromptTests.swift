import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android boot PIN prompt")
@MainActor
struct AndroidBootPINPromptTests {
    /// What `BootPINPrompt.script` prints on an API 28 AVD with full-disk encryption, waiting at "To start Android, enter your PIN".
    nonisolated static let prompt = "boot_pin=encrypted,block,trigger_restart_min_framework,\n"
    /// The same AVD once the PIN is in, and an API 36 AVD with file-based encryption.
    nonisolated static let decrypted = "boot_pin=encrypted,block,trigger_restart_framework,\n"
    nonisolated static let fileBased = "boot_pin=encrypted,file,,\n"

    @Test("only full-disk encryption's minimal framework, with no encryption under way, is the PIN prompt", arguments: [
        (AndroidBootPINPromptTests.prompt, true),
        ("boot_pin=encrypted,,trigger_restart_min_framework,\n", true),
        (AndroidBootPINPromptTests.decrypted, false),
        ("boot_pin=encrypted,block,trigger_reset_main,\n", false),
        ("boot_pin=unencrypted,,trigger_restart_min_framework,42\n", false),
        ("boot_pin=encrypted,block,trigger_restart_min_framework,0\n", false),
        (AndroidBootPINPromptTests.fileBased, false),
        ("boot_pin=encrypted,file,trigger_restart_min_framework,\n", false),
        ("boot_pin=,,,\n", false),
        ("boot_pin=encrypted,block,trigger_restart_min_framework\n", false),
        ("arm64-v8a\n0\nnull\n", false),
    ] as [(String, Bool)])
    func parse(output: String, showing: Bool) {
        #expect(BootPINPrompt.isShowing(output) == showing)
    }

    @Test("the script prints the four properties the parser reads, an unset one as empty", arguments: [
        (["ro.crypto.state": "encrypted", "ro.crypto.type": "block", "vold.decrypt": "trigger_restart_min_framework"], true),
        (["ro.crypto.state": "encrypted", "ro.crypto.type": "file"], false),
        ([:], false),
    ] as [([String: String], Bool)])
    func scriptOnDevice(properties: [String: String], showing: Bool) throws {
        let output = try DeviceShellSandbox(properties: properties).run(BootPINPrompt.script)
        #expect(output.hasPrefix("boot_pin="))
        #expect(BootPINPrompt.isShowing(output) == showing)
    }

    // MARK: doctor

    @Test("doctor fails the device state at the PIN prompt, asks a person for the PIN and checks nothing else on it")
    func doctorAtPrompt() async throws {
        let rig = try AndroidDoctorProbeTests.rig(deviceScript: Self.prompt + "arm64-v8a\n0\nnull\n")
        let facts = await rig.probe.run(deviceID: AndroidDoctorProbeTests.serial)
        let device = try #require(facts.device)

        #expect(device.state == .bootPINPrompt)
        #expect(rig.device.startedProcesses == 0)
        #expect(!rig.server.services.contains { $0.contains("dumpsys") || $0.contains("reverse") })
        let checks = AndroidDoctorRules.deviceChecks(device, hostBlocker: nil)
        let state = try #require(checks.first { $0.id == .androidDeviceState })
        #expect(state.status == .fail)
        #expect(state.detail.contains("waiting for its boot PIN, so apps cannot be installed"))
        #expect(state.hint == "Ask the user: Can you enter the PIN on Offsider_E2E? Offsider never types it. Or boot an AVD that has no boot PIN.")
        #expect(checks.filter { $0.id != .androidDeviceState }.allSatisfy { $0.status == .skip && $0.detail == "requires android-device.state" })
        let summary = try #require(AndroidDoctorRules.summary(facts.host, device: device))
        #expect(summary.devices.first?.state == "Waiting for PIN")
    }

    @Test("a decrypted or file-based device stays booted, and the lines after the prompt line keep their places", arguments: [AndroidBootPINPromptTests.decrypted, AndroidBootPINPromptTests.fileBased])
    func doctorBooted(line: String) async throws {
        let rig = try AndroidDoctorProbeTests.rig(deviceScript: line + "arm64-v8a\n1\nnull\n")
        let device = try #require(await rig.probe.run(deviceID: AndroidDoctorProbeTests.serial).device)

        #expect(device.state == .booted)
        #expect(device.abi == "arm64-v8a")
        #expect(device.uiAutomation?.accessibilityEnabled == true)
        #expect(device.uiAutomation?.enabledServices == [])
    }

    @Test("a person is told to enter the PIN on the screen, an agent to ask for it, and a phone is never told to boot an AVD")
    func hints() {
        #expect(BootPINPrompt.hint(name: "Offsider_E2E", isPhysical: false, audience: .person) == "Enter the PIN on its screen; Offsider never types it. Or boot an AVD that has no boot PIN.")
        #expect(BootPINPrompt.hint(name: "Pixel 3", isPhysical: true, audience: .agent) == "Ask the user: Can you enter the PIN on Pixel 3? Offsider never types it.")
    }

    // MARK: boot and lease

    static func server(_ prompt: String, listing: String = "emulator-5556 device product:sdk model:sdk transport_id:3\n") -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556", "R58M123ABC"],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: listing)
                default: return .hang
                }
            },
            device: { _, service in
                if service.hasSuffix(BootPINPrompt.script) { return FakeAdbServer.shell(stdout: prompt) }
                if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) { return FakeAdbServer.shell(stdout: "Offsider_E2E\n\n1\n9\n28\n") }
                return FakeAdbServer.shell(status: 1)
            }
        ))
    }

    @Test("boot's read answers in one round trip: true at the prompt, false once decrypted or when nothing answers")
    func booterRead() async throws {
        let home = try AndroidTestHost.homeWithSDK()
        let atPrompt = Self.server(Self.prompt)
        #expect(await EmulatorBooter(host: AndroidTestHost.make(home: home, adb: atPrompt)) { _, _ in }.bootPINPromptShowing(serial: "emulator-5556"))
        #expect(AndroidAwakeStateTests.shellCommands(atPrompt) == [BootPINPrompt.script])
        #expect(await !EmulatorBooter(host: AndroidTestHost.make(home: home, adb: Self.server(Self.decrypted))) { _, _ in }.bootPINPromptShowing(serial: "emulator-5556"))
        let none = FakeAdbServer(connect: .refuse) { _ in .hang }
        #expect(await !EmulatorBooter(host: AndroidTestHost.make(home: home, adb: none)) { _, _ in }.bootPINPromptShowing(serial: "emulator-5556"))
    }

    @Test("lease's read takes an emulator by serial or AVD name, and sends a phone nothing")
    func backendRead() async throws {
        let home = try AndroidTestHost.homeWithSDK()
        let bySerial = Self.server(Self.prompt)
        #expect(await AndroidBackend(host: AndroidTestHost.make(home: home, adb: bySerial)) { _, _ in }.bootPINPromptShowing("emulator-5556"))
        let shutDown = Self.server(Self.prompt)
        #expect(await !AndroidBackend(host: AndroidTestHost.make(home: home, adb: shutDown)) { _, _ in }.bootPINPromptShowing("Offsider_E2E"))
        #expect(shutDown.connectionAttempts == 0)
        EmulatorBootTests.writeDiscovery(pid: 900, in: home)
        #expect(await AndroidBackend(host: AndroidTestHost.make(home: home, adb: Self.server(Self.prompt), liveProcesses: [900])) { _, _ in }.bootPINPromptShowing("Offsider_E2E"))

        let phone = Self.server(Self.prompt, listing: "R58M123ABC device usb:1-1 model:Pixel_3 transport_id:2\n")
        #expect(await !AndroidBackend(host: AndroidTestHost.make(home: home, adb: phone)) { _, _ in }.bootPINPromptShowing("R58M123ABC"))
        #expect(AndroidAwakeStateTests.shellCommands(phone).isEmpty)
        let disguised = Self.server(Self.prompt, listing: "emulator-5556 device usb:1-1 model:Pixel_3 transport_id:2\n")
        #expect(await !AndroidBackend(host: AndroidTestHost.make(home: home, adb: disguised)) { _, _ in }.bootPINPromptShowing("emulator-5556"))
        #expect(AndroidAwakeStateTests.shellCommands(disguised).isEmpty)
    }

    @Test("the warning asks a person for the PIN by the device's name and never offers to type it")
    func notice() {
        let notice = BootPINPrompt.notice(name: "Offsider_E2E")
        #expect(notice.kind == .warning)
        #expect(notice.text == "Offsider_E2E is waiting for its boot PIN; enter it on its screen before installing apps")
        #expect(notice.agentText == "Offsider_E2E is waiting for its boot PIN, so apps cannot be installed. Ask the user: Can you enter the PIN on Offsider_E2E? Offsider never types it. Or boot an AVD that has no boot PIN.")
        #expect(notice.command == nil)
        #expect(BootPINPrompt.notice(name: "AVD\u{1B}[2J").agentText?.contains("\u{1B}") == false)
    }
}
