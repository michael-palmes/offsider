import ArgumentParser
import Foundation
import OffsiderCore

extension DevicePlatform: ExpressibleByArgument {}

struct ListDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Lists available devices and the IDs other commands take.",
        aliases: ["list-devices"]
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout instead of a table.")
    var json = false

    @Option(name: .customLong("platform"), help: "Only list devices on this platform.")
    var platform: DevicePlatform?

    @Flag(name: .customLong("physical"), help: "List only physical devices, including the ones no one has allowed with `offsider device-access allow`.")
    var physical = false

    @Flag(name: .customLong("booted"), help: "List only booted or booting devices.")
    var booted = false

    func run() async throws {
        let console = Console.current
        let (listed, skipped) = try await console.progress("Looking for devices") { try await Self.listDevices(platform: platform, logger: OffsiderLogger()) }
        let (shown, hidden) = Self.applyPolicy(listed, physicalOnly: physical, gate: DevicePolicyGate.current)
        let ordered = DeviceListOrder.sorted(shown)
        let devices = Self.withLeases(Self.withHolders(booted ? DeviceListOrder.running(ordered) : ordered))
        let listing = DeviceListing(devices: devices, hiddenPhysical: hidden, skipped: skipped, currentDefault: DeviceDefault.environment())
        if json {
            console.data(DeviceListRenderer.json(devices, hiddenPhysical: hidden, compact: console.out.profile == .agent))
            DevicesScreen.notices(listing).forEach(console.notice)
        } else {
            console.show(DevicesScreen.page(listing))
        }
    }

    /// Marks each physical row allowed or not; without `physicalOnly`, rows that are not allowed are dropped and counted. The policy is read only when a physical row exists.
    static func applyPolicy(_ devices: [DeviceSummary], physicalOnly: Bool, gate: DevicePolicyGate) -> (shown: [DeviceSummary], hidden: Int) {
        guard devices.contains(where: { $0.kind == .physical }) else { return (physicalOnly ? [] : devices, 0) }
        var hidden = 0
        var shown: [DeviceSummary] = []
        for var device in devices {
            guard device.kind == .physical else {
                if !physicalOnly { shown.append(device) }
                continue
            }
            let key = StableDeviceKey.of(device) ?? device.id
            if case .allowed = gate.decision(platform: device.platform, key: key) { device.allowed = true } else { device.allowed = false }
            if physicalOnly || device.allowed == true {
                shown.append(device)
            } else {
                hidden += 1
            }
        }
        return (shown, hidden)
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

    /// Fills `lease` from each row's stable key, so an emulator's lease follows its AVD across serials, and whether it is this session's.
    static func withLeases(
        _ devices: [DeviceSummary], store: DeviceLeaseStore = DeviceLeaseStore(), now: Date = Date(),
        sessionLabel: String? = ProcessInfo.processInfo.environment[DeviceLeaseRules.sessionVariable],
        processes: ProcessTable = .live, selfPID: Int32 = getpid()
    ) -> [DeviceSummary] {
        var ancestors: [ProcessIdentity]?
        return devices.map { device in
            guard let key = StableDeviceKey.of(device) else { return device }
            var device = device
            device.lease = store.lease(platform: device.platform, key: key, now: now)
            if let lease = device.lease {
                let chain = ancestors ?? ProcessAncestry.ancestors(of: selfPID, in: processes)
                ancestors = chain
                device.leaseIsMine = DeviceLeaseRules.ownership(of: lease, sessionLabel: sessionLabel, ancestors: chain, processes: processes) == .thisSession
            }
            return device
        }
    }

    @MainActor
    private static func listDevices(platform: DevicePlatform?, logger: OffsiderLogger) async throws -> (devices: [DeviceSummary], skipped: [ListingSkip]) {
        let backends = DeviceRouter.allBackends(logger: logger).filter { platform == nil || $0.platform == platform }
        var skipped: [ListingSkip] = []
        let devices = try await collect(from: backends, platformFilter: platform) { skipped.append($0) }
        return (devices, skipped)
    }

    /// Each backend is prepared on its own, so one missing toolchain only warns unless every backend fails.
    /// A platform whose toolchain is not installed at all is skipped quietly, unless `--platform` asked for it.
    @MainActor
    static func collect(
        from backends: [any DeviceBackend],
        platformFilter: DevicePlatform? = nil,
        warn: (ListingSkip) -> Void
    ) async throws -> [DeviceSummary] {
        var devices: [DeviceSummary] = []
        var failures: [(platform: DevicePlatform, name: String, error: Error)] = []
        var skipped = 0
        for backend in backends {
            do {
                try await backend.prepare()
                devices += try await backend.listDevices()
            } catch is PlatformUnavailable where platformFilter == nil {
                skipped += 1
            } catch {
                failures.append((backend.platform, backend.listingName, error))
            }
        }

        let allFailed = !failures.isEmpty && failures.count == backends.count - skipped
        // The iOS simulator and device backends share one Xcode, so they often fail alike.
        var groups: [(platform: DevicePlatform, names: [String], error: Error)] = []
        for failure in failures {
            if let index = groups.firstIndex(where: { $0.platform == failure.platform && message(for: $0.error) == message(for: failure.error) }) {
                groups[index].names.append(failure.name)
            } else {
                groups.append((failure.platform, [failure.name], failure.error))
            }
        }
        if allFailed {
            if groups.count == 1 {
                throw groups[0].error
            }
            let details = groups.map { "\($0.platform.rawValue): \(message(for: $0.error))" }
            let reasons = groups.map { ($0.error as? any OffsiderFailure)?.reason }
            let missing = reasons.allSatisfy { $0?.exitCode == .toolMissing }
            throw CLIError(
                errorDescription: "Could not list devices.\n" + details.joined(separator: "\n"),
                reason: missing ? (reasons[0] ?? .deviceListFailed) : .deviceListFailed
            )
        }
        for group in groups {
            let what = group.names.count > 1 ? group.platform.devicesName : group.names[0]
            warn(ListingSkip(what: what, message: message(for: group.error), hint: (group.error as? any OffsiderFailure)?.hint))
        }
        return devices
    }

    private static func message(for error: Error) -> String {
        (error as? UserFacingError)?.userFacingDescription ?? error.localizedDescription
    }
}
