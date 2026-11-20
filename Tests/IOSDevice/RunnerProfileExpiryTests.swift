import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

/// The fixtures are made-up profiles signed by a throwaway key: no team, App ID or device ids.
@Suite("iOS device runner profile expiry")
struct RunnerProfileExpiryTests {
    static let expired = "runner-profile-expired.mobileprovision"
    static let current = "runner-profile-current.mobileprovision"
    static let expiredOn = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
    static let currentUntil = ISO8601DateFormatter().date(from: "2027-11-13T00:00:00Z")!
    static let device = RunnerDestination.device(udid: "U")

    @Test("a profile's expiry is read from its CMS envelope")
    func readsExpiry() throws {
        #expect(ProvisioningProfile.expiry(of: try IOSDeviceFixtures.data(Self.expired)) == Self.expiredOn)
        #expect(ProvisioningProfile.expiry(of: try IOSDeviceFixtures.data(Self.current)) == Self.currentUntil)
    }

    @Test("an empty, cut short, unsigned or foreign file has no expiry, and nothing crashes")
    func unreadableProfiles() throws {
        let profile = try IOSDeviceFixtures.data(Self.expired)
        let plain = Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date></dict></plist>"#.utf8)
        for data in [Data(), profile.prefix(profile.count / 2), plain, Data(repeating: 0x30, count: 64)] {
            #expect(ProvisioningProfile.expiry(of: data) == nil)
        }
    }

    @Test("a cached build whose profile is current is kept with no rebuild")
    func currentProfileKept() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        let builder = fixture.builder(now: Self.expiredOn.addingTimeInterval(-3 * 86_400))
        let build = try await builder.build(for: Self.device, deviceName: "iPhone")

