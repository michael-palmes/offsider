import Foundation
import GRPCCore
import Testing
@testable import OffsiderAndroid

@Suite("Emulator gRPC auth")
struct EmulatorAuthTests {
    static func discovery(token: String? = "s3cr3t-token", folder: FakeJWKSFolder? = nil) throws -> EmulatorDiscovery {
        var lines = ["avd.id=Offsider_E2E", "port.serial=5556", "grpc.port=8556"]
        if let token { lines.append("grpc.token=\(token)") }
        if let folder {
            lines.append("grpc.jwks=\(folder.jwks.path)")
            lines.append("grpc.jwk_active=\(folder.active.path)")
        }
        return try EmulatorDiscovery.parse(fileName: "pid_50144.ini", contents: lines.joined(separator: "\n"))
    }

    static func authorization(_ auth: EmulatorAuth, method: EmulatorMethod = .sendKey) throws -> String? {
        try auth.metadata(for: method, now: Date())[stringValues: "authorization"].first(where: { _ in true })
    }

    @Test("the discovery file's token wins and becomes a Bearer header")
    func tokenPreferred() async throws {
        let folder = try FakeJWKSFolder()
        let auth = try await EmulatorAuth.choose(for: Self.discovery(folder: folder), host: folder.host())

        #expect(try Self.authorization(auth) == "Bearer s3cr3t-token")
        #expect(auth.issuer == "android-studio")
        #expect(folder.keyFiles.isEmpty)
    }

    @Test("without a token, a per-process key signs each call as the gradle issuer")
    func jwtWithoutToken() async throws {
        let folder = try FakeJWKSFolder()
        let auth = try await EmulatorAuth.choose(for: Self.discovery(token: nil, folder: folder), host: folder.host())
        defer { auth.close() }

        let header = try #require(try Self.authorization(auth, method: .sendTouch))
        #expect(header.hasPrefix("Bearer ey"))
        #expect(header.split(separator: ".").count == 3)
        #expect(auth.issuer == "gradle-utp-emulator-control")
        #expect(folder.keyFiles.count == 1)
    }

    @Test("OFFSIDER_ANDROID_GRPC_AUTH=jwt registers a key even when there is a token; close() removes it")
    func jwtForced() async throws {
        let folder = try FakeJWKSFolder()
        let auth = try await EmulatorAuth.choose(for: Self.discovery(folder: folder), host: folder.host(environment: ["OFFSIDER_ANDROID_GRPC_AUTH": "jwt"]))

        #expect(auth.issuer == "gradle-utp-emulator-control")
        #expect(try Self.authorization(auth)?.contains("s3cr3t") == false)
        auth.close()
        #expect(folder.keyFiles.isEmpty)
    }

    @Test("no token and no jwks folder is the credentials error")
    func noCredentials() async throws {
        let folder = try FakeJWKSFolder()
        let error = await #expect(throws: AndroidError.self) {
            try await EmulatorAuth.choose(for: Self.discovery(token: nil), host: folder.host())
        }
        #expect(error?.message == "The emulator's gRPC endpoint on port 8556 offers no credentials Offsider can use (its discovery file has no grpc.token or grpc.jwks). Restart it with `offsider boot Offsider_E2E`.")
    }

    @Test("forcing the token without one, or an unknown value, is an error naming the setting")
    func forcedAndInvalid() async throws {
        let folder = try FakeJWKSFolder()
        let missing = await #expect(throws: AndroidError.self) {
            try await EmulatorAuth.choose(for: Self.discovery(token: nil, folder: folder), host: folder.host(environment: ["OFFSIDER_ANDROID_GRPC_AUTH": "token"]))
        }
        #expect(missing?.kind == .grpcNoCredentials)
        #expect(folder.keyFiles.isEmpty)

        let invalid = await #expect(throws: AndroidError.self) {
            try await EmulatorAuth.choose(for: Self.discovery(), host: folder.host(environment: ["OFFSIDER_ANDROID_GRPC_AUTH": "studio"]))
        }
        #expect(invalid?.message == "OFFSIDER_ANDROID_GRPC_AUTH is studio, which Offsider cannot read. Use token or jwt, or unset it.")
    }
}
