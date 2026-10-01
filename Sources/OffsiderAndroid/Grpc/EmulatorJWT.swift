import CryptoKit
import Darwin
import Foundation

/// The JWS parts the emulator checks: an ES256 header with `kid` only (it rejects a `typ`) and per-method claims.
enum EmulatorJWTFormat {
    static let lifetime: TimeInterval = 120

    static func header(kid: String) -> Data {
        json(["alg": "ES256", "kid": kid])
    }

    static func claims(issuer: String, method: EmulatorMethod, now: Date, lifetime: TimeInterval = lifetime) -> Data {
        let issuedAt = Int(now.timeIntervalSince1970)
        return json(["iss": issuer, "aud": [method.path], "iat": issuedAt, "exp": issuedAt + Int(lifetime)])
    }

    /// No padding, `-` and `_` for `+` and `/`.
    static func base64URL<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A JWK set holding one P-256 public key, the form the emulator reads from its `grpc.jwks` folder.
    static func keySet(for publicKey: P256.Signing.PublicKey, kid: String) -> Data {
        let raw = publicKey.rawRepresentation
        return json(["keys": [[
            "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
            "x": base64URL(raw.prefix(32)), "y": base64URL(raw.suffix(32)),
        ]]])
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// Key files this process wrote, removed at exit; Ctrl+C skips `atexit`, so the next registration sweeps those.
enum EmulatorKeyRegistry {
    private final class Paths: @unchecked Sendable {
        let lock = NSLock()
        var paths: Set<String> = []
        var hookInstalled = false
    }

    private static let state = Paths()

    static func register(_ path: String) {
        state.lock.withLock {
            state.paths.insert(path)
            if !state.hookInstalled {
                state.hookInstalled = true
                atexit { EmulatorKeyRegistry.removeAll() }
            }
        }
    }

    static func unregister(_ path: String) {
        _ = state.lock.withLock { state.paths.remove(path) }
    }

    static var registered: Set<String> { state.lock.withLock { state.paths } }

    /// Every registered key, or with `folder` only the keys inside it.
    static func removeAll(in folder: String? = nil) {
        let paths = state.lock.withLock { () -> [String] in
            let chosen = state.paths.filter { path in folder.map { path.hasPrefix($0 + "/") } ?? true }
            state.paths.subtract(chosen)
            return Array(chosen)
        }
        for path in paths {
            unlink(path)
        }
    }
}

/// A per-process ES256 key the emulator accepts as issuer `gradle-utp-emulator-control`, never `android-studio`.
final class EmulatorJWTSigner: Sendable {
    static let issuer = "gradle-utp-emulator-control"
    static let activationAttempts = 150
    static let activationInterval = Duration.milliseconds(20)

    let kid: String
    let keyPath: String
    private let key: P256.Signing.PrivateKey

    /// Sweeps keys of dead Offsider processes, writes `offsider-<pid>-<kid>.jwk`, and waits up to 3 s for the emulator to list it.
    init(jwksDirectory: String, activeListPath: String, avd: String?, host: AndroidHost, pid: Int32 = getpid()) async throws {
        Self.sweepStaleKeys(in: jwksDirectory, host: host)
        let key = P256.Signing.PrivateKey()
        let kid = UUID().uuidString.lowercased()
        let path = (jwksDirectory as NSString).appendingPathComponent("offsider-\(pid)-\(kid).jwk")
        do {
            try EmulatorJWTFormat.keySet(for: key.publicKey, kid: kid).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw AndroidError.grpcKeyNotWritten(directory: jwksDirectory, detail: (error as NSError).localizedDescription)
        }
        EmulatorKeyRegistry.register(path)
        self.key = key
        self.kid = kid
        self.keyPath = path

        for _ in 0..<Self.activationAttempts {
            if let listing = host.files.contents(atPath: activeListPath), String(decoding: listing, as: UTF8.self).contains(kid) {
                return
            }
            try? await host.sleep(Self.activationInterval)
        }
        remove()
        throw AndroidError.grpcKeyNotActivated(activeListPath: activeListPath, avd: avd)
    }

    /// Signed per call, so each token names one method and lives 120 s.
    func token(for method: EmulatorMethod, now: Date) throws -> String {
        let signingInput = EmulatorJWTFormat.base64URL(EmulatorJWTFormat.header(kid: kid)) + "."
            + EmulatorJWTFormat.base64URL(EmulatorJWTFormat.claims(issuer: Self.issuer, method: method, now: now))
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + EmulatorJWTFormat.base64URL(signature)
    }

    var publicKey: P256.Signing.PublicKey { key.publicKey }

    /// Idempotent.
    func remove() {
        unlink(keyPath)
        EmulatorKeyRegistry.unregister(keyPath)
    }

    /// `offsider-<pid>-*.jwk` files whose pid has gone; other files in the folder are never touched.
    static func sweepStaleKeys(in directory: String, host: AndroidHost) {
        for name in host.files.contentsOfDirectory(atPath: directory) {
            guard name.hasPrefix("offsider-"), name.hasSuffix(".jwk") else { continue }
            let digits = name.dropFirst("offsider-".count).prefix { $0.isASCII && $0.isNumber }
            guard let pid = Int32(digits), name.dropFirst("offsider-".count + digits.count).hasPrefix("-"),
                  !host.isProcessAlive(pid) else { continue }
            unlink((directory as NSString).appendingPathComponent(name))
        }
    }
}
