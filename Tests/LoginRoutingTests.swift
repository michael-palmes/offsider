import ArgumentParser
import Foundation
@testable import Offsider
@testable import OffsiderAndroid
@testable import OffsiderCore
import Testing

@Suite("login on a phone allowed for any app", .serialized)
@MainActor
struct LoginRoutingTests {
    static let serial = "R58M123ABC"
    static let package = "com.mpalmes.offsider.playground.rn"

    /// A folder outside the current directory holding an offsider.login.json for `package`.
    static func project(package: String = package) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-login-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"package": "\#(package)"}"#.utf8).write(to: folder.appendingPathComponent(LoginProfile.fileName))
        return folder.path
    }

    static func route(project: String, app: [String] = []) async throws -> String? {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let claims = DeviceClaims()
        claims.root = { root }
        let server = DevicePolicyRoutingTests.phoneServer("\(serial) device usb:1-1 model:Pixel_9 transport_id:2\n")
        let host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        let gate = DevicePolicyRoutingTests.gate([PolicyFixtures.entry(.android, key: serial)])
        let route = try await DevicePolicyGate.$current.withValue(gate) {
            try await LoginCommand.route(
                serial, profile: try LoginProfiles.load(project: project), app: try AppOption.parse(app), logger: OffsiderLogger(),
                watchdog: DeviceWatchdog(), host: host, claims: claims
            )
        }
        defer { claims.releaseAll() }
        return (route.backend as? AndroidBackend)?.appScopes[serial]?.target
    }

    @Test("the package of the offsider.login.json that --project names is the app the phone guard requires, not the current directory's")
    func projectPackageIsTheTarget() async throws {
        let project = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: project) }
        #expect(!FileManager.default.fileExists(atPath: (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(LoginProfile.fileName)))

        #expect(try await Self.route(project: project) == Self.package)
    }

    @Test("--app naming the file's app drives it")
    func appMatchingTheFile() async throws {
        let project = try Self.project()
        defer { try? FileManager.default.removeItem(atPath: project) }
        #expect(try await Self.route(project: project, app: ["--app", Self.package]) == Self.package)
    }

    @Test("--app naming another app than the file's is a usage error (exit 64) before anything reaches the phone")
    func appOtherThanTheFile() async throws {
        let project = try Self.project(package: "com.example.other")
        defer { try? FileManager.default.removeItem(atPath: project) }
        let error = await #expect(throws: CLIError.self) {
            _ = try await Self.route(project: project, app: ["--app", Self.package])
        }

        #expect(error?.reason == .usage)
        #expect(error?.exitCode.rawValue == 64)
        #expect(error?.userFacingDescription.contains("--app \(Self.package) is not an app offsider.login.json names (com.example.other)") == true)
    }
}
