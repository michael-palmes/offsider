import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice

struct DeviceAccessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device-access",
        abstract: "Allow, check or withdraw Offsider's access to a physical iPhone, iPad or Android phone.",
        discussion: """
        Offsider refuses every physical device until a person allows it here, from their own terminal: `allow` shows the device, \
        asks for the last four characters of its ID, then for Touch ID or your password. Each entry lapses (12 hours by default, \
        at most 30 days unless `never`) and can pin the apps Offsider may drive on it. The list lives in \
        ~/.config/offsider/allowed-devices.json, sealed in the login Keychain; an edit made outside Offsider refuses every device \
        until `allow` runs again. A managed preference (domain com.mpalmes.offsider) can forbid devices the list allows, never the reverse.

        Examples:
          offsider device-access allow --device PHONE_ID --app com.example.app
          offsider device-access status --device PHONE_ID --json
          offsider device-access remove --device PHONE_ID
        """,
        subcommands: [DeviceAccessAllow.self, DeviceAccessStatus.self, DeviceAccessRemove.self]
    )
}

/// Everything `device-access` reaches outside the process; tests bind their own.
struct DeviceAccessContext: Sendable {
    @TaskLocal static var current = DeviceAccessContext.live

    var store: @Sendable () -> DeviceAllowListStore?
    var seal: any DeviceAllowListSealing
    var managed: any ManagedPreferenceSource
    var now: @Sendable () -> Date
    /// Connected physical devices, as `list-devices` shows them.
    var physicalDevices: @Sendable @MainActor () async throws -> [DeviceSummary]
    /// Stops the device's runner and session broker; returns what stopped.
    var stopSessions: @Sendable @MainActor (String) async -> [String]
    /// A pseudo-terminal in tests; nil opens `/dev/tty`.
    var promptDescriptor: Int32?

    static let live = DeviceAccessContext(
        store: { DevicePolicySources.store() },
        seal: KeychainDeviceAllowListSeal(),
        managed: LiveManagedPreferences(),
        now: { Date() },
        physicalDevices: {
            let backends = DeviceRouter.allBackends(logger: OffsiderLogger())
            let rows = try await ListDevices.collect(from: backends) { warning in
                FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8))
            }
            return rows.filter { $0.kind == .physical }
        },
        stopSessions: { key in await DeviceAccessCommand.stopSessions(udid: key) },
        promptDescriptor: nil
    )

    func policy() -> PhysicalDevicePolicy {
        DevicePolicyGate.read(store: store(), seal: seal, managed: managed)
    }

    func requireStore() throws -> DeviceAllowListStore {
        guard let store = store() else {
            throw CLIError(errorDescription: "This account has no home folder in the password database, so Offsider has nowhere to keep the device allow-list.", reason: .commandFailed)
        }
        return store
    }
}

extension DeviceAccessCommand {
    static let defaultExpiry = "12h"
    static let longestExpiry: TimeInterval = 30 * 86_400

