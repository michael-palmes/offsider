import ArgumentParser
import Foundation
import OffsiderCore

extension DevicePlatform: ExpressibleByArgument {}

/// `devices`: the device list, and the phones and tablets a person lets agents drive. It runs itself without a subcommand.
struct ListDevices: AsyncParsableCommand, RunsWithoutSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List devices and their IDs, and add or remove the phones and tablets agents may drive.",
        discussion: """
        Simulators and emulators need nothing added. A physical iPhone, iPad or Android phone is refused until a person adds it \
        from their own terminal: `add` lets you pick the device, the signing team (iPhone or iPad), the app and how long from menus, \
        then asks for Touch ID or your password. Each one lapses (12 hours by default, at most 30 days unless `never`) and can pin the \
        app Offsider may drive on it. The list lives in ~/.config/offsider/allowed-devices.json, sealed in the login Keychain; an edit \
        made outside Offsider refuses every device until `add` runs again. A managed preference (domain com.mpalmes.offsider) can \
        forbid devices the list allows, never the reverse.

        Examples:
          offsider devices
          offsider devices add
          offsider devices remove
          offsider devices status --json
        """,
        subcommands: [DeviceAccessAllow.self, DeviceAccessRemove.self, DeviceAccessStatus.self]
    )

    @OptionGroup var options: DeviceListOptions

    func run() async throws {
        try await Self.list(options)
    }

    static func list(_ options: DeviceListOptions) async throws {
        let console = Console.current
        let (listed, skipped) = try await console.progress("Looking for devices") { try await Self.listDevices(platform: options.platform, logger: OffsiderLogger()) }
        let (shown, hidden) = Self.applyPolicy(listed, physicalOnly: options.physical, gate: DevicePolicyGate.current)
        let ordered = DeviceListOrder.sorted(shown)
        let devices = Self.withLeases(Self.withHolders(options.booted ? DeviceListOrder.running(ordered) : ordered))
        let listing = DeviceListing(devices: devices, hiddenPhysical: hidden, skipped: skipped, currentDefault: DeviceDefault.environment())
        if options.json {
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

/// The flags `devices` and `list-devices` share.
struct DeviceListOptions: ParsableArguments {
    @OptionGroup var output: DeviceJSONOption

    var json: Bool { output.json }

    @OptionGroup var filters: DeviceListFilters

    var platform: DevicePlatform? { filters.platform }
    var physical: Bool { filters.physical }
    var booted: Bool { filters.booted }
}

/// The list's filters. `devices` parses them wherever they fall, so its subcommands declare this group too, receive them and refuse them.
struct DeviceListFilters: ParsableArguments {
    @Option(name: .customLong("platform"), help: "Only list devices on this platform.")
    var platform: DevicePlatform?

    @Flag(name: .customLong("physical"), help: "List only physical devices, including the ones no one has added with `offsider devices add`.")
    var physical = false

    @Flag(name: .customLong("booted"), help: "List only booted or booting devices.")
    var booted = false

    /// A usage error for `devices <subcommand>` when any filter is set, naming the listing command it meant.
    func refuse(in subcommand: any ParsableCommand.Type) throws {
        let set: [(flag: String, argument: String)?] = [
            platform.map { ("--platform", "--platform \($0.rawValue)") },
            physical ? ("--physical", "--physical") : nil,
            booted ? ("--booted", "--booted") : nil,
        ]
        let filters = set.compactMap { $0 }
        guard let last = filters.last?.flag else { return }
        let named = filters.count == 1 ? last : filters.dropLast().map(\.flag).joined(separator: ", ") + " and " + last
        throw ValidationError(
            "\(named) \(filters.count == 1 ? "filters" : "filter") the device list; devices \(subcommand._commandName) takes --device <id>. To list: offsider devices \(filters.map(\.argument).joined(separator: " "))"
        )
    }
}

/// `--json` for `devices` and its subcommands. The parent parses it wherever it falls, and a subcommand declaring the same group gets that value, so `devices status --json` and `devices --json status` both reach `status`.
struct DeviceJSONOption: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false
}
