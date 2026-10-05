import ArgumentParser
import Darwin
import Foundation
import OffsiderCore
import OffsiderIOSDevice

/// The detached broker `offsider` starts for a physical device; an internal entry point, not a supported command.
struct DeviceSessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-session",
        shouldDisplay: false,
        subcommands: [DeviceSessionServe.self]
    )
}

struct DeviceSessionServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", shouldDisplay: false)

    @Option(name: .customLong("device"), help: ArgumentHelp("The iPhone or iPad to serve.", valueName: "id"))
    var device: String

    @MainActor
    func run() async throws {
        let udid = device.trimmingCharacters(in: .whitespaces)
        let store = DeviceSessionStore(root: OffsiderPrivateDirectory.root)
        let socket = try store.socketPath(udid: udid)
        let log: IOSDeviceLog = { level, message in
            guard level != .debug else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardOutput.write(Data("\(stamp) \(message)\n".utf8))
        }
        var host = IOSDeviceHost.live()
        if Timings.isEnabled {
            host.timing = .printing { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        }
        let server = DeviceSessionServer(
            udid: udid,
            socketPath: socket,
            hardware: CoreDeviceSessionHardware(udid: udid, host: host, log: log),
            store: store,
            idleTimeout: .seconds(DeviceSessionServer.idleSeconds(ProcessInfo.processInfo.environment)),
            log: log
        )
        let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { server.requestStop() } }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        try await server.run()
    }
}
