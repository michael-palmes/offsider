import Foundation
import OffsiderCore
import Testing

@Suite("Android doctor rules")
struct AndroidDoctorRulesTests {
    static let sdk = AndroidSDKFact.found(root: "/sdk", source: "default location", adbPath: "/sdk/platform-tools/adb")

    static func booted(_ configure: (inout AndroidDeviceFacts) -> Void = { _ in }) -> AndroidDeviceFacts {
        var facts = AndroidDeviceFacts(id: "emulator-5556", serial: "emulator-5556", avdName: "Offsider_E2E", state: .booted)
        facts.apiLevel = 36
        facts.release = "16"
        facts.abi = "arm64-v8a"
        facts.grpc = .connected(endpoint: "127.0.0.1:8556", auth: "token", statusMilliseconds: 9, booted: true)
        facts.uiAutomation = UiAutomationFact(accessibilityEnabled: false, enabledServices: [], offsiderHelperPids: [])
        facts.helper = .ready(launchMilliseconds: 412, pushed: false, helloMilliseconds: 7, pingMilliseconds: 3, protocolVersion: 1, sdkInt: 36)
        facts.reverses = []
        configure(&facts)
        return facts
    }

    static func check(_ id: DoctorCheckID, in checks: [DoctorCheckResult]) -> DoctorCheckResult? {
        checks.first { $0.id == id }
    }

    @Test("a set ANDROID_HOME without adb fails android.sdk and names the variable")
    func variableWithoutAdb() {
        let facts = AndroidHostFacts(
            sdk: .variableWithoutAdb(variable: "ANDROID_HOME", message: "ANDROID_HOME is /nope, which has no platform-tools/adb."),
            helperBundle: .ok(version: "1.0.0", protocolVersion: 1)
        )
        let sdk = Self.check(.androidSDK, in: AndroidDoctorRules.hostChecks(facts, deviceNamed: false))
        #expect(sdk?.status == .fail)
        #expect(sdk?.hint?.contains("ANDROID_HOME") == true)
    }

    @Test("no SDK skips the Android host checks when no Android device is named")
    func noSDKQuiet() {
        let facts = AndroidHostFacts(sdk: .notFound, helperBundle: .ok(version: "1.0.0", protocolVersion: 1))
        let checks = AndroidDoctorRules.hostChecks(facts, deviceNamed: false)
        #expect(CheckStatus.aggregate(checks.map(\.status)) == .pass)
        #expect(Self.check(.androidSDK, in: checks)?.status == .skip)
        #expect(Self.check(.androidAdbServer, in: checks)?.detail == "requires android.sdk")
    }

    @Test("no SDK fails android.sdk when an Android device is named, and the device checks wait on it")
    func noSDKWithDevice() {
        let facts = AndroidHostFacts(sdk: .notFound, helperBundle: .ok(version: "1.0.0", protocolVersion: 1))
        let checks = AndroidDoctorRules.hostChecks(facts, deviceNamed: true)
            + AndroidDoctorRules.deviceChecks(nil, hostBlocker: AndroidDoctorRules.hostBlocker(facts))
        #expect(Self.check(.androidSDK, in: checks)?.status == .fail)
        #expect(Self.check(.androidDeviceState, in: checks)?.detail == "requires android.sdk")
    }

    @Test("an adb server from another SDK warns and never suggests a restart by Offsider")
    func serverFromOtherSDK() {
        let verdict = AndroidDoctorRules.adb(.version("37.0.0-1", protocolVersion: 41), server: .answering(endpoint: "127.0.0.1:5037", version: 40))
        #expect(verdict.status == .warn)
        #expect(verdict.hint?.contains("Offsider never restarts") == true)
    }

    @Test("an absent adb server warns and is the one fixable Android check")
    func absentServer() {
        var facts = AndroidHostFacts(sdk: Self.sdk, helperBundle: .ok(version: "1.0.0", protocolVersion: 1))
        facts.adb = .version("37.0.0-1", protocolVersion: 41)
        facts.server = .notRunning(endpoint: "127.0.0.1:5037")
        facts.emulatorRevision = "37.1.11"
        let checks = AndroidDoctorRules.hostChecks(facts, deviceNamed: true)
        #expect(Self.check(.androidAdbServer, in: checks)?.status == .warn)
        #expect(checks.filter(\.fixable).map(\.id) == [.androidAdbServer])
        #expect(AndroidDoctorRules.hostBlocker(facts) == .androidAdbServer)
        let plain = AndroidDoctorRules.hostChecks(facts, deviceNamed: false)
        #expect(Self.check(.androidAdbServer, in: plain)?.status == .skip)
        #expect(CheckStatus.aggregate(plain.map(\.status)) == .pass)
    }

    @Test("a non-loopback adb server setting fails")
    func badServerSetting() {
        #expect(AndroidDoctorRules.adbServer(.badSetting("ADB_SERVER_SOCKET is tcp:10.0.0.2:5037, which is not on this Mac.")).status == .fail)
    }

    @Test("active mDNS discovery warns with the ADB_MDNS hint; a disabled answer passes; an unreadable answer skips")
    func mdns() {
        let active = AndroidDoctorRules.mdns(AndroidDoctorRules.mdnsFact(fromCheckReply: "mdns daemon version [Openscreen discovery 0.0.0]"))
        #expect(active.status == .warn)
        #expect(active.hint?.contains("ADB_MDNS=0") == true)
        #expect(AndroidDoctorRules.mdns(AndroidDoctorRules.mdnsFact(fromCheckReply: "ERROR: mdns discovery disabled")).status == .pass)
        #expect(AndroidDoctorRules.mdns(AndroidDoctorRules.mdnsFact(fromCheckReply: "something new")).status == .skip)
        #expect(AndroidDoctorRules.mdns(AndroidDoctorRules.mdnsFact(fromCheckReply: "")).status == .skip)
    }

