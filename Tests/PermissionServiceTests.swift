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

    static var state: AndroidPackagePermissions { .parse(dumpsysPackage: dumpsys, apiLevel: 36) }

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

    static var android9: AndroidPackagePermissions {
        let (apiLevel, dump) = AndroidPackagePermissions.splitRead(Android9Fixtures.permissionRead)
        return .parse(dumpsysPackage: String(dump), apiLevel: apiLevel, dangerous: AndroidPackagePermissions.parseDangerous(Android9Fixtures.dangerousPermissions))
    }

    @Test("only a device before API 29 needs the dangerous list, and only API 33 and later clear permission flags")
    func versionGates() {
        #expect([nil, 23, 28, 29, 36].map { AndroidPackagePermissions.needsDangerousList(apiLevel: $0) } == [false, true, true, false, false])
        #expect([nil, 28, 32, 33, 36].map { AndroidPackagePermissions(requested: [], runtime: [], apiLevel: $0).clearsFlags } == [true, false, false, true, true])
    }

    @Test("the read's first line is the API level, and a missing one leaves the dump whole")
    func splitRead() {
        let read = AndroidPackagePermissions.splitRead(Android9Fixtures.permissionRead)
        #expect(read.apiLevel == 28)
        #expect(read.dump.hasPrefix("Packages:"))
        let unread = AndroidPackagePermissions.splitRead("\nPackages:\n")
        #expect(unread.apiLevel == nil)
        #expect(unread.dump == "\nPackages:\n")
    }

    @Test("pm's dangerous list is every permission line under its header, and nothing without the header")
    func dangerousList() {
        let dangerous = AndroidPackagePermissions.parseDangerous(Android9Fixtures.dangerousPermissions)
        #expect(dangerous?.contains("android.permission.CAMERA") == true)
        #expect(dangerous?.contains("com.example.provider.permission.READ_ONLY") == true)
        #expect(dangerous?.count == 7)
        #expect(AndroidPackagePermissions.parseDangerous("Error: unknown option -g\n") == nil)
    }

    static func android9Plan(_ action: PermissionAction, _ names: [String]) throws -> AndroidPermissionPlan {
        try AndroidPermissionPlan.make(action, names.map { try PermissionTarget.parse($0, platform: .android) }, package: package, state: android9)
    }

    @Test("on Android 9 a requested dangerous permission dumpsys leaves out reads as denied, in requested order")
    func android9Parse() {
        let state = Self.android9
        #expect(state.runtime.map(\.name) == ["android.permission.CAMERA", "android.permission.ACCESS_FINE_LOCATION", "android.permission.READ_CONTACTS"])
        #expect(state.runtime.map(\.granted) == [false, true, false])
        #expect(state.userFixed == ["android.permission.READ_CONTACTS"])
        for notRuntime in ["android.permission.POST_NOTIFICATIONS", "android.permission.SYSTEM_ALERT_WINDOW", "android.permission.INTERNET"] {
            #expect(state.isGranted(notRuntime) == nil, "\(notRuntime) is not a runtime permission on Android 9")
        }
    }

    @Test("on Android 9 camera grants though dumpsys has not listed it yet")
    func android9Grant() throws {
        let plan = try Self.android9Plan(.grant, ["camera"])
        #expect(plan.script == "pm grant com.example.app android.permission.CAMERA")
        #expect(plan.change.targets[0].permissions == [PermissionEntry(name: "android.permission.CAMERA", previous: .denied, current: .granted, changed: true)])
    }

    @Test("reset on Android 9 only revokes, since pm gained clear-permission-flags in Android 13")
    func android9Reset() throws {
        let plan = try Self.android9Plan(.reset, ["camera", "android.permission.ACCESS_FINE_LOCATION"])
        #expect(plan.script == "pm revoke com.example.app android.permission.CAMERA && pm revoke com.example.app android.permission.ACCESS_FINE_LOCATION")
        #expect(plan.change.targets.flatMap(\.permissions).map(\.current) == [.notDetermined, .notDetermined])
        #expect(plan.change.appStopped)
        #expect(plan.change.notes.isEmpty)
    }

    @Test("reset on Android 9 says a permission the user fixed stays denied")
    func android9ResetUserFixed() throws {
        let plan = try Self.android9Plan(.reset, ["android.permission.READ_CONTACTS"])
        #expect(plan.script == "pm revoke com.example.app android.permission.READ_CONTACTS")
        #expect(plan.change.targets[0].permissions == [PermissionEntry(name: "android.permission.READ_CONTACTS", previous: .denied, current: .denied, changed: nil)])
        #expect(plan.change.notes == ["Android 12 and earlier cannot clear android.permission.READ_CONTACTS's user-fixed flag from the shell, so com.example.app will not ask for it again until it is reinstalled."])
    }

    @Test("reset output promises a new prompt only when nothing stays user-fixed")
    func android9ResetLines() throws {
        let fixed = PermissionCommand.changeLines(try Self.android9Plan(.reset, ["contacts"]).change, app: Self.package, platform: .android)
        #expect(!fixed.contains("asks again"))
        #expect(fixed.contains("Note: Android 12 and earlier cannot clear android.permission.READ_CONTACTS's user-fixed flag"))
        let camera = PermissionCommand.changeLines(try Self.android9Plan(.reset, ["camera"]).change, app: Self.package, platform: .android)
        #expect(camera == "Reset camera (android.permission.CAMERA) for com.example.app; it asks again on next use")
    }

    @Test("reset all on Android 9 revokes every runtime permission the app requests, listed or not")
    func android9ResetAll() throws {
        let script = try #require(try Self.android9Plan(.reset, ["all"]).script)
        #expect(script == "pm revoke com.example.app android.permission.CAMERA && pm revoke com.example.app android.permission.ACCESS_FINE_LOCATION && pm revoke com.example.app android.permission.READ_CONTACTS && appops reset com.example.app")
    }

    static let userFixedCamera = dumpsys.replacingOccurrences(
        of: "android.permission.CAMERA: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]",
        with: "android.permission.CAMERA: granted=false, flags=[ USER_SET|USER_FIXED|USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED]"
    )

    @Test("reset on API 33 and later clears a user-fixed flag with no note")
    func laterResetClearsUserFixed() throws {
        let plan = try AndroidPermissionPlan.make(.reset, [.service(.camera)], package: Self.package, state: .parse(dumpsysPackage: Self.userFixedCamera, apiLevel: 33))
        #expect(plan.script == "pm revoke com.example.app android.permission.CAMERA && pm clear-permission-flags com.example.app android.permission.CAMERA user-set user-fixed")
        #expect(plan.change.targets[0].permissions[0].current == .notDetermined)
        #expect(plan.change.notes.isEmpty)
    }

    @Test("reset on API 29 to 32 revokes without pm clear-permission-flags and says a user-fixed permission stays denied")
    func android12ResetUserFixed() throws {
        let plan = try AndroidPermissionPlan.make(.reset, [.service(.camera)], package: Self.package, state: .parse(dumpsysPackage: Self.userFixedCamera, apiLevel: 32))
        #expect(plan.script == "pm revoke com.example.app android.permission.CAMERA")
        #expect(plan.change.targets[0].permissions[0].current == .denied)
        #expect(plan.change.notes == ["Android 12 and earlier cannot clear android.permission.CAMERA's user-fixed flag from the shell, so com.example.app will not ask for it again until it is reinstalled."])
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
