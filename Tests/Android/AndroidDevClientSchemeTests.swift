import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android dev client schemes")
@MainActor
struct AndroidDevClientSchemeTests {
    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    static func schemes(dump: String, resolving: Set<String>) async throws -> (schemes: [String], server: FakeAdbServer) {
        let server = AndroidDeviceStateTests.server(dumpsys: dump) { command in
            if command.hasPrefix("pm path") { return FakeAdbServer.shell(stdout: "package:/data/app/base.apk\n") }
            if command.hasPrefix("cmd package resolve-activity"), resolving.contains(where: { command.contains("'\($0)://") }) {
                return FakeAdbServer.shell(stdout: "priority=0\ncom.example.app/.MainActivity\n")
            }
            return FakeAdbServer.shell(stdout: "No activity found\n")
        }
        let backend = try AndroidBackendTests.backend(server)
        return (try await backend.devClientSchemes("com.example.app", on: Self.device), server)
    }

    @Test("an exp+ scheme is used as found, with no resolve read")
    func expoScheme() async throws {
        let (schemes, server) = try await Self.schemes(dump: "Scheme: \"exp+app\"\nScheme: \"myapp\"\n", resolving: [])
        #expect(schemes == ["exp+app"])
        #expect(!server.services.contains { $0.contains("resolve-activity") })
    }

    @Test("with no exp+ scheme, only the app's own schemes that resolve expo-development-client count")
    func ownSchemesThatResolve() async throws {
        let (schemes, _) = try await Self.schemes(dump: "Scheme: \"https\"\nScheme: \"myapp\"\nScheme: \"other\"\n", resolving: ["myapp"])
        #expect(schemes == ["myapp"])
    }
}