    @Test("an x86_64 image warns that Offsider supports arm64-v8a")
    func x86Image() {
        let verdict = AndroidDoctorRules.image(apiLevel: 36, release: "16", abi: "x86_64")
        #expect(verdict.status == .warn)
        #expect(verdict.hint?.contains("arm64-v8a") == true)
    }

    @Test("an emulator without a discovery file warns that commands use adb")
    func noDiscoveryFile() {
        let verdict = AndroidDoctorRules.grpc(.noDiscoveryFile(forced: false))
        #expect(verdict.status == .warn)
        #expect(verdict.detail.contains("commands use adb"))
    }

    @Test("forcing gRPC on an emulator without gRPC fails")
    func forcedGrpc() {
        #expect(AndroidDoctorRules.grpc(.noGrpcPort(forced: true)).status == .fail)
        #expect(AndroidDoctorRules.grpc(.failed("refused", forced: true)).status == .fail)
        #expect(AndroidDoctorRules.grpc(.forcedAdb).status == .skip)
    }

    @Test("a connected gRPC endpoint reports its auth mode")
    func connectedGrpc() {
        let verdict = AndroidDoctorRules.grpc(.connected(endpoint: "127.0.0.1:8556", auth: "jwt", statusMilliseconds: 12, booted: true))
        #expect(verdict.status == .pass)
        #expect(verdict.detail == "127.0.0.1:8556, jwt auth, getStatus 12 ms; commands use gRPC")
    }

    @Test("TalkBack enabled warns that taps behave differently")
    func talkBack() {
        let verdict = AndroidDoctorRules.uiAutomation(UiAutomationFact(
            accessibilityEnabled: true,
            enabledServices: ["com.google.android.marvin.talkback/.TalkBackService"],
            offsiderHelperPids: []
        ))
        #expect(verdict.status == .warn)
        #expect(verdict.detail.contains("taps"))
    }

    @Test("a running Offsider helper warns and skips the helper probe")
    func helperRunning() {
        let facts = Self.booted {
            $0.uiAutomation = UiAutomationFact(accessibilityEnabled: true, enabledServices: [], offsiderHelperPids: [4321])
            $0.helper = nil
        }
        let checks = AndroidDoctorRules.deviceChecks(facts, hostBlocker: nil)
        #expect(Self.check(.androidDeviceUiAutomation, in: checks)?.status == .warn)
        #expect(Self.check(.androidDeviceHelper, in: checks)?.status == .skip)
    }

    @Test("a busy UiAutomation slot fails and names the other clients")
    func busySlot() {
        let verdict = AndroidDoctorRules.helper(.busy("UiAutomation already registered"))
        #expect(verdict.status == .fail)
        #expect(verdict.hint?.contains("Appium") == true)
        #expect(verdict.hint?.contains("Maestro") == true)
    }

    @Test("an unavailable helper warns that reads fall back to uiautomator")
    func unavailableHelper() {
        let verdict = AndroidDoctorRules.helper(.unavailable("it did not start within 30 s"))
        #expect(verdict.status == .warn)
        #expect(verdict.detail.contains("uiautomator"))
    }

    @Test("the Metro reverse check passes whether or not a reverse exists")
    func metroReverse() {
        let none = AndroidDoctorRules.metroReverse([])
        let metro = AndroidDoctorRules.metroReverse(["host-19 tcp:8742 tcp:8742"])
        let unreadable = AndroidDoctorRules.metroReverse(nil)
        #expect([none.status, metro.status, unreadable.status] == [.pass, .pass, .pass])
        #expect(none.detail == "none")
        #expect(metro.detail == "tcp:8742 to tcp:8742 (Metro)")
    }

    @Test("a healthy booted emulator passes every device check")
    func healthyDevice() {
        let checks = AndroidDoctorRules.deviceChecks(Self.booted(), hostBlocker: nil)
        #expect(checks.map(\.id) == [
            .androidDeviceState, .androidDeviceImage, .androidDeviceGrpc, .androidDeviceUiAutomation, .androidDeviceHelper, .androidDeviceMetroReverse,
        ])
        #expect(checks.allSatisfy { $0.status == .pass })
    }

    @Test("a missing device fails android-device.state and skips the rest")
    func missingDevice() {
        let facts = AndroidDeviceFacts(id: "emulator-5560", serial: "emulator-5560", state: .notFound("No emulator with serial emulator-5560 is running."))
        let checks = AndroidDoctorRules.deviceChecks(facts, hostBlocker: nil)
        #expect(checks.first?.status == .fail)
        #expect(checks.dropFirst().allSatisfy { $0.status == .skip && $0.detail == "requires android-device.state" })
    }

    @Test("every Android check id fits the existing id column")
    func idsFitColumn() {
        let longest = DoctorCheckID.allCases.filter { !$0.isAndroidHost && !$0.isPerAndroidDevice }.map(\.rawValue.count).max() ?? 0
        #expect(DoctorCheckID.allCases.filter { $0.isAndroidHost || $0.isPerAndroidDevice }.allSatisfy { $0.rawValue.count <= longest })
    }
}
