import Foundation
import OffsiderCore
import Testing

@Suite("Android doctor rules")
struct AndroidDoctorRulesTests {
    static let sdk = AndroidSDKFact.found(root: "/sdk", source: "default location", adbPath: "/sdk/platform-tools/adb")

    static func booted(_ configure: (inout AndroidDeviceFacts) -> Void = { _ in }) -> AndroidDeviceFacts {
        var facts = AndroidDeviceFacts(id: "emulator-5556", serial: "emulator-5556", avdName: "Offsider_E2E_Pixel_9", state: .booted)
        facts.apiLevel = 36
        facts.release = "16"
        facts.abi = "arm64-v8a"
        facts.grpc = .connected(endpoint: "127.0.0.1:8556", auth: "token", statusMilliseconds: 9, booted: true)
        facts.uiAutomation = UiAutomationFact(accessibilityEnabled: false, enabledServices: [], offsiderHelperPids: [])
        facts.helper = .ready(launchMilliseconds: 412, pushed: false, helloMilliseconds: 7, pingMilliseconds: 3, protocolVersion: 1, sdkInt: 36)
        facts.reverses = []
        facts.awake = AwakeReading(
            screen: .on, lockScreen: .hidden, credential: "none", stayAwake: [.ac, .usb, .wireless, .dock], charging: [.ac],
            screenTimeoutMilliseconds: 1_800_000, userUnlocked: true, memTotalKB: 6_149_664
        )
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

    @Test("a healthy booted emulator passes every device check and skips the phone-only ones")
    func healthyDevice() {
        let checks = AndroidDoctorRules.deviceChecks(Self.booted(), hostBlocker: nil)
        #expect(checks.map(\.id) == [
            .androidDeviceState, .androidDeviceImage, .androidDeviceMemory, .androidDeviceScreen, .androidDeviceLock, .androidDeviceStayAwake,
            .androidDeviceGrpc, .androidDeviceUiAutomation, .androidDeviceHelper, .androidDeviceMetroReverse, .androidDeviceAdbExpiry, .androidDeviceSystemUpdates,
        ])
        #expect(checks.dropLast(2).allSatisfy { $0.status == .pass })
        #expect(checks.suffix(2).allSatisfy { $0.status == .skip && $0.detail == "applies to phones only" })
    }

    @Test("a phone is named by its maker and model, an emulator by its AVD name")
    func deviceNames() {
        let phone = Self.booted {
            $0.isPhysical = true
            $0.avdName = nil
            $0.serial = "ZY22FAKE01"
            $0.model = "moto g57"
            $0.awake?.maker = "motorola"
        }
        #expect(AndroidDoctorRules.deviceState(phone).detail == "Motorola moto g57 (ZY22FAKE01), a phone connected over USB")
        #expect(AndroidDoctorRules.deviceState(Self.booted()).detail == "Offsider_E2E_Pixel_9 (emulator-5556), booted")
    }

    @Test("a phone reports its adb expiry and system update settings")
    func phoneSettings() {
        let facts = Self.booted {
            $0.isPhysical = true
            $0.adbAuthorisationTimeout = "0"
            $0.automaticUpdatesDisabled = "null"
        }
        let checks = AndroidDoctorRules.deviceChecks(facts, hostBlocker: nil)
        #expect(Self.check(.androidDeviceAdbExpiry, in: checks)?.status == .pass)
        #expect(Self.check(.androidDeviceSystemUpdates, in: checks)?.status == .warn)
    }

    @Test("an unreadable power state skips the memory, screen, lock and stay-awake checks")
    func unreadablePowerState() {
        let checks = AndroidDoctorRules.deviceChecks(Self.booted { $0.awake = nil }, hostBlocker: nil)
        for id in [DoctorCheckID.androidDeviceMemory, .androidDeviceScreen, .androidDeviceLock, .androidDeviceStayAwake] {
            #expect(Self.check(id, in: checks)?.status == .skip)
        }
    }

    @Test("an emulator under about 2.75 GB of RAM warns with the --memory hint; a phone always passes", arguments: [
        (2_883_583, false, CheckStatus.warn), (2_883_584, false, .pass), (2_000_000, true, .pass), (6_149_664, false, .pass),
    ] as [(Int, Bool, CheckStatus)])
    func memoryBoundaries(kilobytes: Int, isPhysical: Bool, status: CheckStatus) {
        let verdict = AndroidDoctorRules.memory(memTotalKB: kilobytes, avdName: "Pixel_API34", isPhysical: isPhysical)
        #expect(verdict.status == status)
        #expect(verdict.hint == (status == .warn ? "Close it, then run `offsider boot Pixel_API34 --memory 4096`." : nil))
    }

    @Test("a device waiting for its first unlock fails with the unlock hints; unlocked or without a credential passes")
    func lockVerdicts() {
        let waiting = AwakeReading(screen: .on, lockScreen: .secure, credential: "pin", userUnlocked: false)
        let failing = AndroidDoctorRules.lock(waiting, unlockCode: nil, deviceID: "emulator-5560")
        #expect(failing.status == .fail)
        #expect(failing.detail == "PIN set; waiting for its first unlock since boot, so apps cannot start; code saved: no")
        #expect(failing.hint?.contains("offsider unlock-code set --device emulator-5560") == true)
        let saved = AndroidDoctorRules.lock(waiting, unlockCode: UnlockCodeFact(saved: true, lastAttemptFailed: false), deviceID: "emulator-5560")
        #expect(saved.hint?.hasPrefix("Run `offsider wake --unlock --device emulator-5560`") == true)
        let failed = AndroidDoctorRules.lock(waiting, unlockCode: UnlockCodeFact(saved: true, lastAttemptFailed: true), deviceID: "emulator-5560")
        #expect(failed.detail.hasSuffix("code saved: yes, but it failed last time"))
        var unlocked = waiting
        unlocked.userUnlocked = true
        #expect(AndroidDoctorRules.lock(unlocked, unlockCode: nil, deviceID: "emulator-5560") == (.pass, "PIN set; unlocked since boot; code saved: no", nil))
        #expect(AndroidDoctorRules.lock(AwakeReading(screen: .on, lockScreen: .hidden, credential: "none"), unlockCode: nil, deviceID: "x").status == .pass)
        let unknown = AndroidDoctorRules.deviceChecks(Self.booted { $0.awake?.credential = nil }, hostBlocker: nil)
        #expect(Self.check(.androidDeviceLock, in: unknown)?.status == .skip)
    }

    @Test("a screen that is off or locked warns and names the command that helps")
    func screenVerdicts() {
        let off = AndroidDoctorRules.screen(AwakeReading(screen: .off, lockScreen: .secure, credential: "pin"), deviceID: "ZY22FAKE01")
        let locked = AndroidDoctorRules.screen(AwakeReading(screen: .on, lockScreen: .secure, credential: "password"), deviceID: "ZY22FAKE01")
        let usable = AndroidDoctorRules.screen(AwakeReading(screen: .on, lockScreen: .hidden), deviceID: "ZY22FAKE01")
        #expect(off.status == .warn)
        #expect(off.hint == "Run `offsider wake --device ZY22FAKE01`.")
        #expect(locked.detail.hasPrefix("On, password lock screen showing"))
        #expect(locked.hint?.contains("offsider wake --unlock --device ZY22FAKE01") == true)
        #expect(usable.status == .pass)
    }

    @Test("stay awake warns when off, when not charging, when charging over another source and when a policy caps the timeout")
    func stayAwakeVerdicts() {
        func verdict(_ stayAwake: PowerSources, charging: PowerSources, capped: Bool = false) -> AndroidDoctorRules.Verdict {
            AndroidDoctorRules.stayAwake(
                AwakeReading(screen: .on, lockScreen: .hidden, credential: "pin", stayAwake: stayAwake, charging: charging, screenTimeoutMilliseconds: 600_000, timeoutCappedByPolicy: capped),
                deviceID: "FA7AFAKE02"
            )
        }
        let off = verdict([], charging: [.usb])
        #expect(off.status == .warn)
        #expect(off.detail == "Off: the screen turns off after 10 min without input, then the PIN lock screen returns")
        #expect(off.hint == "Run `offsider stay-awake on --device FA7AFAKE02`.")
        #expect(verdict([.usb], charging: []).detail == "On, but the device is not charging, so the screen turns off after 10 min without input")
        #expect(verdict([.usb], charging: [.ac]).detail == "On while charging over USB, but the device charges over AC")
        #expect(verdict([.ac, .usb], charging: [.ac], capped: true).status == .warn)
        #expect(verdict([.ac, .usb], charging: [.ac]) == (.pass, "On; charging over AC", nil))
    }

    @Test("stay awake off with a screen timeout of never passes and says the screen never turns off")
    func stayAwakeOffNeverTimesOut() {
        let reading = AwakeReading(screen: .on, lockScreen: .hidden, credential: "none", screenTimeoutMilliseconds: Int(Int32.max))
        #expect(AndroidDoctorRules.stayAwake(reading, deviceID: "emulator-5554") == (.pass, "Off: the screen never turns off on its own", nil))
    }

    @Test("stay awake on with no charger passes when the screen timeout is never, instead of saying it turns off after never")
    func stayAwakeOnNeverTimesOut() {
        let reading = AwakeReading(screen: .on, lockScreen: .hidden, credential: "none", stayAwake: [.ac, .usb, .wireless, .dock], charging: [], screenTimeoutMilliseconds: Int(Int32.max))
        #expect(AndroidDoctorRules.stayAwake(reading, deviceID: "emulator-5554") == (.pass, "On; not charging, but the screen never turns off on its own", nil))
    }

    @Test("adb authorisation passes only when it never lapses; null is the 7-day default")
    func adbExpiry() {
        #expect(AndroidDoctorRules.adbAuthorisation("0").status == .pass)
        #expect(AndroidDoctorRules.adbAuthorisation("null").detail.hasPrefix("Lapses after 7 days"))
        #expect(AndroidDoctorRules.adbAuthorisation("86400000").detail.hasPrefix("Lapses after 1 day "))
        #expect(AndroidDoctorRules.adbAuthorisation("604800000").status == .warn)
    }

    @Test("automatic system updates pass only when Developer options turns them off")
    func systemUpdates() {
        #expect(AndroidDoctorRules.systemUpdates("1").status == .pass)
        #expect(AndroidDoctorRules.systemUpdates("null").status == .warn)
        #expect(AndroidDoctorRules.systemUpdates("0").status == .warn)
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
