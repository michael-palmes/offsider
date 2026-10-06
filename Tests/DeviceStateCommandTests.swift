import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Device state commands")
@MainActor
struct DeviceStateCommandTests {
    static let ios = DeviceID(rawValue: "ABCDEF00-0000-4000-8000-00000000ABCD", platform: .ios)
    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)

    static func backend(android: Bool = false) -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: android ? .android : .ios, trees: [])
        if android { backend.packagePermissions = PermissionServiceTests.state }
        return backend
    }

    static func plan(_ arguments: [String]) throws -> PermissionCommand.Plan {
        try PermissionCommand.parse(arguments).plan()
    }

    @Test("granting an already granted permission changes nothing and says so")
    func alreadyGranted() async throws {
        let backend = Self.backend(android: true)
        let output = try await PermissionCommand.report(
            try Self.plan(["grant", "camera", "location", "--app", "com.example.app", "--device", "emulator-5554"]),
            json: false, on: Self.android, backend: backend
        )
        #expect(output == """
        Granted camera (android.permission.CAMERA) to com.example.app
        location (android.permission.ACCESS_FINE_LOCATION, android.permission.ACCESS_COARSE_LOCATION) was already granted
        """)
    }

    @Test("revoke on Android reports that the app is stopped")
    func revokeStops() async throws {
        let output = try await PermissionCommand.report(
            try Self.plan(["revoke", "location", "--app", "com.example.app", "--device", "emulator-5554"]),
            json: false, on: Self.android, backend: Self.backend(android: true)
        )
        #expect(output.hasSuffix("Android stopped com.example.app because a permission was revoked."))
    }

    @Test("the permission JSON keeps its schema order")
    func permissionJSON() async throws {
        let output = try await PermissionCommand.report(
            try Self.plan(["grant", "camera", "--app", "com.example.app", "--device", "emulator-5554", "--json"]),
            json: true, on: Self.android, backend: Self.backend(android: true)
        )
        #expect(output == #"{"version":1,"action":"grant","device":"emulator-5554","platform":"android","app":"com.example.app","services":[{"service":"camera","permissions":[{"name":"android.permission.CAMERA","previous":"denied","current":"granted","changed":true}]}],"appStopped":false,"notes":[]}"#)
    }

    @Test("iOS grants name simctl privacy and report no earlier value")
    func iosGrant() async throws {
        let backend = Self.backend()
        let plan = try Self.plan(["grant", "photos", "contacts", "--app", "com.example.app", "--device", Self.ios.rawValue])
        #expect(try await PermissionCommand.report(plan, json: false, on: Self.ios, backend: backend) == "Granted photos to com.example.app (simctl privacy)\nGranted contacts to com.example.app (simctl privacy)")
        #expect(backend.stateCalls == ["grant photos,contacts com.example.app"])
        let json = try await PermissionCommand.report(plan, json: true, on: Self.ios, backend: backend)
        #expect(json.contains(#"{"name":"photos","previous":null,"current":"granted","changed":null}"#))
    }

    @Test("permission show lists runtime permissions with their services")
    func show() async throws {
        let output = try await PermissionCommand.report(.show(app: "com.example.app", device: "emulator-5554"), json: false, on: Self.android, backend: Self.backend(android: true))
        #expect(output.hasPrefix("com.example.app runtime permissions:\n  android.permission.POST_NOTIFICATIONS: denied (notifications)\n  android.permission.ACCESS_FINE_LOCATION: granted (location, location-always)"))
    }

    @Test("permission usage errors exit 64 with the reason", arguments: [
        (["permission", "grant", "camera", "--app", "com.example.app", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "camera is not offered on iOS simulators"),
        (["permission", "grant", "camera", "--device", "emulator-5554"], "permission grant needs --app"),
        (["permission", "grant", "--app", "com.example.app", "--device", "emulator-5554"], "Name at least one service"),
        (["permission", "grant", "camera", "--app", "com.example.app"], "permission grant needs --device or OFFSIDER_DEVICE."),
        (["permission", "show", "--app", "com.example.app", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "permission show is Android only"),
        (["permission", "allow", "camera"], "Unknown action 'allow'. Use grant, revoke, reset, show or services."),
        (["permission", "services", "--platform", "windows"], "--platform takes ios or android; got windows."),
        (["permission", "grant", "camera", "--app", "not an id", "--device", "emulator-5554"], "is not a bundle ID or package name"),
        (["status-bar", "dim", "--device", "emulator-5554"], "Unknown action 'dim'. Use override, clear or show."),
        (["status-bar", "clear", "--battery", "50", "--device", "emulator-5554"], "Status bar options go with override, not clear."),
        (["status-bar", "override", "--operator", "Telstra", "--device", "emulator-5554"], "--operator is iOS only"),
        (["status-bar", "override", "--notifications", "shown", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "--notifications is Android only"),
        (["status-bar", "override", "--battery", "101", "--device", "emulator-5554"], "--battery takes 0 to 100; got 101."),
        (["status-bar", "override", "--wifi", "4", "--device", "emulator-5554"], "--wifi takes off or 0 to 3; got 4."),
        (["biometric", "scan", "--device", "emulator-5554"], "Unknown action 'scan'. Use enrol, unenrol, match, no-match or status."),
        (["biometric", "no-match", "--finger-id", "3", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "--finger-id is Android only"),
        (["biometric", "match", "--modality", "face", "--device", "emulator-5554"], "--modality is iOS only"),
        (["biometric", "status", "--finger-id", "3", "--device", "emulator-5554"], "--finger-id goes with match or no-match."),
    ])
    func usageErrors(arguments: [String], message: String) {
        do {
            _ = try OffsiderCommand.parseAsRoot(arguments)
            Issue.record("expected a usage error for \(arguments)")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error).contains(message), "\(OffsiderCommand.message(for: error))")
        }
    }

    @Test("services lists each platform's vocabulary")
    func servicesTable() {
        let ios = PermissionCommand.servicesTable(.ios)
        #expect(ios.hasPrefix("Service"))
        #expect(!ios.contains("camera"))
        #expect(ios.contains("photos-add"))
        let android = PermissionCommand.servicesTable(.android)
        #expect(android.contains("CAMERA"))
        #expect(!android.contains("siri"))
        #expect(DeviceStateReport.services([.camera]) == #"{"version":1,"action":"services","services":[{"service":"camera","ios":null,"android":["android.permission.CAMERA"]}]}"#)
    }

    @Test("a status bar override with no options applies the clean preset and says so")
    func statusBarOverride() async throws {
        let backend = Self.backend()
        let (action, override) = try StatusBarCommand.parse(["override", "--device", Self.ios.rawValue]).plan()
        let output = try await StatusBarCommand.report(action, override: override, json: false, on: Self.ios, backend: backend)
        #expect(output == "Status bar: 9:41, battery 100 % not charging, Wi-Fi 3 bars, cellular 4 bars")
        #expect(backend.stateCalls == ["status-bar override 9:41"])
    }

    @Test("status bar options build the override")
    func statusBarOptions() throws {
        let (_, override) = try StatusBarCommand.parse(["override", "--time", "10:30", "--battery", "50", "--charging", "--wifi", "off", "--cellular", "1", "--data-network", "lte", "--device", "emulator-5554"]).plan()
        #expect(StatusBarCommand.line(try #require(override)) == "Status bar: 10:30, battery 50 % charging, Wi-Fi off, cellular 1 bar")
        #expect(override?.dataNetwork == .lte)
    }

    @Test("the status bar override JSON carries the earlier reading")
    func statusBarJSON() async throws {
        let backend = Self.backend(android: true)
        backend.statusBarReading = StatusBarReading(demoAllowed: false)
        let output = try await StatusBarCommand.report(.override, override: StatusBarOverride(), json: true, on: Self.android, backend: backend)
        #expect(output == #"{"version":1,"action":"override","device":"emulator-5554","platform":"android","statusBar":{"time":"9:41","batteryLevel":100,"charging":false,"wifiBars":3,"cellularBars":4,"operatorName":null,"dataNetwork":"wifi","notificationsHidden":true},"current":null,"previous":{"overrides":null,"demoAllowed":false}}"#)
    }

    @Test("biometric match on a Face ID simulator sends the pearl match and reports it")
    func faceMatch() async throws {
        let backend = Self.backend()
        let report = try await BiometricCommand.report(.match, modality: nil, fingerID: nil, json: true, on: Self.ios, backend: backend)
        #expect(report.output == #"{"version":1,"action":"match","device":"ABCDEF00-0000-4000-8000-00000000ABCD","platform":"ios","modality":"face","enrolled":true,"sent":"com.apple.BiometricKit_Sim.pearl.match"}"#)
        #expect(report.warning == nil)
    }

    @Test("biometric match without enrolment warns that apps see no biometrics")
    func matchUnenrolled() async throws {
        let backend = Self.backend()
        backend.biometricEnrolment = false
        backend.biometricModality = .finger
        let report = try await BiometricCommand.report(.noMatch, modality: nil, fingerID: nil, json: false, on: Self.ios, backend: backend)
        #expect(report.output == "Touch ID: sent a non-matching finger (an app must be asking for it)")
        #expect(report.warning?.contains("Touch ID is not enrolled") == true)
        #expect(backend.stateCalls.last == "biometric no-match finger")
    }

    @Test("enrol and the hidden enroll alias set enrolment")
    func enrol() async throws {
        let backend = Self.backend()
        let (action, modality) = try BiometricCommand.parse(["enroll", "--device", Self.ios.rawValue]).plan()
        let report = try await BiometricCommand.report(action, modality: modality, fingerID: nil, json: false, on: Self.ios, backend: backend)
        #expect(report.output == "Face ID: enrolled")
        #expect(backend.stateCalls == ["biometric enrol true"])
    }

    @Test("permission services lists both platforms without a device")
    func servicesProcess() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("permission services")
        #expect(result.exitCode == 0)
        #expect(result.output.contains("iOS (simctl privacy)"))
        #expect(result.output.contains("Android runtime permissions"))
    }
}
