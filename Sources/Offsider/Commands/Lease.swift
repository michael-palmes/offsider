import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

struct LeaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Mark a device as used by one session, release it, or show leases. Advisory: input commands never read leases.",
        discussion: """
        A lease is a label and an expiry kept under the device's stable name (an AVD name, a phone serial or a UDID), \
        so it survives an emulator restart on another serial; a shut-down AVD can be leased by name. `set` fails with \
        exit 8 (device_leased) while another label holds a live lease, unless --force; the same label renews it. \
        `list-devices` shows leases, and `doctor --device` warns about one unless OFFSIDER_LEASE matches its label.

        Examples:
          offsider lease set --device Offsider_E2E --label 'PR 123 review'
          offsider lease show --json
          offsider lease release --device Offsider_E2E
        """
    )

    enum Action: String, CaseIterable {
        case set
        case release
        case show
    }

    @Argument(help: ArgumentHelp("set, release or show.", valueName: "action"))
    var action: String

    @Option(name: .customLong("label"), help: ArgumentHelp("With set: who holds the device, 1 to 80 characters.", valueName: "text"))
    var label: String?

    @Option(name: .customLong("ttl"), help: ArgumentHelp("With set: minutes until the lease lapses, from 1 to 1440 (default 240).", valueName: "minutes"))
    var ttl: Int?

    @Flag(name: .customLong("force"), help: "With set: replace a lease another label holds.")
    var force = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @Option(name: .customLong("device"), help: ArgumentHelp("The device (default OFFSIDER_DEVICE for set and release); with show, only this device.", valueName: "id"))
    var explicitDevice: String?

    func validate() throws {
        let parsed = try parsedAction()
        if parsed != .set {
            if label != nil { throw ValidationError("--label goes with set, not \(parsed.rawValue).") }
            if ttl != nil { throw ValidationError("--ttl goes with set, not \(parsed.rawValue).") }
            if force { throw ValidationError("--force goes with set, not \(parsed.rawValue).") }
        }
        if parsed == .set {
            guard let label else { throw ValidationError("lease set needs --label <text>, such as --label 'PR 123 review'.") }
            guard DeviceLease.validLabel(label) != nil else { throw ValidationError("--label must be 1 to 80 printable characters.") }
            if let ttl, !DeviceLease.minutes.contains(ttl) { throw ValidationError("--ttl must be from 1 to 1440 minutes; got \(ttl).") }
        }
        if parsed != .show, device == nil { throw ValidationError(DeviceDefault.missingMessage) }
    }

    func parsedAction() throws -> Action {
        guard let parsed = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(action)'. Use set, release or show.")
        }
        return parsed
    }

    /// `show` lists every lease unless --device names one, so OFFSIDER_DEVICE never narrows it.
    var device: String? {
        (try? parsedAction()) == .show ? explicitDevice : DeviceDefault.resolve(explicit: explicitDevice)?.id
    }

    @MainActor
    func run() async throws {
        let store = DeviceLeaseStore()
        let target = try await device.asyncMap { try await Self.resolve($0) }
        print(try Self.perform(
            try parsedAction(), target: target, label: label.flatMap(DeviceLease.validLabel), minutes: ttl ?? DeviceLease.defaultMinutes,
            force: force, json: json, store: store, now: Date(), pid: getppid()
        ))
    }

    /// The device's stable key; an emulator serial is asked for its AVD name.
    @MainActor
    static func resolve(_ id: String) async throws -> (platform: DevicePlatform, key: String) {
        if let key = StableDeviceKey.of(id: id) { return key }
        guard case .androidSerial = DeviceIDClassifier.classify(id) else {
            throw CLIError(errorDescription: "\(id) is not a device ID. Run `offsider list-devices` to find device IDs.", reason: .invalidDeviceID, hint: "offsider list-devices")
        }
        let route = try await DeviceRouter.route(id, logger: OffsiderLogger())
        try await route.backend.prepare()
        let booted = try await route.backend.requireBootedDevice(route.device)
        guard let key = StableDeviceKey.of(booted) else {
            throw CLIError(errorDescription: "Could not read the AVD name of \(id), which a lease is kept under. Lease it by its AVD name from `offsider list-devices`.", reason: .commandFailed, hint: "offsider list-devices")
        }
        return (.android, key)
    }

    static func perform(
        _ action: Action, target: (platform: DevicePlatform, key: String)?, label: String?, minutes: Int, force: Bool, json: Bool,
        store: DeviceLeaseStore, now: Date, pid: Int32
    ) throws -> String {
        switch action {
        case .set:
            guard let target, let label else { throw ValidationError(DeviceDefault.missingMessage) }
            let (existing, lease) = try store.set(platform: target.platform, key: target.key, now: now) { existing in
                try claim(existing, key: target.key, label: label, minutes: minutes, force: force, now: now, pid: pid)
            }
            let renewing = existing?.label == label
            if json { return report("set", target: target, lease: lease) }
            let verb = renewing ? "Renewed the lease on" : "Leased"
            return "\(verb) \(target.key) to '\(label)' until \(DeviceLeaseRules.clock(lease.expires)). Run `export OFFSIDER_LEASE=\(shellQuoted(label))` so `offsider doctor` knows this session holds it."
        case .release:
            guard let target else { throw ValidationError(DeviceDefault.missingMessage) }
            let removed = store.remove(platform: target.platform, key: target.key, now: now)
            if json { return report("release", target: target, lease: removed) }
            return removed.map { "Released the lease '\($0.label)' on \(target.key)." } ?? "\(target.key) was not leased."
        case .show:
            let leases = target.map { target in
                store.lease(platform: target.platform, key: target.key, now: now).map { [LeasedDevice(platform: target.platform, key: target.key, lease: $0)] } ?? []
            } ?? store.all(now: now)
            if json { return showReport(leases) }
            guard !leases.isEmpty else { return target.map { "\($0.key) is not leased." } ?? "No devices are leased." }
            return leases.map { "\($0.platform.rawValue)  \($0.key)  '\($0.lease.label)'  since \(DeviceLeaseRules.clock($0.lease.created)), until \(DeviceLeaseRules.clock($0.lease.expires))" }
                .joined(separator: "\n")
        }
    }

    /// The lease `set` writes over `existing`: refused while another label holds it unless `force`, and renewed for the same label.
    static func claim(_ existing: DeviceLease?, key: String, label: String, minutes: Int, force: Bool, now: Date, pid: Int32) throws -> DeviceLease {
        if let existing, existing.label != label, !force {
            throw CLIError(
                errorDescription: "\(key) is leased to '\(existing.label)' since \(DeviceLeaseRules.clock(existing.created)), until \(DeviceLeaseRules.clock(existing.expires)). Choose another device, or pass --force if that lease is stale.",
                reason: .deviceLeased,
                hint: "offsider lease show --device \(key)"
            )
        }
        let created = existing.flatMap { $0.label == label ? $0.created : nil } ?? now
        return DeviceLease(label: label, created: created, expires: now.addingTimeInterval(TimeInterval(minutes * 60)), pid: pid)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func report(_ action: String, target: (platform: DevicePlatform, key: String), lease: DeviceLease?) -> String {
        DeviceStateReport.lease(action, platform: target.platform, device: target.key, lease: lease)
    }

    static func showReport(_ leases: [LeasedDevice]) -> String {
        DeviceStateReport.leases(leases)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
