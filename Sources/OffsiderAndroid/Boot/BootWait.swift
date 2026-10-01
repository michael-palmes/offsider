import Foundation

/// The polling half of `offsider boot`: from a launched process to a serial, then to a booted Android and gRPC.
@MainActor
struct BootWait {
    let host: AndroidHost
    let log: AndroidLog
    let client: AdbClient
    let avdName: String
    let deadline: Duration
    let timeout: Duration

    func discovery(for serial: String) -> EmulatorDiscovery? {
        let port = Int(serial.dropFirst("emulator-".count))
        return EmulatorDiscovery.live(host: host).first { $0.consolePort == port }
    }

    /// A new discovery file for this pid or AVD gives the serial; after 30 s without one, a new adb serial of this AVD.
    func serial(pid: Int32, knownFiles: Set<String>, knownSerials: Set<String>, launched: Int32?, logPath: String?) async throws -> String {
        let started = host.uptime()
        while true {
            let files = EmulatorDiscovery.live(host: host)
            if let file = files.first(where: { $0.pid == pid || ($0.avdID == avdName && !knownFiles.contains($0.path)) }),
               let port = file.consolePort {
                return "emulator-\(port)"
            }
            if let launched, let status = host.launcher.exitStatus(of: launched), status != 0 {
                throw AndroidError.emulatorExited(status: status, logPath: logPath ?? "", tail: logTail(logPath))
            }
            if host.uptime() - started >= EmulatorBooter.discoveryGrace, let serial = try await newAdbSerial(knownSerials) {
                return serial
            }
            try checkDeadline(serial: nil, logPath: logPath)
            try await host.sleep(EmulatorBooter.serialPoll)
        }
    }

    /// Until adb reports `sys.boot_completed`, then, when the emulator has a gRPC endpoint, until `getStatus` says booted.
    func untilBooted(_ serial: String, logPath: String?, progress: (String) -> Void) async throws -> Bool {
        progress("Waiting for Android to finish booting on \(serial)...")
        let directory = AndroidDeviceDirectory(client: client, host: host)
        while true {
            if let emulator = try? await directory.runningEmulator(serial: serial), emulator.state == .device, emulator.bootCompleted {
                break
            }
            try checkDeadline(serial: serial, logPath: logPath)
            try await host.sleep(EmulatorBooter.bootPoll)
        }
        guard try EmulatorTransportSelector.mode(host: host) != .adb, let discovery = discovery(for: serial), discovery.grpcPort != nil else {
            return false
        }
        return try await untilGrpcBooted(serial, discovery: discovery, logPath: logPath)
    }

    private func untilGrpcBooted(_ serial: String, discovery: EmulatorDiscovery, logPath: String?) async throws -> Bool {
        var emulator: (any EmulatorControlling)?
        while true {
            do {
                if emulator == nil {
                    let auth = try await EmulatorAuth.choose(for: discovery, host: host)
                    do {
                        emulator = try await host.emulatorConnector.connect(discovery: discovery, auth: auth)
                    } catch {
                        auth.close()
                        throw error
                    }
                }
                if try await emulator?.status().booted == true {
                    await emulator?.close()
                    return true
                }
            } catch let error as AndroidError where error.kind == .grpcUnavailable || error.kind == .grpcDeadlineExceeded {
                log(.debug, "gRPC on \(serial) is not ready yet: \(error.message)")
            } catch {
                await emulator?.close()
                let message = (error as? AndroidError)?.message ?? error.localizedDescription
                log(.warning, "\(message) Commands will use adb for \(serial).")
                return false
            }
            do {
                try checkDeadline(serial: serial, logPath: logPath)
                try await host.sleep(EmulatorBooter.bootPoll)
            } catch {
                await emulator?.close()
                throw error
            }
        }
    }

    private func newAdbSerial(_ known: Set<String>) async throws -> String? {
        let directory = AndroidDeviceDirectory(client: client, host: host)
        for entry in try await client.devices() where entry.consolePort != nil && !known.contains(entry.serial) {
            if let emulator = try? await directory.runningEmulator(serial: entry.serial), emulator.avdName == avdName {
                return entry.serial
            }
        }
        return nil
    }

    private func checkDeadline(serial: String?, logPath: String?) throws {
        guard host.uptime() < deadline else {
            throw AndroidError.bootTimeout(avd: avdName, serial: serial, seconds: Int(timeout.components.seconds), logPath: logPath)
        }
    }

    /// The last 20 lines of the emulator's log.
    private func logTail(_ path: String?) -> String {
        guard let path, let data = host.files.contents(atPath: path) else { return "" }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(20).joined(separator: "\n")
    }
}