    /// `<n>m`, `<n>h`, `<n>d` (at most 30 days) or `never`; nil for never.
    static func expiry(_ text: String) throws -> TimeInterval? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "never" { return nil }
        let units: [Character: TimeInterval] = ["m": 60, "h": 3_600, "d": 86_400]
        guard let unit = value.last, let scale = units[unit], let count = Int(value.dropLast()), count > 0 else {
            throw ValidationError("--expires takes <n>m, <n>h, <n>d or never, such as 12h.")
        }
        let seconds = TimeInterval(count) * scale
        guard seconds <= longestExpiry else { throw ValidationError("--expires is at most 30d; pass never for an entry that stays until removed.") }
        return seconds
    }

    /// The stable key for a physical device ID; refuses simulators, emulators and anything else.
    static func physicalKey(_ raw: String) throws -> (platform: DevicePlatform, key: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(id) {
        case .iosDevice(let udid): return (.ios, udid.uppercased())
        case .androidName(let serial): return (.android, serial)
        case .iosSimulator, .androidSerial:
            throw CLIError(errorDescription: "\(id) is a simulator or emulator, which Offsider drives without an allowance. device-access is for physical devices.", reason: .usage)
        case .androidNetworkSerial(let serial):
            throw AndroidError.networkDevice(serial)
        case .empty, .unrecognised:
            throw CLIError(errorDescription: "\(id.isEmpty ? "Device ID cannot be empty" : "\(id) is not a device ID Offsider recognises"). Run `offsider list-devices --physical` to find it.", reason: .invalidDeviceID, hint: "offsider list-devices --physical")
        }
    }

    /// Stops the runner and session broker serving an iPhone or iPad, clearing its screen-sharing indicator.
    @MainActor
    static func stopSessions(udid: String) async -> [String] {
        var stopped: [String] = []
        let brokers = DeviceSessions.records(device: udid)
        let manager = DeviceSessions.manager()
        for record in brokers { await manager.stop(record) }
        if !brokers.isEmpty { stopped.append("session broker") }
        let runners = RunnerSessions.records(device: udid)
        let runnerManager = RunnerSessionManager(
            store: RunnerSessions.store, builder: UnusedRunnerBuilder(), environment: ProcessInfo.processInfo.environment,
            developerDirectory: nil, log: { _, _ in }
        )
        for record in runners { await runnerManager.stop(record) }
        if !runners.isEmpty { stopped.append("runner") }
        return stopped
    }
}

