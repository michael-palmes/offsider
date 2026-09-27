import ArgumentParser
import Foundation
import OffsiderCore

extension DevicePlatform: ExpressibleByArgument {}

struct ListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Lists available devices and the IDs other commands take."
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of a table.")
    var json = false

    @Option(name: .customLong("platform"), help: "Only list devices on this platform.")
    var platform: DevicePlatform?

    func run() async throws {
        let devices = try await Self.listDevices(platform: platform, logger: OffsiderLogger())
        print(json ? DeviceListRenderer.json(devices) : DeviceListRenderer.table(devices), terminator: "")
    }

    @MainActor
    private static func listDevices(platform: DevicePlatform?, logger: OffsiderLogger) async throws -> [DeviceSummary] {
        let backends = DeviceRouter.allBackends(logger: logger).filter { platform == nil || $0.platform == platform }
        return try await collect(from: backends) { warning in
            FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
        }
    }

    /// Each backend is prepared on its own, so one missing toolchain only warns unless every backend fails.
    @MainActor
    static func collect(from backends: [any DeviceBackend], warn: (String) -> Void) async throws -> [DeviceSummary] {
        var devices: [DeviceSummary] = []
        var failures: [(platform: DevicePlatform, error: Error)] = []
        for backend in backends {
            do {
                try await backend.prepare()
                devices += try await backend.listDevices()
            } catch {
                failures.append((backend.platform, error))
            }
        }

        if !failures.isEmpty, failures.count == backends.count {
            if failures.count == 1 {
                throw failures[0].error
            }
            let details = failures.map { "\($0.platform.rawValue): \(message(for: $0.error))" }
            throw CLIError(errorDescription: "Could not list devices.\n" + details.joined(separator: "\n"))
        }
        for failure in failures {
            warn("Skipped \(failure.platform.rawValue) devices: \(message(for: failure.error))")
        }
        return devices
    }

    private static func message(for error: Error) -> String {
        (error as? UserFacingError)?.userFacingDescription ?? error.localizedDescription
    }
}
