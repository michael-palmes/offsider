import CryptoKit
import Foundation
import Testing
@testable import OffsiderAndroid

/// A jwks folder whose "emulator" lists every Offsider key it finds each time the signer waits, unless told not to.
struct FakeJWKSFolder {
    let root: URL
    var jwks: URL { root.appendingPathComponent("jwks") }
    var active: URL { jwks.appendingPathComponent("active.jwk") }

    init() throws {
        root = try AndroidTestHost.temporaryHome()
        try FileManager.default.createDirectory(at: jwks, withIntermediateDirectories: true)
    }

    var keyFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: jwks.path)) ?? []).filter { $0.hasSuffix(".jwk") && $0 != "active.jwk" }.sorted()
    }

    func host(activates: Bool = true, environment: [String: String] = [:], liveProcesses: Set<Int32> = [], waits: SleepRecorder = SleepRecorder()) -> AndroidHost {
        let folder = self
        return AndroidHost(
            environment: environment,
            homeDirectory: root,
            isProcessAlive: { liveProcesses.contains($0) },
            processPath: { _ in nil },
            sleep: { duration in
                waits.sleep(duration)
                if activates { folder.activateKeys() }
            }
        )
    }

    func activateKeys() {
        let kids = keyFiles.compactMap { name -> String? in
            guard let data = FileManager.default.contents(atPath: jwks.appendingPathComponent(name).path),
                  let set = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let keys = set["keys"] as? [[String: Any]] else { return nil }
            return keys.first?["kid"] as? String
        }
        let listing = try? JSONSerialization.data(withJSONObject: ["keys": kids.map { ["kid": $0] }])
        FileManager.default.createFile(atPath: active.path, contents: listing)
    }

    func signer(host: AndroidHost, pid: Int32 = 4242) async throws -> EmulatorJWTSigner {
        try await EmulatorJWTSigner(jwksDirectory: jwks.path, activeListPath: active.path, avd: "Offsider_E2E_Pixel_9", host: host, pid: pid)
    }
}

@Suite("Emulator JWT", .serialized)
struct EmulatorJWTTests {
    static func parts(_ token: String) throws -> [Data] {
        try token.split(separator: ".").map { part in
            var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            return try #require(Data(base64Encoded: text))
        }
    }

    @Test("the header is exactly alg ES256 and kid, with no typ")
    func header() throws {
        let object = try JSONSerialization.jsonObject(with: EmulatorJWTFormat.header(kid: "abc")) as? [String: String]
        #expect(object == ["alg": "ES256", "kid": "abc"])
    }