struct DeviceAccessAllow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow",
        abstract: "Let Offsider drive a physical device: a person at this Mac confirms it in their own terminal."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The physical device's ID; without it, choose from the connected ones. OFFSIDER_DEVICE is never read.", valueName: "id"))
    var device: String?

    @Option(name: .customLong("app"), help: ArgumentHelp("An app Offsider may drive on it (repeatable); without any, every app that is not a browser or system app.", valueName: "id"))
    var apps: [String] = []

    @Option(name: .customLong("expires"), help: ArgumentHelp("How long the allowance lasts: <n>m, <n>h, <n>d (at most 30d) or never.", valueName: "time"))
    var expires = DeviceAccessCommand.defaultExpiry

    @Option(name: .customLong("team"), help: ArgumentHelp("For an iPhone or iPad: the Apple development team ID that signs Offsider's runner app on it; OFFSIDER_IOS_TEAM_ID wins over it.", valueName: "id"))
    var team: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    func validate() throws {
        _ = try DeviceAccessCommand.expiry(expires)
        if let team, !DeviceAllowance.isTeamID(team) {
            throw ValidationError("--team takes a 10-character Apple team ID such as ABCDE12345; '\(team)' is not one.")
        }
        for app in apps where !DeviceAllowance.isAppID(app) {
            throw ValidationError("--app takes a bundle id or package name, such as com.example.app; '\(app)' is not one.")
        }
        guard Set(apps).count == apps.count else { throw ValidationError("--app names the same app twice.") }
    }

    @MainActor
    func run() async throws {
        print(try await perform(context: DeviceAccessContext.current))
    }

    @MainActor
    func perform(context: DeviceAccessContext) async throws -> String {
        let instead = "Ask the user to run `offsider device-access allow\(device.map { " --device \($0.trimmingCharacters(in: .whitespaces))" } ?? "")` in their own terminal."
        try PersonPresence.requireTerminal(instead: instead)
        let lifetime = try DeviceAccessCommand.expiry(expires)
        let rows = try await context.physicalDevices().filter { $0.connection == "usb" }
        let store = try context.requireStore()
        let policy = context.policy()
        let chosen = try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, instead: instead, descriptor: context.promptDescriptor) { prompt in
            try confirm(on: prompt, rows: rows, policy: policy)
        }
        let platform = chosen.platform
        let key = chosen.key
        try await PersonPresence.confirm(reason: "allow Offsider to drive \(chosen.name) (\(key))")
        let now = context.now()
        var droppedTampered = false
        let snapshot = try store.update({ current in
            var list = current.list
            if !context.seal.isIntact(current) {
                droppedTampered = true
                list = .empty
            }
            let entry = DeviceAllowance(
                platform: platform, key: key, name: chosen.name,
                added: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                expires: lifetime.map { Date(timeIntervalSince1970: now.addingTimeInterval($0).timeIntervalSince1970.rounded(.down)) },
                apps: apps,
                team: team
            )
            return list.pruned(now: now).adding(entry)
        }, commit: { try context.seal.seal($0) })
        let entry = snapshot.list.entry(platform: platform, key: key)
        if droppedTampered {
            FileHandle.standardError.write(Data("The allow-list had been changed outside Offsider, so its other entries were dropped; allow those devices again if you still want them.\n".utf8))
        }
        if json { return DeviceAccessReport.changeJSON(action: "allow", platform: platform, key: key, allowance: entry) }
        let until = entry?.expires.map { "until \(ProcessStamp.timestamp($0))" } ?? "until you remove it"
        let pinned = apps.isEmpty ? "" : " for \(apps.joined(separator: ", "))"
        let signer = team.map { " Team \($0) signs Offsider's runner app on it." } ?? ""
        return "Allowed \(chosen.name) (\(key)) \(until)\(pinned).\(signer) Commands reach it only with --device \(key); `offsider device-access remove --device \(key)` withdraws it."
    }

    /// Picks the device, shows what is being allowed, and asks for the last four characters of its ID.
    @MainActor
    private func confirm(on prompt: TerminalPrompt, rows: [DeviceSummary], policy: PhysicalDevicePolicy) throws -> (platform: DevicePlatform, key: String, name: String) {
        let row: DeviceSummary
        if let device {
            let target = try DeviceAccessCommand.physicalKey(device)
            guard let match = rows.first(where: { $0.platform == target.platform && StableDeviceKey.of($0) == target.key }) else {
                throw CLIError(
                    errorDescription: "\(target.key) is not a physical device connected over USB. Connect it with a cable, then run `offsider list-devices --physical` to check its ID.",
                    reason: .deviceNotFound, hint: "offsider list-devices --physical"
                )
            }
            row = match
        } else {
            guard !rows.isEmpty else {
                throw CLIError(errorDescription: "No physical device is connected over USB. Connect one with a cable, then try again.", reason: .deviceNotFound, hint: "offsider list-devices --physical")
            }
            let options = rows.map { "\(DeviceName.display($0.id, label: $0.name))  \($0.platform.rawValue)" }
            row = rows[try prompt.choose("Which device may Offsider drive?", options: options)]
        }
        let key = StableDeviceKey.of(row) ?? row.id
        if team != nil, row.platform != .ios {
            throw CLIError(errorDescription: "--team is for an iPhone or iPad, and \(key) is an Android phone. Nothing was saved.", reason: .usage)
        }
        if case .refused(let refusal) = policy.decision(platform: row.platform, key: key), refusal.isManaged {
            throw CLIError.deviceNotAllowed(name: row.name, key: key, refusal: refusal)
        }
        for app in apps {
            if let why = SystemAppDenyList.refusal(app, platform: row.platform) {
                throw CLIError(errorDescription: "\(app) is \(why); Offsider never drives it on a physical device.", reason: .appNotAllowed)
            }
            if let ceiling = policy.managed.allowedBundleIDs, !ceiling.contains(app) {
                throw CLIError(errorDescription: "Managed policy on this Mac does not list \(app), and the allow-list cannot override it.", reason: .appNotAllowed)
            }
        }
        let lifetime = (try? DeviceAccessCommand.expiry(expires)) ?? nil
        prompt.lines([
            prompt.style.bold("Allow Offsider to drive this device?"),
            "  Platform  \(row.platform == .ios ? "iOS" : "Android")",
            "  Name      \(row.name)",
            "  Model     \(row.deviceType ?? "unknown")",
            "  ID        \(key)",
            "  Apps      \(apps.isEmpty ? "any app that is not a browser or system app" : apps.joined(separator: ", "))",
            "  Expires   \(lifetime.map { "in \(Self.duration($0))" } ?? "never (until removed)")",
        ] + (team.map { ["  Team      \($0) signs Offsider's runner app on it"] } ?? []) + [
            "Anything that can run commands as you can then drive it until it expires.",
        ])
        let suffix = String(key.suffix(4))
        _ = try prompt.ask("Type the last four characters of its ID to allow it: ") { answer in
            answer.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(suffix) == .orderedSame ? nil : "That does not match the end of \(key)."
        }
        return (row.platform, key, row.name)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(seconds / 86_400)) days" }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600)) hours" }
        return "\(Int(seconds / 60)) minutes"
    }
}

