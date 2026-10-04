import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Permission services")
struct PermissionServiceTests {
    static let package = "com.example.app"

    /// Trimmed from `dumpsys package com.android.chrome` on API 36.
    static let dumpsys = """
    Packages:
      Package [com.example.app] (b1c2d3):
        declared permissions:
          com.example.app.permission.C2D_MESSAGE: prot=signature, INSTALLED
        requested permissions:
          android.permission.POST_NOTIFICATIONS
          android.permission.ACCESS_FINE_LOCATION
          android.permission.INTERNET
          android.permission.ACCESS_COARSE_LOCATION
          android.permission.CAMERA
          android.permission.READ_CONTACTS, restricted=true
        install permissions:
          android.permission.INTERNET: granted=true
        User 0: ceDataInode=345027 installed=true hidden=false
          gids=[3003]
          runtime permissions:
            android.permission.POST_NOTIFICATIONS: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]
            android.permission.ACCESS_FINE_LOCATION: granted=true, flags=[ GRANTED_BY_DEFAULT|USER_SENSITIVE_WHEN_GRANTED]
            android.permission.ACCESS_COARSE_LOCATION: granted=true, flags=[ GRANTED_BY_DEFAULT|USER_SENSITIVE_WHEN_GRANTED]
            android.permission.CAMERA: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]
            android.permission.READ_CONTACTS: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]

    Queries:
      runtime permissions:
        android.permission.NOT_THIS_APP: granted=true
    """

    static var state: AndroidPackagePermissions { .parse(dumpsysPackage: dumpsys) }

    static func plan(_ action: PermissionAction, _ names: [String]) throws -> AndroidPermissionPlan {
        try AndroidPermissionPlan.make(action, names.map { try PermissionTarget.parse($0, platform: .android) }, package: package, state: state)
    }

    @Test("every service maps to at least one platform")
    func everyServiceMaps() {
        for service in PermissionService.allCases {
            #expect(service.iosName != nil || service.androidPermissions != nil, "\(service.rawValue) maps to neither platform")
        }
    }

    @Test("dumpsys package parsing reads requested and granted runtime permissions of the app only")
    func parsesDumpsys() {
        let state = Self.state
        #expect(state.requested == ["android.permission.POST_NOTIFICATIONS", "android.permission.ACCESS_FINE_LOCATION", "android.permission.INTERNET", "android.permission.ACCESS_COARSE_LOCATION", "android.permission.CAMERA", "android.permission.READ_CONTACTS"])
        #expect(state.runtime.map(\.name) == ["android.permission.POST_NOTIFICATIONS", "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION", "android.permission.CAMERA", "android.permission.READ_CONTACTS"])
        #expect(state.isGranted("android.permission.ACCESS_FINE_LOCATION") == true)
        #expect(state.isGranted("android.permission.CAMERA") == false)
        #expect(state.isGranted("android.permission.INTERNET") == nil)
        #expect(state.isGranted("android.permission.NOT_THIS_APP") == nil)
    }

    @Test("granting an already granted permission issues nothing and reports changed false")
    func grantIsIdempotent() throws {
        let plan = try Self.plan(.grant, ["location"])
        #expect(plan.script == nil)
        #expect(plan.change.targets[0].permissions.allSatisfy { $0.changed == false && $0.previous == .granted })
    }

    @Test("a grant runs pm grant only for the denied permissions, in one script")
    func grantScript() throws {
        let plan = try Self.plan(.grant, ["camera", "notifications", "location"])
        #expect(plan.script == "pm grant com.example.app android.permission.CAMERA && pm grant com.example.app android.permission.POST_NOTIFICATIONS")
        #expect(plan.change.appStopped == false)
    }

    @Test("revoke runs pm revoke for granted permissions and says the app stops")
    func revokeScript() throws {
        let plan = try Self.plan(.revoke, ["location", "camera"])
        #expect(plan.script == "pm revoke com.example.app android.permission.ACCESS_FINE_LOCATION && pm revoke com.example.app android.permission.ACCESS_COARSE_LOCATION")
        #expect(plan.change.appStopped)
        #expect(plan.change.targets[1].permissions[0].changed == false)
    }

    @Test("reset clears the user-set and user-fixed flags so the app asks again")
    func resetClearsFlags() throws {
        let plan = try Self.plan(.reset, ["camera"])
        #expect(plan.script == "pm revoke com.example.app android.permission.CAMERA && pm clear-permission-flags com.example.app android.permission.CAMERA user-set user-fixed")
        #expect(plan.change.targets[0].permissions[0].current == .notDetermined)
    }

