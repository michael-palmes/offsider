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
        BrokerLimits.apply()
        let udid = device.trimmingCharacters(in: .whitespaces)
        // Gated again here, before CoreDevice opens, since anything can start this entry point directly.
        guard case .iosDevice(let canonical) = DeviceIDClassifier.classify(udid) else {
            throw CLIError(errorDescription: "\(udid) is not a physical iPhone or iPad UDID.", reason: .invalidDeviceID)
        }
        let key = canonical.uppercased()
        _ = try DeviceRouter.requireAllowed(platform: .ios, key: key, rawID: udid, gate: DevicePolicyGate.current)
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
        let usbmux = host.usbmux
        let recheck: DeviceSessionRecheck = {
            Self.allowanceRefusal(key: key, gate: Self.freshGate) ?? DeviceSessionServer.usbRefusal(udid: udid, usbmux: usbmux)
        }
        let server = DeviceSessionServer(
            udid: udid,
            socketPath: socket,
            hardware: CoreDeviceSessionHardware(udid: udid, host: host, log: log),
            store: store,
            idleTimeout: .seconds(DeviceSessionServer.idleSeconds(ProcessInfo.processInfo.environment)),
            recheck: recheck,
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

    /// Reads the allow-list, its seal and managed policy afresh on every call, unlike the once-per-process gate a command uses.
    static let freshGate = DevicePolicyGate(policy: {
        DevicePolicyGate.read(store: DevicePolicySources.store(), seal: KeychainDeviceAllowListSeal(), managed: LiveManagedPreferences())
    })

    /// The refusal a command would get now, through the same gate; nil while the device is still allowed.
    static func allowanceRefusal(key: String, gate: DevicePolicyGate) -> IOSDeviceError? {
        do {
            try gate.require(platform: .ios, key: key)
            return nil
        } catch let error as CLIError {
            return IOSDeviceError(.notAllowed, error.userFacingDescription, hint: error.hint ?? "offsider device-access allow")
        } catch {
            return IOSDeviceError(.notAllowed, "\(key) could not be checked against the allow-list (\(error)), so its device session stopped.", hint: "offsider device-access allow")
        }
    }
}
