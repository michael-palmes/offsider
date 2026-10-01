import Foundation

enum LoopbackHost: String, Sendable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"
}

/// Where the adb server listens; only numeric loopback addresses or a Unix path, so no name is ever resolved.
enum LoopbackEndpoint: Equatable, Sendable, CustomStringConvertible {
    case tcp(LoopbackHost, port: UInt16)
    case unix(path: String)

    static let defaultAdbServer = LoopbackEndpoint.tcp(.ipv4, port: 5037)

    var description: String {
        switch self {
        case .tcp(.ipv4, let port):
            return "127.0.0.1:\(port)"
        case .tcp(.ipv6, let port):
            return "[::1]:\(port)"
        case .unix(let path):
            return path
        }
    }

    /// `tcp:5037`, `tcp:127.0.0.1:5037`, `tcp:[::1]:5037`, `tcp:localhost:5037` or `localfilesystem:/path`.
    static func parse(adbSocketSpec spec: String, variable: String = "ADB_SERVER_SOCKET") throws -> LoopbackEndpoint {
        if spec.hasPrefix("localfilesystem:") {
            let path = String(spec.dropFirst("localfilesystem:".count))
            guard path.hasPrefix("/") else { throw invalid(variable, spec) }
            return .unix(path: path)
        }
        guard spec.hasPrefix("tcp:") else {
            throw AndroidError.nonLoopbackAdbServer(variable: variable, value: spec)
        }
        let rest = String(spec.dropFirst("tcp:".count))
        guard let separator = rest.lastIndex(of: ":") else {
            return .tcp(.ipv4, port: try port(rest, variable: variable, value: spec))
        }
        let hostText = String(rest[..<separator])
        let portText = String(rest[rest.index(after: separator)...])
        guard let host = host(literal: hostText) else {
            throw AndroidError.nonLoopbackAdbServer(variable: variable, value: spec)
        }
        return .tcp(host, port: try port(portText, variable: variable, value: spec))
    }

    /// ADB_SERVER_SOCKET, else ANDROID_ADB_SERVER_ADDRESS with ANDROID_ADB_SERVER_PORT, else 127.0.0.1:5037.
    static func adbServer(environment: [String: String]) throws -> LoopbackEndpoint {
        func value(_ name: String) -> String? {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        if let spec = value("ADB_SERVER_SOCKET") {
            return try parse(adbSocketSpec: spec)
        }
        var host = LoopbackHost.ipv4
        if let address = value("ANDROID_ADB_SERVER_ADDRESS") {
            guard let loopback = self.host(literal: address) else {
                throw AndroidError.nonLoopbackAdbServer(variable: "ANDROID_ADB_SERVER_ADDRESS", value: address)
            }
            host = loopback
        }
        var serverPort: UInt16 = 5037
        if let portText = value("ANDROID_ADB_SERVER_PORT") {
            serverPort = try port(portText, variable: "ANDROID_ADB_SERVER_PORT", value: portText)
        }
        return .tcp(host, port: serverPort)
    }

    /// "127.0.0.1", "::1", "[::1]" and "localhost" only; `localhost` is mapped, never looked up.
    static func host(literal: String) -> LoopbackHost? {
        switch literal {
        case "127.0.0.1", "localhost":
            return .ipv4
        case "::1", "[::1]":
            return .ipv6
        default:
            return nil
        }
    }

    private static func port(_ text: String, variable: String, value: String) throws -> UInt16 {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt16(text), number > 0 else {
            throw invalid(variable, value)
        }
        return number
    }

    private static func invalid(_ variable: String, _ value: String) -> AndroidError {
        AndroidError.invalidAdbServerSetting(variable: variable, value: value)
    }
}
