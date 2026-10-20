import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

struct LeaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Mark a device as used by one session, release it, check it, or show leases. Advisory: input commands never read leases.",
        discussion: """
        A lease is a label and an expiry kept under the device's stable name (an AVD name, a phone serial or a UDID), \
        so it survives an emulator restart on another serial; a shut-down AVD can be leased by name. `set` fails with \
        exit 8 (device_leased) while another label holds a live lease, unless --force; the same label renews it. \
        `set` records the session it runs in (the agent or terminal above its shell), so `doctor --device` passes \
        for any later command of that session and warns for any other. When OFFSIDER_LEASE is set it decides \
        instead, passing only for a matching label. `devices` shows leases. `check` is a read-only snapshot: \
        exit 0 when the device is free or this session's (by session, --label or OFFSIDER_LEASE), exit 8 \
        (device_leased) while another session's lease is live, even when that session has ended; only `set` claims \
        a device atomically. For a UDID or an AVD name it reads only the lease file and the process table.

        Examples:
          offsider lease set --device Offsider_E2E --label 'PR 123 review'
          offsider lease check --device Offsider_E2E --json
          offsider lease show --json
          offsider lease release --device Offsider_E2E
        """
    )

    enum Action: String, CaseIterable {
        case set
        case release
        case show
        case check
    }

    @Argument(help: ArgumentHelp("set, release, show or check.", valueName: "action"))
    var action: String

    @Option(name: .customLong("label"), help: ArgumentHelp("With set: who holds the device, 1 to 80 characters. With check: the label that counts as this session's.", valueName: "text"))
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
            if label != nil, parsed != .check { throw ValidationError("--label goes with set or check, not \(parsed.rawValue).") }
            if ttl != nil { throw ValidationError("--ttl goes with set, not \(parsed.rawValue).") }
            if force { throw ValidationError("--force goes with set, not \(parsed.rawValue).") }
        }
        if parsed == .check, let label, DeviceLease.validLabel(label) == nil {
            throw ValidationError("--label must be 1 to 80 printable characters.")
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
            throw ValidationError("Unknown action '\(action)'. Use set, release, show or check.")
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
        if try parsedAction() == .check, let target {
            try Self.runCheck(target, label: label, environment: ProcessInfo.processInfo.environment, json: json, store: store, now: Date(), selfPID: getpid(), processes: .live) {
                print($0)
            }
            return
        }
        print(try Self.perform(
            try parsedAction(), target: target, label: label.flatMap(DeviceLease.validLabel), minutes: ttl ?? DeviceLease.defaultMinutes,
            force: force, json: json, store: store, now: Date(), pid: getppid(), owner: ProcessAncestry.owner(from: getppid(), in: .live)
        ))
    }

    /// The device's stable key; an emulator serial is asked for its AVD name.
    @MainActor
    static func resolve(_ id: String) async throws -> (platform: DevicePlatform, key: String) {
        if let key = StableDeviceKey.of(id: id) { return key }
        guard case .androidSerial = DeviceIDClassifier.classify(id) else {
            throw CLIError(errorDescription: "\(id) is not a device ID. Run `offsider devices` to find device IDs.", reason: .invalidDeviceID, hint: "offsider devices")
        }
        let route = try await DeviceRouter.route(id, logger: OffsiderLogger())
        try await route.backend.prepare()
        let booted = try await route.backend.requireBootedDevice(route.device)
        guard let key = StableDeviceKey.of(booted) else {
            throw CLIError(errorDescription: "Could not read the AVD name of \(id), which a lease is kept under. Lease it by its AVD name from `offsider devices`.", reason: .commandFailed, hint: "offsider devices")
        }
        return (.android, key)
    }

    static func perform(
        _ action: Action, target: (platform: DevicePlatform, key: String)?, label: String?, minutes: Int, force: Bool, json: Bool,
        store: DeviceLeaseStore, now: Date, pid: Int32, owner: ProcessIdentity? = nil
    ) throws -> String {
        switch action {
        case .set:
            guard let target, let label else { throw ValidationError(DeviceDefault.missingMessage) }
            let (existing, lease) = try store.set(platform: target.platform, key: target.key, now: now) { existing in
                try claim(existing, key: target.key, label: label, minutes: minutes, force: force, now: now, pid: pid, owner: owner)
            }
            let renewing = existing?.label == label
            if json { return report("set", target: target, lease: lease) }
            let verb = renewing ? "Renewed the lease on" : "Leased"
            let quoted = DeviceLeaseRules.shellQuoted(label)
            let leased = "\(verb) \(target.key) to '\(label)' until \(DeviceLeaseRules.clock(lease.expires))"
            guard let owner = lease.owner else {
                return "\(leased). Run `export OFFSIDER_LEASE=\(quoted)` so `offsider doctor` knows this session holds it."
            }
            return "\(leased) for this session (\(owner.name), pid \(owner.pid)); `offsider doctor` recognises it from any command this session runs. From another session, set OFFSIDER_LEASE=\(quoted)."
        case .release:
            guard let target else { throw ValidationError(DeviceDefault.missingMessage) }
            let removed = store.remove(platform: target.platform, key: target.key, now: now)
            if json { return report("release", target: target, lease: removed) }
            return removed.map { "Released the lease '\($0.label)' on \(target.key)." } ?? "\(target.key) was not leased."
        case .check:
            guard let target else { throw ValidationError(DeviceDefault.missingMessage) }
            let checked = check(target, label: label, json: json, store: store, now: now, selfPID: pid, processes: .live)
            if let failure = checked.failure { throw failure }
            return checked.output
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

    /// `check` as the command runs it: `--label` wins over OFFSIDER_LEASE, and under `--json` the one object is written before a failure that then adds only its exit code.
    static func runCheck(
        _ target: (platform: DevicePlatform, key: String), label: String?, environment: [String: String], json: Bool,
        store: DeviceLeaseStore, now: Date, selfPID: Int32, processes: ProcessTable, write: (String) -> Void
    ) throws {
        let sessionLabel = label.flatMap(DeviceLease.validLabel) ?? environment[DeviceLeaseRules.sessionVariable]
        let checked = check(target, label: sessionLabel, json: json, store: store, now: now, selfPID: selfPID, processes: processes)
        if !checked.output.isEmpty { write(checked.output) }
        guard let failure = checked.failure else { return }
        throw json ? ReportedFailure(underlying: failure, exitCode: failure.exitCode) : failure
    }

    /// `check`'s output and, when another session's lease is live, the `device_leased` failure; `label` is `--label` or OFFSIDER_LEASE.
    static func check(
        _ target: (platform: DevicePlatform, key: String), label: String?, json: Bool, store: DeviceLeaseStore, now: Date, selfPID: Int32, processes: ProcessTable
    ) -> (output: String, failure: CLIError?) {
        let lease = store.lease(platform: target.platform, key: target.key, now: now)
        let ownership = lease.map {
            DeviceLeaseRules.ownership(of: $0, sessionLabel: label, ancestors: ProcessAncestry.ancestors(of: selfPID, in: processes), processes: processes)
        }
        var failure: CLIError?
        var ownerEnded = false
        if let lease, let ownership, ownership != .thisSession {
            let span = "since \(DeviceLeaseRules.clock(lease.created)), until \(DeviceLeaseRules.clock(lease.expires))"
            let holder: String
            var next = "Choose another device from `offsider devices`, or pass --label (or set OFFSIDER_LEASE) if the lease is yours."
            switch ownership {
            case .ended(let owner):
                ownerEnded = true
                holder = "by a session that has ended (\(owner.name), pid \(owner.pid))"
                next = "If it was yours, `offsider lease set --device \(target.key) --label \(DeviceLeaseRules.shellQuoted(lease.label))` renews it; otherwise choose another device, or take it over with `lease set --force`."
            case .other(let owner):
                holder = "by another session (\(owner.name), pid \(owner.pid))"
            case .otherLabel:
                // The label decides before the session does, so the lease may still be this session's.
                holder = "under another label than '\((label ?? "").trimmingCharacters(in: .whitespaces))' (--label or OFFSIDER_LEASE)"
                next = "If the lease is yours, pass its label with --label or set OFFSIDER_LEASE to it; otherwise choose another device from `offsider devices`."
            default:
                holder = "by another session"
            }
            failure = CLIError(
                errorDescription: "\(target.key) is leased to '\(lease.label)' \(holder) \(span). \(next)",
                reason: .deviceLeased,
                hint: "offsider lease show --device \(target.key)"
            )
        }
        let mine = ownership == .thisSession
        if json {
            let payload = failure.map { ErrorPayload($0) }
            return (DeviceStateReport.leaseCheck(platform: target.platform, device: target.key, lease: lease, mine: mine, ownerEnded: ownerEnded, error: payload), failure)
        }
        guard let lease, mine else { return (failure == nil ? "\(target.key) is free." : "", failure) }
        return ("\(target.key) is this session's: '\(lease.label)' until \(DeviceLeaseRules.clock(lease.expires)).", nil)
    }

    /// The lease `set` writes over `existing`: refused while another label holds it unless `force`, and renewed for the same label by whichever session sets it now.
    static func claim(_ existing: DeviceLease?, key: String, label: String, minutes: Int, force: Bool, now: Date, pid: Int32, owner: ProcessIdentity? = nil) throws -> DeviceLease {
        if let existing, existing.label != label, !force {
            throw CLIError(
                errorDescription: "\(key) is leased to '\(existing.label)' since \(DeviceLeaseRules.clock(existing.created)), until \(DeviceLeaseRules.clock(existing.expires)). Choose another device, or pass --force if that lease is stale.",
                reason: .deviceLeased,
                hint: "offsider lease show --device \(key)"
            )
        }
        let created = existing.flatMap { $0.label == label ? $0.created : nil } ?? now
        return DeviceLease(label: label, created: created, expires: now.addingTimeInterval(TimeInterval(minutes * 60)), pid: pid, owner: owner)
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