    @Test("reset all covers every runtime permission and the app's app ops, never the global reset")
    func resetAll() throws {
        let plan = try Self.plan(.reset, ["all"])
        let script = try #require(plan.script)
        #expect(script.hasSuffix("appops reset com.example.app"))
        #expect(script.components(separatedBy: "clear-permission-flags").count - 1 == 5)
    }

    @Test("Android scripts never contain reset-permissions", arguments: PermissionAction.allCases)
    func neverGlobalReset(action: PermissionAction) throws {
        for service in PermissionService.offered(on: .android) {
            let script = (try? Self.plan(action, [service.rawValue]))?.script ?? ""
            #expect(!script.contains("reset-permissions"))
        }
    }

    @Test("an app that requests none of a service's permissions fails naming the manifest entry")
    func noneRequested() {
        #expect {
            try Self.plan(.grant, ["microphone"])
        } throws: { error in
            (error as? DeviceSettingsError)?.message == #"com.example.app requests none of microphone's permissions. Its manifest needs <uses-permission android:name="android.permission.RECORD_AUDIO" />."#
        }
    }

    @Test("a partly requested service applies to what is requested and adds a note")
    func partialService() throws {
        let plan = try Self.plan(.grant, ["contacts"])
        #expect(plan.script == "pm grant com.example.app android.permission.READ_CONTACTS")
        #expect(plan.change.notes == ["com.example.app does not request android.permission.WRITE_CONTACTS, android.permission.GET_ACCOUNTS; grant applied to android.permission.READ_CONTACTS."])
    }

    @Test("a requested install-time permission cannot be granted")
    func installPermission() {
        #expect(throws: DeviceSettingsError.self) { try Self.plan(.grant, ["android.permission.INTERNET"]) }
    }

    @Test("a literal android.permission name passes through on Android and is refused on iOS")
    func literalPermission() throws {
        #expect(try PermissionTarget.parse("android.permission.CAMERA", platform: .android) == .androidPermission("android.permission.CAMERA"))
        #expect(try PermissionTarget.parse("android.permission.CAMERA", platform: nil) == .androidPermission("android.permission.CAMERA"))
        #expect(throws: DeviceSettingsError.self) { try PermissionTarget.parse("android.permission.CAMERA", platform: .ios) }
        #expect(try Self.plan(.grant, ["android.permission.CAMERA"]).script == "pm grant com.example.app android.permission.CAMERA")
    }

    @Test("a service the platform does not offer names what it does offer")
    func notOffered() {
        #expect {
            try PermissionTarget.parse("camera", platform: .ios)
        } throws: { error in
            (error as? DeviceSettingsError)?.message.hasPrefix("camera is not offered on iOS simulators (simctl privacy has no camera service). Services on iOS: all, calendar,") == true
        }
        #expect(throws: DeviceSettingsError.self) { try PermissionTarget.parse("siri", platform: .android) }
        #expect(throws: DeviceSettingsError.self) { try PermissionTarget.parse("teleport", platform: nil) }
    }

    @Test("iOS runs one simctl privacy call per service and cannot read the earlier value")
    func iosArguments() {
        #expect(IOSPermissionArguments.arguments(.grant, service: .photos, udid: "SIM", bundleID: "com.example.app") == ["simctl", "privacy", "SIM", "grant", "photos", "com.example.app"])
        let change = IOSPermissionArguments.change(.revoke, services: [.contacts])
        #expect(change.targets[0].permissions == [PermissionEntry(name: "contacts", previous: nil, current: .denied, changed: nil)])
    }

    @Test("every iOS service Offsider maps is one simctl privacy accepts")
    func simctlContract() async throws {
        let result = try await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "help", "privacy"], timeout: 30)
        let offered = Set((result.stdout + result.stderr).components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dash = trimmed.range(of: " - ") else { return nil }
            return String(trimmed[..<dash.lowerBound])
        })
        for service in PermissionService.offered(on: .ios) {
            #expect(offered.contains(service.iosName!), "simctl privacy does not list \(service.rawValue)")
        }
    }
}

@Suite("iOS permission refusals")
@MainActor
struct IOSPermissionRefusalTests {
    @Test("what iOS simulators cannot do with permissions is not_supported, so an agent does not retry it")
    func notSupported() async {
        let backend = IOSBackend(logger: OffsiderLogger())
        let device = DeviceID(rawValue: UUID().uuidString, platform: .ios)
        let read = await #expect(throws: CLIError.self) { try await backend.permissions(of: "com.example.app", on: device) }
        #expect(read?.reason == .notSupported)
        let change = await #expect(throws: CLIError.self) {
            try await backend.applyPermission(.grant, [.androidPermission("android.permission.CAMERA")], app: "com.example.app", on: device)
        }
        #expect(change?.reason == .notSupported)
    }
}
