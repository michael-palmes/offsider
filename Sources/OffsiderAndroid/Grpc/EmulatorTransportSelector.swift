import Foundation

/// Why a command drives an emulator over adb rather than gRPC.
enum AdbReason: Equatable, Sendable {
    case noDiscoveryFile
    case noGrpcPort
    case forced
    case grpcFailed(String)

    /// Finishes "and emulator-5556 ..." in messages about features that need gRPC.
    var clause: String {
        switch self {
        case .noDiscoveryFile: return "has none (it was probably started with -port)"
        case .noGrpcPort: return "has none (its discovery file lists no grpc.port)"
        case .forced: return "is driven over adb because OFFSIDER_ANDROID_TRANSPORT is adb"
        case .grpcFailed(let message): return "has one, but it failed: \(message)"
        }
    }
}

enum AndroidTransport {
    case grpc(any EmulatorControlling)
    case adb(AdbReason)
}

/// Chooses gRPC or adb once per emulator per command; a session never switches transport part-way.
struct EmulatorTransportSelector {
    enum Mode: String, Sendable {
        case auto
        case adb
        case grpc
    }

    static let variable = "OFFSIDER_ANDROID_TRANSPORT"

    let host: AndroidHost
    let log: AndroidLog

    /// `OFFSIDER_ANDROID_TRANSPORT=adb|grpc|auto`; unset is auto.
    static func mode(host: AndroidHost) throws -> Mode {
        guard let value = host.variable(variable) else { return .auto }
        guard let mode = Mode(rawValue: value.lowercased()) else {
            throw AndroidError.invalidSetting(variable: variable, value: value, expected: "auto, adb or grpc")
        }
        return mode
    }

    /// No discovery file or port: adb, silently. A failed probe: adb with one warning, or the error when gRPC is forced.
    func choose(for serial: String) async throws -> AndroidTransport {
        let mode = try Self.mode(host: host)
        if mode == .adb {
            return .adb(.forced)
        }
        _ = try EmulatorAuth.preference(host: host)
        let port = Int(serial.dropFirst("emulator-".count))
        guard let discovery = EmulatorDiscovery.live(host: host).first(where: { $0.consolePort == port }) else {
            return try adb(.noDiscoveryFile, serial: serial, mode: mode)
        }
        guard discovery.grpcPort != nil else {
            return try adb(.noGrpcPort, serial: serial, mode: mode)
        }

        var auth: EmulatorAuth?
        do {
            let chosen = try await EmulatorAuth.choose(for: discovery, host: host)
            auth = chosen
            return .grpc(try await host.emulatorConnector.connect(discovery: discovery, auth: chosen))
        } catch {
            auth?.close()
            if mode == .grpc || error is CancellationError {
                throw error
            }
            let message = (error as? AndroidError)?.message ?? error.localizedDescription
            log(.warning, "\(message) Using adb for \(serial) instead.")
            return .adb(.grpcFailed(message))
        }
    }

    private func adb(_ reason: AdbReason, serial: String, mode: Mode) throws -> AndroidTransport {
        if mode == .grpc {
            throw AndroidError.grpcForced(serial: serial, reason: reason.clause)
        }
        return .adb(reason)
    }
}