        #expect(try await builder.verifyForLaunch(build, for: Self.device, deviceName: "iPhone") == build)
        #expect(fixture.xcodebuild.calls.count == 1)
    }

    @Test("a profile ending within an hour is rebuilt before launch, and the renewed build is kept")
    func expiringProfileRebuilt() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        let builder = fixture.builder(now: Self.expiredOn.addingTimeInterval(-30 * 60))
        let build = try await builder.build(for: Self.device, deviceName: "iPhone")
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.current)

        let rebuilt = try await builder.verifyForLaunch(build, for: Self.device, deviceName: "iPhone")

        #expect(fixture.xcodebuild.calls.count == 2)
        #expect(builder.expiringProfile(rebuilt, signing: try builder.signing(for: Self.device)) == nil)
        #expect(fixture.notices.values.contains { $0.contains("provisioning profile that expires on") })
    }

    @Test("a rebuild that brings back the same profile, close to its end but still valid, is kept, as it still launches")
    func stillValidProfileKept() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        let builder = fixture.builder(now: Self.expiredOn.addingTimeInterval(-30 * 60))
        let build = try await builder.build(for: Self.device, deviceName: "iPhone")

        let rebuilt = try await builder.verifyForLaunch(build, for: Self.device, deviceName: "iPhone")

        #expect(fixture.xcodebuild.calls.count == 2)
        #expect(FileManager.default.fileExists(atPath: rebuilt.xctestrun.path))
    }

    @Test("a renewal that fails because the team dropped the device still names runner build --register-device")
    func renewalNeedsRegistration() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        let builder = fixture.builder(now: Self.expiredOn.addingTimeInterval(86_400))
        let build = try await builder.build(for: Self.device, deviceName: "iPhone")
        fixture.xcodebuild.status = 65
        fixture.xcodebuild.output = "error: Device \"U\" is not registered in your developer account."

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await builder.verifyForLaunch(build, for: Self.device, deviceName: "iPhone") }

        #expect(error?.reason == .runnerBuildFailed)
        #expect(error?.hint == "offsider runner build --register-device --device U")
    }

    @Test("an expired profile a rebuild cannot renew is profile_expired, naming the one command a person runs, and the build is deleted")
    func unrenewedProfileRefused() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        let builder = fixture.builder(now: Self.expiredOn.addingTimeInterval(86_400))
        let build = try await builder.build(for: Self.device, deviceName: "iPhone")

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await builder.verifyForLaunch(build, for: Self.device, deviceName: "iPhone") }

        #expect(error?.reason == .profileExpired)
        #expect(error?.hint == "offsider runner build --device U")
        #expect(error?.message.contains("expired on") == true)
        #expect(error?.message.contains("team \(RunnerProvisioningTests.team)") == true)
        #expect(fixture.xcodebuild.calls.count == 2)
        #expect(!FileManager.default.fileExists(atPath: build.directory.path))
    }

    @Test("a renewal xcodebuild fails, as with no account signed in, is profile_expired with the person's command, not a registration failure")
    func renewalBuildFails() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        let builder = fixture.builder(now: Self.expiredOn.addingTimeInterval(86_400))
        let build = try await builder.build(for: Self.device, deviceName: "iPhone")
        fixture.xcodebuild.status = 65
        fixture.xcodebuild.output = "error: No Accounts: Add a new account in Accounts settings.\nerror: No profiles for 'com.mpalmes.offsider.runner' were found"

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await builder.verifyForLaunch(build, for: Self.device, deviceName: "iPhone") }

        #expect(error?.reason == .profileExpired)
        #expect(error?.hint == "offsider runner build --device U")
        #expect(error?.message.contains("No Accounts") == true)
    }

    @Test("doctor's cache view warns of an expired profile and passes a current one")
    func doctorFact() async throws {
        let fixture = try RunnerProvisioningTests.Fixture()
        defer { fixture.remove() }
        fixture.xcodebuild.profile = try IOSDeviceFixtures.data(Self.expired)
        _ = try await fixture.builder(now: Self.expiredOn.addingTimeInterval(-3 * 86_400)).build(for: Self.device, deviceName: "iPhone")
        let team = RunnerProvisioningTests.team

        let late = fixture.builder(now: Self.expiredOn.addingTimeInterval(3600)).cacheStatus(udid: "U")
        #expect(late == .profileExpiring(team: team, prefix: "com.mpalmes.offsider", expires: Self.expiredOn, expired: true))
        #expect(fixture.builder(now: Self.expiredOn.addingTimeInterval(-3 * 86_400)).cacheStatus(udid: "U") == .built(team: team, prefix: "com.mpalmes.offsider"))
    }

    @Test("the device's 0xe8008011 refusal is found in hex and in xcodebuild's decimal code, and other codes are not", arguments: [
        ("The application could not be launched: 0xe8008011", true),
        (#"Error Domain=com.apple.dt.CoreDeviceError Code=-402620399 "Launch refused.""#, true),
        ("The application could not be launched: 0xe8008015", false),
        ("Signing Identity: Apple Development: Jane Citizen (PERSON1234)", false),
    ])
    func logFinding(line: String, found: Bool) {
        #expect(RunnerLogWatch.finding(in: line) == (found ? .profileNotValid : nil))
    }

    @Test("a runner start the device refuses with 0xe8008011 fails at once with profile_expired and drops the cached build")
    @MainActor
    func startRefused() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        let build = URL(fileURLWithPath: RunnerTestPaths.temporaryRoot()).appendingPathComponent("build-key")
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(at: build.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let processes = FakeRunnerProcesses(launchLog: Data("Testing started\nThe application could not be launched: 0xe8008011\n".utf8), exitsOnLaunch: true)
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = RunnerSessionTests.manager(root: root, processes: processes, transport: transport, builder: FakeRunnerBuilder(directory: build), startTimeout: 20)

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: RunnerSessionTests.udid), deviceName: "iPhone") }

        #expect(error?.reason == .profileExpired)
        #expect(error?.hint == "offsider runner build --device \(RunnerSessionTests.udid)")
        #expect(error?.message.contains("UI Automation") == false)
        #expect(!FileManager.default.fileExists(atPath: build.path))
    }
}
