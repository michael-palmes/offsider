import Foundation
import GRPCCore

/// The RPCs Offsider calls; the path is what a JWT's `aud` names.
enum EmulatorMethod: String, CaseIterable, Sendable {
    case getStatus, sendTouch, sendKey, getScreenshot, streamScreenshot, setClipboard, getClipboard, setPosture, streamNotification

    var path: String { "/android.emulation.control.EmulatorController/\(rawValue)" }
}

/// Credentials for the emulator's gRPC endpoint: the discovery file's token, else a registered per-process key.
enum EmulatorAuth: Sendable {
    /// Checked by the emulator as issuer `android-studio`.
    case token(String)
    case jwt(EmulatorJWTSigner)

    enum Preference: String, Sendable {
        case token
        case jwt
    }

    static let variable = "OFFSIDER_ANDROID_GRPC_AUTH"

    /// `OFFSIDER_ANDROID_GRPC_AUTH=token|jwt` forces one path; unset means the token when there is one.
    static func preference(host: AndroidHost) throws -> Preference? {
        guard let value = host.variable(variable) else { return nil }
        guard let preference = Preference(rawValue: value.lowercased()) else {
            throw AndroidError.invalidSetting(variable: variable, value: value, expected: "token or jwt")
        }
        return preference
    }

    static func choose(for discovery: EmulatorDiscovery, host: AndroidHost) async throws -> EmulatorAuth {
        let preference = try preference(host: host)
        let port = discovery.grpcPort ?? 0
        if preference != .jwt, let token = discovery.token, !token.isEmpty {
            return .token(token)
        }
        if preference == .token {
            throw AndroidError.grpcNoCredentials(port: port, avd: discovery.avdID, missing: "grpc.token")
        }
        guard let jwks = discovery.jwksDirectory, let active = discovery.jwkActivePath else {
            throw AndroidError.grpcNoCredentials(port: port, avd: discovery.avdID, missing: preference == .jwt ? "grpc.jwks" : "grpc.token or grpc.jwks")
        }
        return .jwt(try await EmulatorJWTSigner(jwksDirectory: jwks, activeListPath: active, avd: discovery.avdID, host: host))
    }

    var issuer: String {
        switch self {
        case .token: return "android-studio"
        case .jwt: return EmulatorJWTSigner.issuer
        }
    }

    func metadata(for method: EmulatorMethod, now: Date) throws -> Metadata {
        var metadata = Metadata()
        switch self {
        case .token(let token):
            metadata.addString("Bearer \(token)", forKey: "authorization")
        case .jwt(let signer):
            metadata.addString("Bearer \(try signer.token(for: method, now: now))", forKey: "authorization")
        }
        return metadata
    }

    /// Removes a registered key; a token needs nothing.
    func close() {
        if case .jwt(let signer) = self {
            signer.remove()
        }
    }
}