struct DeviceAccessStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the allow-list and managed policy; with --device, exit 7 (device_not_allowed) unless that device is allowed."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("Check only this device.", valueName: "id"))
    var device: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    func run() async throws {
        let context = DeviceAccessContext.current
        let (output, refusal) = try perform(context: context)
        print(output, terminator: "")
        if let refusal { throw refusal }
    }

    /// The report, and the error to exit with when `--device` is not allowed.
    func perform(context: DeviceAccessContext) throws -> (String, CLIError?) {
        let policy = context.policy()
        let now = context.now()
        let target = try device.map(DeviceAccessCommand.physicalKey)
        let path = context.store()?.path ?? "~/.config/offsider/\(DeviceAllowListStore.fileName)"
        let output = json
            ? policy.statusJSON(now: now, only: target)
            : DeviceAccessReport.statusText(policy, now: now, path: path)
        guard let target else { return (output, nil) }
        switch policy.decision(platform: target.platform, key: target.key, now: now) {
        case .allowed(let entry):
            let extra = json ? "" : "\(target.key) is allowed\(entry.expires.map { " until \(ProcessStamp.timestamp($0))" } ?? "").\n"
            return (output + extra, nil)
        case .refused(let refusal):
            let entry = policy.list.entry(platform: target.platform, key: target.key)
            return (output, CLIError.deviceNotAllowed(name: entry?.name, key: target.key, refusal: refusal))
        }
    }
}

struct DeviceAccessRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Withdraw a physical device's allowance and stop its runner and session broker. Needs no terminal."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The physical device's ID. OFFSIDER_DEVICE is never read.", valueName: "id"))
    var device: String

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @MainActor
    func run() async throws {
        print(try await perform(context: DeviceAccessContext.current))
    }

    @MainActor
    func perform(context: DeviceAccessContext) async throws -> String {
        let target = try DeviceAccessCommand.physicalKey(device)
        let store = try context.requireStore()
        let existing = try? store.load()
        let listed = existing.map { $0.list.entry(platform: target.platform, key: target.key) != nil } ?? false
        let tampered = existing.map { !context.seal.isIntact($0) } ?? true
        var removed: DeviceAllowance?
        if listed || tampered {
            try store.update({ current in
                removed = current.list.entry(platform: target.platform, key: target.key)
                let base = context.seal.isIntact(current) ? current.list : .empty
                return base.pruned(now: context.now()).removing(platform: target.platform, key: target.key)
            }, commit: { try context.seal.seal($0) })
        }
        let stopped = target.platform == .ios ? await context.stopSessions(target.key) : []
        if json { return DeviceAccessReport.changeJSON(action: "remove", platform: target.platform, key: target.key, allowance: removed, stopped: stopped) }
        var text = removed.map { "Removed \($0.name) (\(target.key)) from the allow-list; Offsider will not drive it again until a person allows it." }
            ?? "\(target.key) was not on the allow-list."
        if tampered, existing != nil { text += " The allow-list had been changed outside Offsider, so every entry was dropped." }
        if !stopped.isEmpty { text += " Stopped its \(stopped.joined(separator: " and "))." }
        return text
    }
}
