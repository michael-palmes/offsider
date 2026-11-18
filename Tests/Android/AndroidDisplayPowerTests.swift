import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// Runs a device script with /bin/sh and stand-ins for `getprop` and `dumpsys`, so its own `grep` meets whole hand-written dumps.
struct DeviceShellSandbox {
    let root: URL

    /// `properties` answers `getprop <name>` (an empty line when unset); `dumps` answers `dumpsys <service>`.
    init(properties: [String: String] = [:], dumps: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-device-shell-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try properties.map { "\($0.key)=\($0.value)\n" }.joined().write(to: root.appendingPathComponent("props"), atomically: true, encoding: .utf8)
        for (service, dump) in dumps {
            try dump.write(to: root.appendingPathComponent("dumpsys-\(service)"), atomically: true, encoding: .utf8)
        }
        try Self.tool(bin.appendingPathComponent("getprop"), #"/usr/bin/awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found = 1; exit } END { if (!found) print "" }' "$SANDBOX/props""#)
        try Self.tool(bin.appendingPathComponent("dumpsys"), #"[ -f "$SANDBOX/dumpsys-$1" ] && exec cat "$SANDBOX/dumpsys-$1"; exit 0"#)
    }

    private static func tool(_ url: URL, _ body: String) throws {
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func run(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "SANDBOX": root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Android display power")
@MainActor
struct AndroidDisplayPowerTests {
    nonisolated static let phone = "ZY22FAKE01"

    /// Hand-written: a phone charging over USB with Stay awake on, just after its power button. Android still reads it awake; the panel is dark.
    nonisolated static let powerDump = """
    POWER MANAGER (dumpsys power)

    Power Manager State:
      Settings power_manager_constants:
        no_cached_wake_locks=true
      mDirty=0x0
      mWakefulness=Awake
      mWakefulnessChanging=false
      mIsPowered=true
      mPlugType=2
      mBatteryLevel=100
      mStayOn=true
      mProximityPositive=false
      mBootCompleted=true
      mScreenOffTimeoutSetting=30000
      mMaximumScreenOffTimeoutFromDeviceAdmin=9223372036854775807 (enforced=false)
      mStayOnWhilePluggedInSetting=15
      mScreenBrightnessSetting=102

    Display Power: state=OFF

    Wake Locks: size=0

    """

    nonisolated static let windowPolicyDump = """
    WINDOW MANAGER POLICY STATE (dumpsys window policy)
        mKeyguardDelegate
          showing=false
          occluded=false
          secure=false

    """

    nonisolated static let lockSettingsDump = """
    Lock Settings Service
      User State:
        User 0
          CredentialType: NONE

    """

    /// `AndroidAwakeState.readScript` as the phone prints it, wakefulness and display state as given.
    nonisolated static func reading(wakefulness: String = "Awake", display: String? = "OFF") -> String {
        """
        maker=motorola
          mWakefulness=\(wakefulness)
          mIsPowered=true
          mPlugType=2
          mScreenOffTimeoutSetting=30000
          mStayOnWhilePluggedInSetting=15
        \(display.map { "Display Power: state=\($0)" } ?? "")
              showing=false
              occluded=false
              secure=false
            CredentialType: NONE

        """
    }

    @Test("a phone that reads awake with its panel off reads off, so input would not reach the app")
    func awakeButDark() throws {
        let reading = try #require(AndroidAwakeState.parse(Self.reading()))
        #expect(reading.screen == .off)
        #expect(!reading.isUsable)
        #expect(reading.screenSummary == "off and unlocked")
    }

    @Test("the display state darkens a screen wakefulness calls on, and a missing or lit display keeps wakefulness", arguments: [
        ("Awake", "OFF", ScreenPower.off), ("Awake", "DOZE", .dozing), ("Awake", "DOZE_SUSPEND", .dozing), ("Awake", "ON", .on),
        ("Awake", "UNKNOWN", .on), ("Awake", nil, .on), ("Asleep", "ON", .off), ("Dreaming", "ON", .dreaming), ("Dozing", "OFF", .off),
    ] as [(String, String?, ScreenPower)])
    func displayDecides(wakefulness: String, display: String?, expected: ScreenPower) throws {
        #expect(try #require(AndroidAwakeState.parse(Self.reading(wakefulness: wakefulness, display: display))).screen == expected)
    }

    @Test("the one awake read picks the display state out of a whole power dump, and nothing like it")
    func readScriptFindsDisplayLine() throws {
        let sandbox = try DeviceShellSandbox(
            properties: ["ro.product.manufacturer": "motorola"],
            dumps: ["power": Self.powerDump, "window": Self.windowPolicyDump, "lock_settings": Self.lockSettingsDump]
        )
        let output = try sandbox.run(AndroidAwakeState.readScript)

        #expect(output.contains("Display Power: state=OFF"))
        #expect(!output.contains("mWakefulnessChanging") && !output.contains("mStayOn=") && !output.contains("Wake Locks"))
        let reading = try #require(AndroidAwakeState.parse(output))
        #expect(reading.screen == .off)
        #expect(reading.stayAwake == PowerSources(rawValue: 15))
        #expect(reading.charging == [.usb])
    }

    @Test("doctor warns about a dark panel on an awake phone and names wake as the fix")
    func doctorWarns() throws {
        let reading = try #require(AndroidAwakeState.parse(Self.reading()))
        let verdict = AndroidDoctorRules.screen(reading, deviceID: Self.phone)
        #expect(verdict.status == .warn)
        #expect(verdict.hint == "Run `offsider wake --device \(Self.phone)`.")
    }

    @Test("a front-app refusal on an awake phone with a dark panel becomes screen_off, in one awake read")
    func refusalBecomesScreenOff() async throws {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            [Self.phone],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: "\(Self.phone) device usb:1-1 product:fake model:moto_g transport_id:2\n")
                default: return .hang
                }
            },
            device: { _, service in
                service == AndroidAwakeStateTests.shellPrefix + AndroidAwakeState.readScript ? FakeAdbServer.shell(stdout: Self.reading()) : FakeAdbServer.shell(status: 1)
            }
        ))
        let backend = AndroidBackend(host: AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)) { _, _ in }
        let route = DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: Self.phone, platform: .android))
        let refusal = AndroidError(.otherAppInFront, "com.android.systemui is part of the system UI, which Offsider never drives on a physical phone.")

        let annotated = try #require(await ScreenStateHint.annotate(refusal, routes: [route], store: MemoryUnlockCodeStore()) as? ScreenStateFailure)
        #expect(annotated.reason == .screenOff)
        #expect(annotated.hint == "offsider wake --device \(Self.phone)")
        #expect(AndroidAwakeStateTests.shellCommands(server) == [AndroidAwakeState.readScript])
    }
}
