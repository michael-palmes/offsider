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
        let devices = Self.withLeases(Self.withHolders(try await Self.listDevices(platform: platform, logger: OffsiderLogger())))
        print(json ? DeviceListRenderer.json(devices) : DeviceListRenderer.table(devices), terminator: "")
        for hint in Self.phoneHints(devices) + Self.holderNotes(devices) + Self.leaseNotes(devices) {
            FileHandle.standardError.write(Data("\(hint)\n".utf8))
        }
    }

    /// Fills `heldBy` for every row that can be locked; a shut-down AVD cannot.
    static func withHolders(_ devices: [DeviceSummary], holder: (DeviceLockKey) -> DeviceLockHolder? = { DeviceLock.currentHolder($0) }) -> [DeviceSummary] {
        devices.map { device in
            guard device.kind != .avd else { return device }
            var device = device
            device.heldBy = holder(DeviceLockKey(platform: device.platform, id: device.id))
            return device
        }
    }

    /// Fills `lease` from each row's stable key, so an emulator's lease follows its AVD across serials.
    static func withLeases(_ devices: [DeviceSummary], store: DeviceLeaseStore = DeviceLeaseStore(), now: Date = Date()) -> [DeviceSummary] {
        devices.map { device in
            guard let key = StableDeviceKey.of(device) else { return device }
            var device = device
            device.lease = store.lease(platform: device.platform, key: key, now: now)
            return device
        }
    }

    static func leaseNotes(_ devices: [DeviceSummary]) -> [String] {
        devices.compactMap { device in
            device.lease.map { "\(device.id) is leased to '\($0.label)' until \(DeviceLeaseRules.clock($0.expires)) (offsider lease show)." }
        }
    }

    /// One line per device another Offsider command is driving.
    static func holderNotes(_ devices: [DeviceSummary], now: Date = Date()) -> [String] {
        devices.compactMap { device in
            guard let holder = device.heldBy else { return nil }
            let command = holder.command.isEmpty ? "offsider" : "offsider \(holder.command)"
            let age = holder.startedAt.map { ", started \(max(0, Int(now.timeIntervalSince($0)))) s ago" } ?? ""
            return "\(device.id) is in use by pid \(holder.pid) (\(command)\(age))."
        }
    }

    /// One line per phone Offsider cannot drive yet, saying what the user must do.
    static func phoneHints(_ devices: [DeviceSummary]) -> [String] {
        devices.filter { $0.kind == .physical }.compactMap { device in
            if device.platform == .ios {
                return iosHint(device)
            }
            if device.connection == "network" {
                return "\(device.id) is a network adb connection, which Offsider does not drive; connect the phone over USB."
            }
            if device.state == "Unauthorised" {
                return "\(device.id) is unauthorised: unlock the phone and accept the \"Allow USB debugging?\" prompt, then run `offsider list-devices` again."
            }
            return nil
        }
    }

    private static func iosHint(_ device: DeviceSummary) -> String? {
        let name = DeviceName.display(device.id, label: device.name)
        switch device.state {
        case "Untrusted":
            return "\(name) does not trust this Mac: unlock it and tap Trust, then run `offsider list-devices` again."
        case "Developer Mode off":
            return "\(name) has Developer Mode off: turn it on in Settings > Privacy & Security > Developer Mode, then restart it."
        case "Preparing":
            return "\(name) is being prepared for development by Xcode: keep it connected and unlocked until that finishes."
        case "Unavailable":
            return "\(name) is paired but not connected: connect its cable and unlock it."
        default:
            return device.connection == "network"
                ? "\(name) is connected over Wi-Fi, which Offsider does not drive; connect its cable."
                : nil
        }
    }

    @MainActor
    private static func listDevices(platform: DevicePlatform?, logger: OffsiderLogger) async throws -> [DeviceSummary] {
        let backends = DeviceRouter.allBackends(logger: logger).filter { platform == nil || $0.platform == platform }
        return try await collect(from: backends, platformFilter: platform) { warning in
            FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
        }
    }

    /// Each backend is prepared on its own, so one missing toolchain only warns unless every backend fails.
    /// A platform whose toolchain is not installed at all is skipped quietly, unless `--platform` asked for it.
    @MainActor
    static func collect(
        from backends: [any DeviceBackend],
        platformFilter: DevicePlatform? = nil,
        warn: (String) -> Void
    ) async throws -> [DeviceSummary] {
        var devices: [DeviceSummary] = []
        var failures: [(platform: DevicePlatform, error: Error)] = []
        var skipped = 0
        for backend in backends {
            do {
                try await backend.prepare()
                devices += try await backend.listDevices()
            } catch is PlatformUnavailable where platformFilter == nil {
                skipped += 1
            } catch {
                failures.append((backend.platform, error))
            }
        }

        if !failures.isEmpty, failures.count == backends.count - skipped {
            if failures.count == 1 {
                throw failures[0].error
            }
            let details = failures.map { "\($0.platform.rawValue): \(message(for: $0.error))" }
            let reasons = failures.map { ($0.error as? any OffsiderFailure)?.reason }
            let missing = reasons.allSatisfy { $0?.exitCode == .toolMissing }
            throw CLIError(
                errorDescription: "Could not list devices.\n" + details.joined(separator: "\n"),
                reason: missing ? (reasons[0] ?? .deviceListFailed) : .deviceListFailed
            )
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
