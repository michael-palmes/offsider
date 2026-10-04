import Foundation
import OffsiderCore

/// Why a command drives a device over adb rather than gRPC.
enum AdbReason: Equatable, Sendable {
    case physicalDevice
    case noDiscoveryFile
    case noGrpcPort
    case forced
    case grpcFailed(String)

    /// Finishes "and emulator-5556 ..." in messages about features that need gRPC.
    var clause: String {
        switch self {
        case .physicalDevice: return "is a physical device, which has no emulator gRPC endpoint"
        case .noDiscoveryFile: return "has none (it was probably started with -port)"
        case .noGrpcPort: return "has none (its discovery file lists no grpc.port)"
        case .forced: return "is driven over adb because OFFSIDER_ANDROID_TRANSPORT is adb"
        case .grpcFailed(let message):
            let trimmed = message.hasSuffix(".") ? String(message.dropLast()) : message
            return "has one, but it failed (\(trimmed))"
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

    /// adb for a phone or a missing discovery file; a failed probe warns once, or throws when gRPC is forced.
    func choose(for serial: String) async throws -> AndroidTransport {
        let mode = try Self.mode(host: host)
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(serial) else {
            return try adb(.physicalDevice, serial: serial, mode: mode)
        }
        if mode == .adb {
            return .adb(.forced)
        }
        _ = try EmulatorAuth.preference(host: host)
        guard let discovery = EmulatorDiscovery.live(host: host).first(where: { $0.consolePort == port }) else {
            return try adb(.noDiscoveryFile, serial: serial, mode: mode)
        }
        guard discovery.grpcPort != nil else {
            return try adb(.noGrpcPort, serial: serial, mode: mode)
        }

        var auth: EmulatorAuth?
        do {
            let emulator = try await host.timing.measure(.grpcConnect) {
                let chosen = try await EmulatorAuth.choose(for: discovery, host: host)
                auth = chosen
                return try await host.emulatorConnector.connect(discovery: discovery, auth: chosen)
            }
            return .grpc(TimedEmulator.wrapping(emulator, timing: host.timing))
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
