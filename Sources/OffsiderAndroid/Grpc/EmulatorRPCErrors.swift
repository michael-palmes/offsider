import Foundation
import GRPCCore

/// gRPC status codes as actionable Android errors; nothing the emulator sends back can leak the token.
enum EmulatorRPCErrors {
    static func map(
        _ error: RPCError,
        method: EmulatorMethod,
        endpoint: String,
        discovery: EmulatorDiscovery,
        issuer: String,
        timeout: Duration
    ) -> AndroidError {
        switch error.code {
        case .unauthenticated:
            return .grpcUnauthenticated(endpoint: endpoint, method: method.rawValue, avd: discovery.avdID)
        case .permissionDenied:
            return .grpcPermissionDenied(
                allowlist: discovery.allowlistPath ?? "emulator/lib/emulator_access.json",
                issuer: issuer,
                method: method.rawValue,
                avd: discovery.avdID
            )
        case .unavailable:
            return .grpcUnavailable(port: discovery.grpcPort ?? 0)
        case .deadlineExceeded:
            return .grpcDeadlineExceeded(method: method.rawValue, seconds: max(1, Int(timeout.components.seconds)))
        default:
            return .grpcFailed(endpoint: endpoint, method: method.rawValue, detail: redacted("\(error.code): \(error.message)", discovery: discovery))
        }
    }

    static func redacted(_ text: String, discovery: EmulatorDiscovery) -> String {
        guard let token = discovery.token, !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "<redacted>")
    }
}