    @Test("claims name the gradle issuer, the method path as aud, and live 120 s")
    func claims() throws {
        let data = EmulatorJWTFormat.claims(issuer: EmulatorJWTSigner.issuer, method: .sendTouch, now: Date(timeIntervalSince1970: 1_000))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["iss"] as? String == "gradle-utp-emulator-control")
        #expect(object["aud"] as? [String] == ["/android.emulation.control.EmulatorController/sendTouch"])
        #expect(object["iat"] as? Int == 1_000)
        #expect(object["exp"] as? Int == 1_120)
    }

    @Test("the posture RPCs are named in aud by their full paths, which the gradle allowlist checks",
          arguments: [(EmulatorMethod.setPosture, "setPosture"), (.streamNotification, "streamNotification")])
    func postureAudience(method: EmulatorMethod, name: String) throws {
        let data = EmulatorJWTFormat.claims(issuer: EmulatorJWTSigner.issuer, method: method, now: Date(timeIntervalSince1970: 1_000))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["aud"] as? [String] == ["/android.emulation.control.EmulatorController/\(name)"])
    }

    @Test("a signed token verifies with the registered public key and names only its method")
    func signatureVerifies() async throws {
        let folder = try FakeJWKSFolder()
        let signer = try await folder.signer(host: folder.host())
        defer { signer.remove() }

        let token = try signer.token(for: .getScreenshot, now: Date())
        let parts = try Self.parts(token)
        #expect(parts.count == 3)
        let signingInput = Data(token.split(separator: ".").prefix(2).joined(separator: ".").utf8)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: parts[2])
        #expect(signer.publicKey.isValidSignature(signature, for: signingInput))

        let header = try JSONSerialization.jsonObject(with: parts[0]) as? [String: String]
        #expect(header == ["alg": "ES256", "kid": signer.kid])
        let claims = try #require(try JSONSerialization.jsonObject(with: parts[1]) as? [String: Any])
        #expect(claims["aud"] as? [String] == [EmulatorMethod.getScreenshot.path])
    }

    @Test("the key file is a JWK set with 32-byte x and y in unpadded base64url")
    func keyFile() async throws {
        let folder = try FakeJWKSFolder()
        let signer = try await folder.signer(host: folder.host(), pid: 777)
        defer { signer.remove() }

        #expect(folder.keyFiles == ["offsider-777-\(signer.kid).jwk"])
        let data = try #require(FileManager.default.contents(atPath: signer.keyPath))
        let set = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]])
        let key = try #require(set["keys"]?.first)
        #expect(key["kty"] == "EC" && key["crv"] == "P-256" && key["alg"] == "ES256" && key["use"] == "sig" && key["kid"] == signer.kid)
        for coordinate in [key["x"], key["y"]] {
            let text = try #require(coordinate)
            #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
            #expect(try Self.parts(text).first?.count == 32)
        }
    }

    @Test("registration waits until the emulator lists the key")
    func waitsForActivation() async throws {
        let folder = try FakeJWKSFolder()
        let waits = SleepRecorder()
        let signer = try await folder.signer(host: folder.host(waits: waits))
        defer { signer.remove() }

        #expect(waits.sleeps == [.milliseconds(20)])
        #expect(String(decoding: try Data(contentsOf: folder.active), as: UTF8.self).contains(signer.kid))
    }

    @Test("a key the emulator never lists fails after 3 s and is removed")
    func notActivated() async throws {
        let folder = try FakeJWKSFolder()
        let waits = SleepRecorder()
        let error = await #expect(throws: AndroidError.self) { try await folder.signer(host: folder.host(activates: false, waits: waits)) }

        #expect(error?.message == "The emulator did not accept Offsider's signing key within 3 s (`\(folder.active.path)`). Restart it with `offsider boot Offsider_E2E_Pixel_9`.")
        #expect(waits.sleeps.count == 150)
        #expect(folder.keyFiles.isEmpty)
    }

    @Test("remove() and the exit registry delete the key file; remove() twice is harmless")
    func removal() async throws {
        let folder = try FakeJWKSFolder()
        let first = try await folder.signer(host: folder.host())
        #expect(EmulatorKeyRegistry.registered.contains(first.keyPath))
        first.remove()
        first.remove()
        #expect(folder.keyFiles.isEmpty)
        #expect(!EmulatorKeyRegistry.registered.contains(first.keyPath))

        let second = try await folder.signer(host: folder.host())
        EmulatorKeyRegistry.removeAll(in: folder.jwks.path)
        #expect(folder.keyFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.keyPath))
    }

    @Test("registration sweeps keys of dead Offsider processes and leaves live ones and other files alone")
    func staleSweep() async throws {
        let folder = try FakeJWKSFolder()
        for name in ["offsider-100-dead.jwk", "offsider-200-live.jwk", "studio.jwk", "offsider-x-odd.jwk"] {
            FileManager.default.createFile(atPath: folder.jwks.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }
        let signer = try await folder.signer(host: folder.host(liveProcesses: [200]), pid: 300)
        defer { signer.remove() }

        #expect(folder.keyFiles == ["offsider-200-live.jwk", "offsider-300-\(signer.kid).jwk", "offsider-x-odd.jwk", "studio.jwk"])
    }
}
