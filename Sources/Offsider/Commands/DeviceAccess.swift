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
        Offsider refuses every physical device until a person allows it here, from their own terminal: `allow` lets you \
        pick the device, the signing team (iPhone or iPad), the app and how long from menus, then asks for \
        Touch ID or your password. Each entry lapses (12 hours by default, at most 30 days unless `never`) and can pin the app \
        Offsider may drive on it. The list lives in ~/.config/offsider/allowed-devices.json, sealed in the login Keychain; an \
        edit made outside Offsider refuses every device until `allow` runs again. A managed preference (domain \
        com.mpalmes.offsider) can forbid devices the list allows, never the reverse. Without a subcommand, `status` runs.

        Examples:
          offsider device-access allow
          offsider device-access status
          offsider device-access remove --device PHONE_ID
          offsider device-access allow --device PHONE_ID --app com.example.app --expires 2h
        """,
        subcommands: [DeviceAccessAllow.self, DeviceAccessStatus.self, DeviceAccessRemove.self],
        defaultSubcommand: DeviceAccessStatus.self
    )
}

/// An app installed on a physical device, as the allow walkthrough offers it.
struct InstalledApp: Equatable, Sendable {
    let id: String
    let name: String?

    var label: String { name.map { "\($0) (\(id))" } ?? id }
}

/// Everything `device-access` reaches outside the process; tests bind their own.
struct DeviceAccessContext: Sendable {
    @TaskLocal static var current = DeviceAccessContext.live

    var store: @Sendable () -> DeviceAllowListStore?
    var seal: any DeviceAllowListSealing
    var managed: any ManagedPreferenceSource
    var now: @Sendable () -> Date
    /// Connected physical devices, as `list-devices` shows them, and the warnings the scan raised.
    var physicalDevices: @Sendable @MainActor () async throws -> (rows: [DeviceSummary], warnings: [String])
    /// Stops the device's runner and session broker; returns what stopped.
    var stopSessions: @Sendable @MainActor (String) async -> [String]
    /// Teams with a code-signing identity in the login Keychain.
    var signingTeams: @Sendable () -> [SigningTeam]
    /// The third-party apps on a device the person chose; one query to that device.
    var installedApps: @Sendable @MainActor (DeviceSummary) async throws -> [InstalledApp]
    /// A pseudo-terminal in tests; nil opens `/dev/tty`.
    var promptDescriptor: Int32?
    /// Where the receipt's expiry time is read.
    var timeZone: TimeZone = .current
    /// The app in front of the chosen device, offered first in the app step; nil when it cannot be read cheaply (an iPhone or iPad).
    var frontApp: @Sendable @MainActor (DeviceSummary) async -> String? = { _ in nil }
    /// offsider.login.json in this folder or above, whose app is offered first when present.
    var profile: @Sendable () -> LoginProfile? = { nil }
    /// Uninstalls the runner from an iPhone or iPad and deletes its builds and logs; returns the report's text.
    var cleanRunner: @Sendable @MainActor (String) async -> String = { _ in "" }
    /// A runner build or session this Mac holds for an iPhone or iPad, which `remove` offers to clean.
    var hasRunner: @Sendable (String) -> Bool = { _ in false }
    /// Whether `remove` may ask a question: standard input and output are both a terminal.
    var interactive: @Sendable () -> Bool = { false }

    static let live = DeviceAccessContext(
        store: { DevicePolicySources.store() },
        seal: KeychainDeviceAllowListSeal(),
        managed: LiveManagedPreferences(),
        now: { Date() },
        physicalDevices: {
            let backends = DeviceRouter.allBackends(logger: OffsiderLogger())
            var warnings: [String] = []
            let rows = try await ListDevices.collect(from: backends) { warnings.append($0) }
            return (rows.filter { $0.kind == .physical }, warnings)
        },
        stopSessions: { key in await DeviceAccessCommand.stopSessions(udid: key) },
        signingTeams: { SigningTeams.discover() },
        installedApps: { row in
            switch row.platform {
            case .ios:
                return try await IOSDeviceDirectory(host: .live()).installedApps(udid: row.id).map { InstalledApp(id: $0.bundleIdentifier, name: $0.name) }
            case .android:
                return try await AndroidBackend(log: { _, _ in }).thirdPartyPackages(serial: row.id).map { InstalledApp(id: $0, name: nil) }
            }
        },
        promptDescriptor: nil,
        frontApp: { row in
            guard row.platform == .android else { return nil }
            let top = try? await AndroidBackend(log: { _, _ in }).foreground(on: DeviceID(rawValue: row.id, platform: .android)).top
            return top?.split(separator: "/").first.map(String.init)
        },
        profile: { (try? LoginProfiles.load(project: nil, warn: { _ in })) ?? nil },
        cleanRunner: { udid in RunnerSessions.cleanText(await RunnerSessions.clean(udid: udid)) },
        hasRunner: { RunnerSessions.hasRecord(udid: $0) },
        interactive: { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }
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

    /// Stops the runner and session broker serving an iPhone or iPad, clearing its screen-sharing indicator, or a phone's warm helper.
    @MainActor
    static func stopSessions(udid: String) async -> [String] {
        if case .androidName = DeviceIDClassifier.classify(udid) {
            return await AndroidBackend.stopWarmHelpers(host: .cli(), serial: udid).isEmpty ? [] : ["warm helper"]
        }
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
        for record in runners {
            await runnerManager.stop(record)
            RunnerSessions.removeLog(udid: record.udid)
        }
        if !runners.isEmpty { stopped.append("runner") }
        return stopped
    }
}

struct DeviceAccessAllow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow",
        abstract: "Let Offsider drive a physical device: a person at this Mac picks it from menus in their own terminal and confirms with Touch ID."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The physical device's ID; without it, choose from the connected ones. OFFSIDER_DEVICE is never read.", valueName: "id"))
    var device: String?

    @Option(name: .customLong("app"), help: ArgumentHelp("An app Offsider may drive on it (repeatable); without it, choose from the apps installed on the device.", valueName: "id"))
    var apps: [String] = []

    @Option(name: .customLong("expires"), help: ArgumentHelp("How long the allowance lasts: <n>m, <n>h, <n>d (at most 30d) or never; without it, choose (12h recommended).", valueName: "time"))
    var expires: String?

    @Option(name: .customLong("team"), help: ArgumentHelp("For an iPhone or iPad: the Apple development team ID that signs Offsider's runner app on it; without it, choose from your Keychain's teams. OFFSIDER_IOS_TEAM_ID wins over it.", valueName: "id"))
    var team: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    func validate() throws {
        if let expires { _ = try DeviceAccessCommand.expiry(expires) }
        if let team, !DeviceAllowance.isTeamID(team) {
            throw ValidationError("--team takes a 10-character Apple team ID such as ABCDE12345; '\(team)' is not one.")
        }
        for app in apps where !DeviceAllowance.isAppID(app) {
            throw ValidationError("--app takes a bundle id or package name, such as com.example.app; '\(app)' is not one.")
        }
        guard Set(apps).count == apps.count else { throw ValidationError("--app names the same app twice.") }
    }

    /// What the person chose; `lifetime` nil means until removed.
    struct Choice {
        let row: DeviceSummary
        let key: String
        let team: String?
        let apps: [String]
        let lifetime: TimeInterval?
    }

    /// A person reading the menus may step away for Touch ID, so a key may be minutes coming.
    static let promptIdle: TimeInterval = 600

    /// A later device failed after earlier ones were saved: `output` holds their receipts, `failure` says what stopped and that they stay.
    struct Interrupted: Error {
        let output: String
        let failure: any Error
    }

    @MainActor
    func run() async throws {
        let output: String
        do {
            output = try await perform(context: DeviceAccessContext.current)
        } catch let interrupted as Interrupted {
            if isatty(STDOUT_FILENO) == 0 { print(interrupted.output) }
            throw interrupted.failure
        }
        // The receipt is already on the terminal; stdout gets it only when it goes elsewhere.
        if json || isatty(STDOUT_FILENO) == 0 { print(output) }
    }

    /// `Test iPhone stays allowed`, or `Test iPhone and Test Pixel stay allowed`.
    static func staysAllowed(_ names: [String]) -> String {
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names.joined()
        return "\(list) \(names.count > 1 ? "stay" : "stays") allowed."
    }

    /// The failure of a later device, reworded to say the earlier ones stay, with its own exit code and hint.
    static func interrupted(_ error: any Error, keeping names: [String]) -> ReportedFailure {
        let status = ErrorReporter.status(for: error)
        let payload = ErrorReporter.payload(for: error)
        let line = "\(reason(error)); \(staysAllowed(names))"
        return ReportedFailure(underlying: CLIError(errorDescription: line, reason: payload.reason, hint: payload.hint), exitCode: OffsiderExitCode(rawValue: status.exit) ?? .failure)
    }

    @MainActor
    func perform(context: DeviceAccessContext) async throws -> String {
        let instead = "Ask the user to run `offsider device-access allow` in their own terminal."
        try PersonPresence.requireTerminal(instead: instead)
        let store = try context.requireStore()
        let policy = context.policy()
        let pasted = try device.map(DeviceAccessCommand.physicalKey)
        var reports: [String] = []
        var savedNames: [String] = []
        var stopped: (any Error)?
        try await TerminalPrompt.runAsync(
            cancelled: AllowScreen.cancelled, instead: instead, descriptor: context.promptDescriptor, idle: Self.promptIdle, keeps: true
        ) { prompt in
            prompt.lines(AllowScreen.header(width: prompt.width, style: prompt.style))
            var (row, connected) = try await pickDevice(on: prompt, context: context, policy: policy, pasted: pasted)
            var allowedNow: Set<String> = []
            /// Where this device's lines begin, so a stop erases them and keeps every earlier receipt.
            var deviceStart = prompt.mark
            while true {
                let choice: Choice
                let entry: DeviceAllowance?
                let droppedTampered: Bool
                do {
                    choice = try await complete(row, on: prompt, context: context, policy: policy, pasted: pasted != nil, later: !savedNames.isEmpty)
                    (entry, droppedTampered) = try record(choice, store: store, context: context)
                } catch where !savedNames.isEmpty {
                    // Whatever stops a later device leaves the ones already saved, and says so.
                    prompt.rewind(to: deviceStart)
                    if error is PromptCancelled || error is PromptTimedOut {
                        prompt.lines([prompt.style.dim("Cancelled; " + Self.staysAllowed(savedNames))])
                    } else {
                        stopped = Self.interrupted(error, keeping: savedNames)
                    }
                    prompt.settle()
                    return
                }
                let until = AllowScreen.until(entry?.expires, now: context.now(), timeZone: context.timeZone)
                let name = AllowScreen.name(choice.row)
                if droppedTampered {
                    prompt.lines(TerminalUI.warning(Self.droppedTampered, width: prompt.width, style: prompt.style))
                }
                prompt.lines(AllowScreen.allowed(name: name, key: choice.key, until: until, apps: choice.apps, width: prompt.width, style: prompt.style))
                prompt.settle()
                reports.append(json
                    ? DeviceAccessReport.changeJSON(action: "allow", platform: choice.row.platform, key: choice.key, allowance: entry)
                    : AllowScreen.allowed(name: name, key: choice.key, until: until, apps: choice.apps, width: .max, style: .detect(isTerminal: false)).joined(separator: "\n"))
                allowedNow.insert(choice.key)
                savedNames.append(name)
                guard pasted == nil, !json else { return }
                let remaining = connected.filter { other in
                    let key = StableDeviceKey.of(other) ?? other.id
                    if allowedNow.contains(key) { return false }
                    if case .allowed = policy.decision(platform: other.platform, key: key) { return false }
                    return true
                }
                guard !remaining.isEmpty else { return }
                let start = prompt.mark
                prompt.lines([""])
                let rows = remaining.map { AllowScreen.deviceRow($0, key: StableDeviceKey.of($0) ?? $0.id, style: prompt.style) } + [MenuRow(.cancel, [AllowScreen.done])]
                let index: Int
                do {
                    index = try prompt.choose(prompt.style.mark(.another) + " " + AllowScreen.anotherQuestion, rows: rows, quit: "done", keepsChoice: false)
                } catch where error is PromptCancelled || error is PromptTimedOut {
                    index = remaining.count
                }
                prompt.rewind(to: start)
                guard index < remaining.count else { return }
                deviceStart = start
                row = remaining[index]
                connected = remaining
                prompt.lines(["", TerminalUI.receipt("Device", AllowScreen.name(row), style: prompt.style)])
            }
        }
        if let stopped { throw Interrupted(output: reports.joined(separator: "\n"), failure: stopped) }
        return reports.joined(separator: "\n")
    }

    /// Writes and seals the allowance; returns it, and whether an edit made outside Offsider cost the other entries.
    private func record(_ chosen: Choice, store: DeviceAllowListStore, context: DeviceAccessContext) throws -> (DeviceAllowance?, Bool) {
        let platform = chosen.row.platform
        let key = chosen.key
        let now = context.now()
        var droppedTampered = false
        let snapshot = try store.update({ current in
            var list = current.list
            if !context.seal.isIntact(current) {
                droppedTampered = true
                list = .empty
            }
            let entry = DeviceAllowance(
                platform: platform, key: key, name: PromptScreen.label(chosen.row.name, cap: 100),
                added: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                expires: chosen.lifetime.map { Date(timeIntervalSince1970: now.addingTimeInterval($0).timeIntervalSince1970.rounded(.down)) },
                apps: chosen.apps,
                team: chosen.team
            )
            return list.pruned(now: now).adding(entry)
        }, commit: { try context.seal.seal($0) })
        return (snapshot.list.entry(platform: platform, key: key), droppedTampered)
    }

    static let droppedTampered = "The list of allowed devices was changed outside Offsider, so the others were removed. Allow them again if you still want them."
    static let expiryOptions: [(mark: TerminalStyle.Mark, label: String, value: String?)] = [
        (.time, "2 hours", "2h"), (.time, "12 hours", "12h"), (.time, "24 hours", "24h"), (.time, "7 days", "7d"), (.keep, "Until removed", "never"),
        (.type, "Type a duration", nil),
    ]
    static let recommendedExpiry = 1

    /// The steps after the device is known: team, app, how long, the summary and Touch ID.
    @MainActor
    /// `later` marks a device after the first: there `--team` applies only to an iPhone or iPad, and is skipped for a phone.
    private func complete(_ row: DeviceSummary, on prompt: TerminalPrompt, context: DeviceAccessContext, policy: PhysicalDevicePolicy, pasted: Bool, later: Bool = false) async throws -> Choice {
        let key = StableDeviceKey.of(row) ?? row.id
        let team = row.platform == .ios || !later ? self.team : nil
        if team != nil, row.platform != .ios {
            throw CLIError(errorDescription: "--team is for an iPhone or iPad, and \(key) is an Android phone. Nothing was saved.", reason: .usage)
        }
        if case .refused(let refusal) = policy.decision(platform: row.platform, key: key), refusal.isManaged {
            throw CLIError.deviceNotAllowed(name: row.name, key: key, refusal: refusal)
        }
        for app in apps {
            if let problem = Self.appProblem(app, platform: row.platform, policy: policy) {
                throw CLIError(errorDescription: problem, reason: .appNotAllowed)
            }
        }
        let steps = stepNames(platform: row.platform)
        /// Runs the step with its `2/4` marker, then leaves one receipt line in place of everything it drew.
        func step<T>(_ name: String, _ body: (String?) async throws -> (value: T, shown: String)) async throws -> (value: T, shown: String) {
            let start = prompt.mark
            let marker = steps.firstIndex(of: name).map { "\($0 + 1)/\(steps.count)" }
            let (value, shown) = try await body(marker)
            prompt.rewind(to: start)
            prompt.lines([TerminalUI.receipt(name, shown, style: prompt.style)])
            return (value, shown)
        }
        var chosenTeam = team
        var shownTeam = team.map { "team \($0)" }
        if row.platform == .ios, team == nil {
            let picked = try await step("Team") { try await pickTeam(on: prompt, context: context, step: $0) }
            chosenTeam = picked.value
            shownTeam = picked.value == nil ? nil : picked.shown
        }
        var chosenApps = apps
        if apps.isEmpty {
            chosenApps = try await step("App") { try await pickApp(on: prompt, row: row, context: context, policy: policy, step: $0) }.value
        }
        let lifetime: TimeInterval?
        if let expires {
            lifetime = try DeviceAccessCommand.expiry(expires)
        } else {
            lifetime = try await step("How long") { try pickExpiry(on: prompt, step: $0) }.value
        }
        let name = AllowScreen.name(row)
        let start = prompt.mark
        prompt.lines([""] + AllowScreen.summary(row, apps: chosenApps, lifetime: lifetime, team: shownTeam, width: prompt.width, style: prompt.style))
        if pasted {
            let suffix = String(key.suffix(4))
            _ = try prompt.ask(prompt.style.mark(.digits) + " " + Self.suffixLabel) { answer in
                answer.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(suffix) == .orderedSame ? nil : Self.suffixMismatch
            }
        }
        prompt.lines([prompt.style.dim(AllowScreen.confirm)])
        try await PersonPresence.confirm(reason: "allow Offsider to drive \(name) (\(PromptScreen.visible(key)))")
        prompt.rewind(to: start)
        return Choice(row: row, key: key, team: chosenTeam, apps: chosenApps, lifetime: lifetime)
    }

    static let suffixLabel = "Last 4 of its ID: "
    static let suffixMismatch = "That is not how its ID ends. Check the ID you passed."

    /// The steps this run shows, in order; a flag given on the command line skips its step.
    func stepNames(platform: DevicePlatform) -> [String] {
        var names: [String] = []
        if device == nil { names.append("Device") }
        if platform == .ios, team == nil { names.append("Team") }
        if apps.isEmpty { names.append("App") }
        if expires == nil { names.append("How long") }
        return names
    }

    /// The chosen device and every USB-connected physical device the scan found.
    @MainActor
    private func pickDevice(
        on prompt: TerminalPrompt, context: DeviceAccessContext, policy: PhysicalDevicePolicy, pasted: (platform: DevicePlatform, key: String)?
    ) async throws -> (DeviceSummary, [DeviceSummary]) {
        func scan() async throws -> (rows: [DeviceSummary], warnings: [String]) {
            try await TerminalSpinner.run("Looking for devices", terminal: prompt.terminalDescriptor) { try await context.physicalDevices() }
        }
        if let pasted {
            let rows = try await scan().rows
            guard let match = rows.first(where: { $0.connection == "usb" && $0.platform == pasted.platform && StableDeviceKey.of($0) == pasted.key }) else {
                throw CLIError(
                    errorDescription: "\(pasted.key) is not a physical device connected over USB. Connect it with a cable, then run `offsider device-access allow` and choose it.",
                    reason: .deviceNotFound, hint: "offsider list-devices --physical"
                )
            }
            return (match, [])
        }
        while true {
            let start = prompt.mark
            let (rows, warnings) = try await scan()
            let usb = rows.filter { $0.connection == "usb" }
            let now = context.now()
            let allowances = usb.map { row -> DeviceAllowance? in
                if case .allowed(let entry) = policy.decision(platform: row.platform, key: StableDeviceKey.of(row) ?? row.id, now: now) { return entry }
                return nil
            }
            let wired = zip(usb, allowances).filter { $0.1 == nil }.map(\.0)
            let allowed = zip(usb, allowances).compactMap { row, entry in entry.map { (row, $0) } }
            let wireless = rows.filter { $0.connection == "network" }
            // The count is the longest run any connected device could take; an Android pick renumbers from step 2.
            let total = stepNames(platform: wired.contains { $0.platform == .ios } ? .ios : .android).count
            let allAllowed = wired.isEmpty && !allowed.isEmpty
            let menu = wired.map { AllowScreen.deviceRow($0, key: StableDeviceKey.of($0) ?? $0.id, style: prompt.style) }
                + allowed.map { AllowScreen.allowedRow($0.0, detail: AccessStatusScreen.detail($0.1, now: now, timeZone: context.timeZone, team: false, style: prompt.style), style: prompt.style) }
                + wireless.map { AllowScreen.deviceRow($0, key: StableDeviceKey.of($0) ?? $0.id, style: prompt.style) }
            do {
                let index = try prompt.choose(
                    AllowScreen.deviceQuestion, step: wired.isEmpty ? nil : "1/\(total)", rows: menu,
                    warning: usb.isEmpty ? AllowScreen.noDevice : nil,
                    notes: usb.isEmpty ? warnings : allAllowed ? [AllowScreen.allAllowed] : [],
                    commands: allAllowed ? [("Withdraw", AccessStatusScreen.removeCommand(allowed.count == 1 ? allowed[0].1.key : "<id>"))] : [],
                    rescan: true, keepsChoice: false
                )
                prompt.rewind(to: start)
                prompt.lines([TerminalUI.receipt("Device", AllowScreen.name(wired[index]), style: prompt.style)])
                return (wired[index], wired)
            } catch is PromptRefresh {
                prompt.rewind(to: start)
            }
        }
    }

    @MainActor
    private func pickTeam(on prompt: TerminalPrompt, context: DeviceAccessContext, step: String?) async throws -> (value: String?, shown: String) {
        let teams = try await TerminalSpinner.run("Reading your signing teams", terminal: prompt.terminalDescriptor) { context.signingTeams() }
        let problem = "A team ID is 10 letters and digits, such as ABCDE12345."
        guard !teams.isEmpty else {
            prompt.lines(TerminalUI.warning(AllowScreen.noTeam, width: prompt.width, style: prompt.style))
            let typed = try prompt.ask("  Team ID: ") { answer in
                let text = answer.trimmingCharacters(in: .whitespaces)
                return text.isEmpty || DeviceAllowance.isTeamID(text) ? nil : problem
            }.trimmingCharacters(in: .whitespaces).uppercased()
            return typed.isEmpty ? (nil, "none") : (typed, typed)
        }
        let rows = teams.map { MenuRow(.team, [PromptScreen.label($0.name), PromptScreen.label($0.id)], recommended: teams.count == 1) } + [MenuRow(.type, [AllowScreen.typeTeam])]
        let index = try prompt.choose(AllowScreen.teamQuestion, step: step, rows: rows, keepsChoice: false)
        if index < teams.count { return (teams[index].id, PromptScreen.label(teams[index].name)) }
        let typed = try prompt.ask("  Team ID: ") { DeviceAllowance.isTeamID($0.trimmingCharacters(in: .whitespaces)) ? nil : problem }
            .trimmingCharacters(in: .whitespaces).uppercased()
        return (typed, typed)
    }

    @MainActor
    private func pickApp(on prompt: TerminalPrompt, row: DeviceSummary, context: DeviceAccessContext, policy: PhysicalDevicePolicy, step: String?) async throws -> (value: [String], shown: String) {
        let listed: [InstalledApp]
        let front: String?
        do {
            (listed, front) = try await TerminalSpinner.run("Reading its apps", terminal: prompt.terminalDescriptor) {
                (try await context.installedApps(row), await context.frontApp(row))
            }
        } catch {
            prompt.lines(TerminalUI.warning("Could not read its apps (\(Self.reason(error))). Unlock it, or type an app ID.", width: prompt.width, style: prompt.style))
            return try typeApp(on: prompt, platform: row.platform, policy: policy, label: (step.map { "\($0) " } ?? "  ") + "App ID (Return for any app): ")
        }
        let menu = Self.appMenu(listed, platform: row.platform, policy: policy, profile: context.profile(), front: front)
        let index = try prompt.choose(AllowScreen.appQuestion, step: step, rows: menu.rows(), selected: menu.selected, keepsChoice: false)
        switch menu.choices[index] {
        case .app(let app): return ([app.id], PromptScreen.label(app.name ?? app.id))
        case .any: return ([], AllowScreen.apps([]))
        case .wholeDevice: return ([DeviceAllowance.wholeDevicePin], Self.wholeDeviceLabel.lowercased())
        case .type: return try typeApp(on: prompt, platform: row.platform, policy: policy, label: "  App ID: ")
        }
    }

    static let anyAppWarning = "every app on the phone, banking and messages included"
    static let wholeDeviceLabel = "Any app and all logs"
    static let wholeDeviceWarning = "the phone's whole log too"

    /// The app step's rows: the recommended app first (offsider.login.json's, else the one in front), the other apps, then the broad choices, dim, and typing.
    struct AppMenu: Equatable {
        enum Choice: Equatable {
            case app(InstalledApp)
            case any
            case wholeDevice
            case type
        }

        let choices: [Choice]
        let recommended: Int?

        /// The recommended app, else the first app, else typing; never a broad choice.
        var selected: Int {
            recommended ?? choices.firstIndex { if case .app = $0 { return true } else { return false } } ?? choices.count - 1
        }

        func rows() -> [MenuRow] {
            choices.enumerated().map { index, choice in
                switch choice {
                case .app(let app): return MenuRow(.app, (app.name.map { [PromptScreen.label($0)] } ?? []) + [PromptScreen.label(app.id)], recommended: index == recommended)
                case .any: return MenuRow(.anyApp, [AllowScreen.anyApp, DeviceAccessAllow.anyAppWarning])
                case .wholeDevice: return MenuRow(.anyApp, [DeviceAccessAllow.wholeDeviceLabel, DeviceAccessAllow.wholeDeviceWarning])
                case .type: return MenuRow(.type, [AllowScreen.typeApp])
                }
            }
        }
    }

    static func appMenu(_ listed: [InstalledApp], platform: DevicePlatform, policy: PhysicalDevicePolicy, profile: LoginProfile?, front: String?) -> AppMenu {
        let offered = listed
            .filter { DeviceAllowance.isAppID($0.id) && appProblem($0.id, platform: platform, policy: policy) == nil }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        let profileApp = platform == .ios ? profile?.bundleID : profile?.package
        let pick = [profileApp, front].compactMap { $0 }.first { id in offered.contains { $0.id == id } }
        let first = offered.filter { $0.id == pick }
        var choices: [AppMenu.Choice] = (first + offered.filter { $0.id != pick }).map { .app($0) }
        choices.append(.any)
        if platform == .android { choices.append(.wholeDevice) }
        choices.append(.type)
        return AppMenu(choices: choices, recommended: first.isEmpty ? nil : 0)
    }

    @MainActor
    private func typeApp(on prompt: TerminalPrompt, platform: DevicePlatform, policy: PhysicalDevicePolicy, label: String) throws -> (value: [String], shown: String) {
        let answer = try prompt.ask(label) { answer in
            let text = answer.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return nil }
            guard DeviceAllowance.isAppID(text) else { return "Type an app ID, such as com.example.app." }
            return Self.appProblem(text, platform: platform, policy: policy)
        }.trimmingCharacters(in: .whitespaces)
        return answer.isEmpty ? ([], AllowScreen.apps([])) : ([answer], answer)
    }

    @MainActor
    private func pickExpiry(on prompt: TerminalPrompt, step: String?) throws -> (value: TimeInterval?, shown: String) {
        let rows = Self.expiryOptions.enumerated().map { MenuRow($1.mark, [$1.label], recommended: $0 == Self.recommendedExpiry) }
        let index = try prompt.choose(AllowScreen.expiryQuestion, step: step, rows: rows, selected: Self.recommendedExpiry, keepsChoice: false)
        if let value = Self.expiryOptions[index].value {
            let lifetime = try DeviceAccessCommand.expiry(value)
            return (lifetime, AllowScreen.duration(lifetime))
        }
        let typed = try prompt.ask("  How long (like 45m, 2h, 7d or never): ") { answer in
            do {
                _ = try DeviceAccessCommand.expiry(answer)
                return nil
            } catch let error as ValidationError {
                return error.message.replacingOccurrences(of: "--expires", with: "A duration")
            } catch {
                return "\(error)"
            }
        }
        let lifetime = try DeviceAccessCommand.expiry(typed)
        return (lifetime, AllowScreen.duration(lifetime))
    }

    /// Why Offsider may not drive `app` on the device, or nil.
    static func appProblem(_ app: String, platform: DevicePlatform, policy: PhysicalDevicePolicy) -> String? {
        if let why = SystemAppDenyList.refusal(app, platform: platform) {
            return "\(why)."
        }
        if let ceiling = policy.managed.allowedBundleIDs, !ceiling.contains(app) {
            return "Managed policy on this Mac does not list \(app), and the allow-list cannot override it."
        }
        return nil
    }

    static func reason(_ error: any Error) -> String {
        let text = (error as? any OffsiderFailure)?.failureMessage ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.hasSuffix(".") ? String(line.dropLast()) : line
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
        let screen = isatty(STDOUT_FILENO) != 0 ? (style: TerminalStyle.detect(isTerminal: true), width: PromptScreen.width(columns: Self.columns())) : nil
        let (output, refusal) = try perform(context: context, screen: screen)
        print(output, terminator: "")
        if let refusal { throw refusal }
    }

    private static func columns() -> Int? {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : nil
    }

    /// The report, and the error to exit with when `--device` is not allowed. `screen` draws the styled list for a terminal,
    /// unless `--json` or `--device` asks for the text agents parse.
    func perform(context: DeviceAccessContext, screen: (style: TerminalStyle, width: Int)? = nil) throws -> (String, CLIError?) {
        let policy = context.policy()
        let now = context.now()
        if let screen, !json, device == nil {
            return (AccessStatusScreen.lines(policy, now: now, timeZone: context.timeZone, width: screen.width, style: screen.style).joined(separator: "\n") + "\n", nil)
        }
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
        abstract: "Withdraw a physical device's allowance and stop its runner and session broker; on a terminal, offer to uninstall the runner. Needs no terminal."
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
        let hadRunner = target.platform == .ios && context.hasRunner(target.key)
        let stopped = await context.stopSessions(target.key)
        if json { return DeviceAccessReport.changeJSON(action: "remove", platform: target.platform, key: target.key, allowance: removed, stopped: stopped) }
        var text = removed.map { "Removed \($0.name) (\(target.key)) from the allow-list; Offsider will not drive it again until a person allows it." }
            ?? "\(target.key) was not on the allow-list."
        if tampered, existing != nil { text += " The allow-list had been changed outside Offsider, so every entry was dropped." }
        if !stopped.isEmpty { text += " Stopped its \(stopped.joined(separator: " and "))." }
        guard hadRunner else { return text }
        let clean = Self.cleanCommand(target.key)
        guard context.interactive() else { return text + " Uninstall Offsider's runner from it with `\(clean)`." }
        let answer = try TerminalPrompt.run(cancelled: "Kept the runner; `\(clean)` removes it later.", descriptor: context.promptDescriptor, keeps: true) { prompt in
            prompt.lines([text])
            return try prompt.ask(Self.cleanQuestion) { Self.yesOrNo($0) == nil ? "Type y or n." : nil }
        }
        guard Self.yesOrNo(answer) == true else { return "Kept the runner; `\(clean)` removes it later." }
        return await context.cleanRunner(target.key).trimmingCharacters(in: .newlines)
    }

    static let cleanQuestion = "Also uninstall its runner? (Y/n) "

    static func cleanCommand(_ udid: String) -> String {
        "offsider session stop --device \(udid) --clean"
    }

    /// Return or y means yes, n means no; nil for anything else.
    static func yesOrNo(_ answer: String) -> Bool? {
        switch answer.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "y", "yes": return true
        case "n", "no": return false
        default: return nil
        }
    }
}
