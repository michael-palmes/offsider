import ArgumentParser
import Darwin
import Foundation
import OffsiderAndroid
import OffsiderCore

/// The detached broker that keeps an Android device's UiAutomation helper warm between commands; an internal entry point, not a supported command.
struct AndroidSessionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "android-session",
        shouldDisplay: false,
        subcommands: [AndroidSessionServe.self]
    )
}

struct AndroidSessionServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", shouldDisplay: false)

    @Option(name: .customLong("device"), help: ArgumentHelp("The emulator or USB phone to serve.", valueName: "serial"))
    var device: String

    @MainActor
    func run() async throws {
        let serial = device.trimmingCharacters(in: .whitespaces)
        // Gated again here, before anything reaches the device, since anything can start this entry point directly.
        switch DeviceIDClassifier.classify(serial) {
        case .androidSerial:
            break
        case .androidName:
            guard ProcessInfo.processInfo.environment["OFFSIDER_ANDROID_SESSION"]?.lowercased() == "on" else {
                throw CLIError(errorDescription: "A USB phone keeps its helper warm only with OFFSIDER_ANDROID_SESSION=on.", reason: .usage)
            }
            _ = try DeviceRouter.requireAllowed(platform: .android, key: serial, rawID: serial, gate: DevicePolicyGate.current)
        default:
            throw CLIError(errorDescription: "\(serial) is not an Android emulator or USB phone serial.", reason: .invalidDeviceID)
        }
        var host = AndroidHost.cli()
        // The broker outlives every command, so it never holds a command's device lock.
        host.claimDevice = { _ in }
        let log: AndroidLog = { level, message in
            guard level != .debug else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardOutput.write(Data("\(stamp) \(message)\n".utf8))
        }
        let backend = AndroidBackend(host: host, log: log)
        let broker = try await backend.warmHelperBroker(for: serial)
        let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { broker.requestStop() } }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        try await broker.run()
        await backend.close()
    }
}
