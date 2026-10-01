import Foundation
import OffsiderCore

struct RunningEmulator: Equatable, Sendable {
    let serial: String
    let consolePort: Int
    let state: AdbDeviceState
    let avdName: String?
    let bootCompleted: Bool
    /// The emulator is in state `device` but its properties could not be read, so its boot state is unknown.
    let propertiesUnreadable: Bool
    let osRelease: String?
    let apiLevel: Int?
    let model: String?
    let discovery: EmulatorDiscovery?
}

/// Running emulators from adb plus discovery files, and the AVDs on this Mac.
struct AndroidDeviceDirectory {
    static let propertiesScript = "getprop ro.boot.qemu.avd_name; getprop ro.kernel.qemu.avd_name; getprop sys.boot_completed; getprop ro.build.version.release; getprop ro.build.version.sdk"

    let client: AdbClient
    let host: AndroidHost

    /// `emulator-NNNN` rows only, by console port; physical devices and `host:port` serials are out of scope.
    /// Without `detailed`, an emulator whose discovery file names its AVD is not queried at all.
    func runningEmulators(detailed: Bool = true) async throws -> [RunningEmulator] {
        let discoveries = EmulatorDiscovery.live(host: host)
        let entries = try await client.devices()
            .compactMap { entry in entry.consolePort.map { (entry, $0) } }
            .sorted { $0.1 < $1.1 }
        var emulators: [RunningEmulator] = []
        for (entry, port) in entries {
            let discovery = discoveries.first { $0.consolePort == port }
            let query = entry.state == .device && (detailed || discovery?.avdID == nil)
            emulators.append(try await describe(entry, port: port, discovery: discovery, queryDevice: query))
        }
        return emulators
    }

    /// One serial only, so checking a device never queries the other emulators.
    func runningEmulator(serial: String) async throws -> RunningEmulator? {
        guard let entry = try await client.devices().first(where: { $0.serial == serial }),
              let port = entry.consolePort else {
            return nil
        }
        let discovery = EmulatorDiscovery.live(host: host).first { $0.consolePort == port }
        return try await describe(entry, port: port, discovery: discovery, queryDevice: entry.state == .device, throwing: true)
    }

    /// With `throwing`, a failed property query is the error; otherwise the row says its state is unknown.
    private func describe(
        _ entry: AdbDeviceEntry,
        port: Int,
        discovery: EmulatorDiscovery?,
        queryDevice: Bool,
        throwing: Bool = false
    ) async throws -> RunningEmulator {
        var properties = [String](repeating: "", count: 5)
        var unreadable = false
        if queryDevice {
            do {
                let result = try await client.shell(Self.propertiesScript, on: entry.serial, timeout: .seconds(5), label: "getprop")
                let lines = result.stdoutText.split(separator: "\n", omittingEmptySubsequences: false)
                for index in 0..<min(5, lines.count) {
                    properties[index] = lines[index].trimmingCharacters(in: .whitespaces)
                }
            } catch {
                if throwing { throw error }
                unreadable = true
            }
        }
        return RunningEmulator(
            serial: entry.serial,
            consolePort: port,
            state: entry.state,
            avdName: [discovery?.avdID ?? "", properties[0], properties[1]].first { !$0.isEmpty },
            bootCompleted: properties[2] == "1",
            propertiesUnreadable: unreadable,
            osRelease: properties[3].isEmpty ? nil : properties[3],
            apiLevel: Int(properties[4]),
            model: entry.properties["model"],
            discovery: discovery
        )
    }

    /// One running instance of the AVD gives its serial; none or several are errors that say what to do.
    func serial(forAVDNamed name: String) async throws -> String {
        let matches = try await runningEmulators(detailed: false).filter { $0.avdName == name }
        if matches.count == 1 {
            return matches[0].serial
        }
        if matches.count > 1 {
            throw AndroidError.avdRunningTwice(name, serials: matches.map(\.serial))
        }
        if AVDCatalog(host: host).info(named: name) != nil {
            throw AndroidError.avdNotRunning(name)
        }
        throw AndroidError.noDeviceNamed(name)
    }

    /// Running emulators by serial, then AVDs that are not running, by name.
    func summaries() async throws -> [DeviceSummary] {
        let catalog = AVDCatalog(host: host)
        let avds = catalog.all()
        let running = try await runningEmulators()
        let runningNames = Set(running.compactMap(\.avdName))

        let runningRows = running.map { emulator in
            let avd = emulator.avdName.flatMap { name in avds.first { $0.name == name } }
            return DeviceSummary(
                id: emulator.serial,
                platform: .android,
                state: Self.stateName(emulator),
                name: emulator.avdName ?? emulator.serial,
                osVersion: emulator.osRelease.map { "Android \($0)" } ?? emulator.apiLevel.map { "Android API \($0)" },
                deviceType: avd?.deviceProfile ?? emulator.model
            )
        }
        let shutdownRows = avds.filter { !runningNames.contains($0.name) }.map { avd in
            DeviceSummary(
                id: avd.name,
                platform: .android,
                state: "Shutdown",
                name: avd.name,
                osVersion: avd.apiLevel.map { "Android API \($0)" },
                deviceType: avd.deviceProfile
            )
        }
        return runningRows + shutdownRows
    }

    static func stateName(_ emulator: RunningEmulator) -> String {
        switch emulator.state {
        case .device where emulator.propertiesUnreadable: return "Unknown"
        case .device: return emulator.bootCompleted ? "Booted" : "Booting"
        case .offline: return "Offline"
        case .unauthorized: return "Unauthorised"
        case .other(let state): return state.prefix(1).uppercased() + state.dropFirst()
        }
    }
}
