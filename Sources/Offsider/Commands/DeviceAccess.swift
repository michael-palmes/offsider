import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice

/// An app installed on a physical device, as the allow walkthrough offers it.
struct InstalledApp: Equatable, Sendable {
    let id: String
    let name: String?

    var label: String { name.map { "\($0) (\(id))" } ?? id }
}

/// Everything `devices add`, `remove` and `status` reach outside the process; tests bind their own.
struct DeviceAccessContext: Sendable {
    @TaskLocal static var current = DeviceAccessContext.live

    var store: @Sendable () -> DeviceAllowListStore?
    var seal: any DeviceAllowListSealing
    var managed: any ManagedPreferenceSource
    var now: @Sendable () -> Date
    /// Connected physical devices, as `devices` shows them, and the warnings the scan raised.
    var physicalDevices: @Sendable @MainActor () async throws -> (rows: [DeviceSummary], warnings: [String])
    /// Stops the device's runner and session broker; returns what stopped and what it left.
    var stopSessions: @Sendable @MainActor (String) async -> DeviceAccess.StoppedSessions
    /// Takes the reverses Offsider recorded off a phone, except on the ports given; a narrower allowance holds from now.
    var withdrawMetroPorts: @Sendable @MainActor (_ key: String, _ keeping: [Int]) async -> MetroReverseOutcome = { _, _ in MetroReverseOutcome() }
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
    /// Uninstalls the runner from an iPhone or iPad and deletes its builds and logs.
    var cleanRunner: @Sendable @MainActor (String) async -> RunnerCleanupReport = { RunnerCleanupReport(udid: $0) }
    /// A runner build or session this Mac holds for an iPhone or iPad, which `remove` offers to clean.
    var hasRunner: @Sendable (String) -> Bool = { _ in false }
    /// Whether `remove` may ask a question: a person, with standard input and output both a terminal.
    var interactive: @Sendable () -> Bool = { false }
    /// Registers an allowed iPhone or iPad with its team, builds its runner and starts it; true once proved. Android has nothing to prove here.
    var prepare: @Sendable @MainActor (DeviceSummary) async throws -> Bool = { _ in false }
    /// Where the end of `add` saves a login; nil skips the question.
    var credentials: (any LoginCredentialStoring)? = nil
    /// How long a prompt waits for a key.
    var promptIdle: TimeInterval = DeviceAccessAllow.promptIdle

    static let live = DeviceAccessContext(
        store: { DevicePolicySources.store() },
        seal: KeychainDeviceAllowListSeal(),
        managed: LiveManagedPreferences(),
        now: { Date() },
        physicalDevices: {
            let backends = DeviceRouter.allBackends(logger: OffsiderLogger())
            var warnings: [String] = []
            let rows = try await ListDevices.collect(from: backends) { warnings.append("Skipped \($0.what): \($0.message)") }
            return (rows.filter { $0.kind == .physical }, warnings)
        },
        stopSessions: { key in await DeviceAccess.stopSessions(udid: key) },
        withdrawMetroPorts: { key, keeping in await AndroidBackend.removeMetroReverses(host: .cli(), serial: key, keeping: keeping) },
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
        cleanRunner: { udid in await RunnerSessions.clean(udid: udid) },
        hasRunner: { RunnerSessions.hasRecord(udid: $0) },
        interactive: { DevicePicker.prompts(terminals: isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0) },
        prepare: { row in try await DeviceAccessContext.livePrepare(row) },
        credentials: KeychainLoginCredentialStore()
    )

    /// The allowance was written after this process read its policy, so the route reads the list again.
    @MainActor
    static func livePrepare(_ row: DeviceSummary) async throws -> Bool {
        guard row.platform == .ios else { return false }
        let policy = DevicePolicyGate.read(store: DevicePolicySources.store(), seal: KeychainDeviceAllowListSeal(), managed: LiveManagedPreferences())
        let udid = StableDeviceKey.of(row) ?? row.id
        return try await DevicePolicyGate.$current.withValue(.fixed(policy)) {
            let route = try await DeviceRouter.route(udid, logger: OffsiderLogger())
            guard let backend = route.backend as? IOSDeviceBackend else { return false }
            _ = try await XcodeRunnerBuilder.$confirmNewPrefix.withValue(RunnerBuildCommand.confirmPrefix(udid: udid)) {
                try await backend.buildRunner(for: route.device, registerDevice: route.allowance?.team != nil)
            }
            try await backend.checkRunner(route.device)
            return true
        }
    }

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

/// What `devices add`, `remove` and `status` share.
enum DeviceAccess {}

extension DeviceAccess {
    /// What a one-app allowance lasts when no one chose; any app on a phone in use is recommended less, a test device stays until removed.
    static let oneAppExpiry = "7d"
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

    /// `8081`, `8081 8742` or `8081,8742`: ports Metro may listen on, ascending; empty for none.
    static func metroPorts(_ text: String) throws -> [Int] {
        let words = text.split { $0 == "," || $0 == " " }.map(String.init)
        guard words.count <= DeviceAllowance.maximumMetroPorts else {
            throw ValidationError("At most \(DeviceAllowance.maximumMetroPorts) Metro ports.")
        }
        let ports = try words.map { word -> Int in
            guard let port = Int(word) else { throw ValidationError("Type ports as numbers, such as 8081 8742; '\(word)' is not one.") }
            if let problem = MetroReverse.refusal(port: port) { throw ValidationError(problem) }
            return port
        }
        guard Set(ports).count == ports.count else { throw ValidationError("A Metro port is named twice.") }
        return ports.sorted()
    }

    /// The stable key for a physical device ID; refuses simulators, emulators and anything else.
    static func physicalKey(_ raw: String) throws -> (platform: DevicePlatform, key: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(id) {
        case .iosDevice(let udid): return (.ios, udid.uppercased())
        case .androidName(let serial): return (.android, serial)
        case .iosSimulator, .androidSerial:
            throw CLIError(errorDescription: "\(id) is a simulator or emulator, which Offsider drives without being added. Only phones and tablets are added.", reason: .usage)
        case .androidNetworkSerial(let serial):
            throw AndroidError.networkDevice(serial)
        case .empty, .unrecognised:
            throw CLIError(errorDescription: "\(id.isEmpty ? "Device ID cannot be empty" : "\(id) is not a device ID Offsider recognises"). Run `offsider devices --physical` to find it.", reason: .invalidDeviceID, hint: "offsider devices --physical")
        }
    }

    /// What stopping a device's sessions did, and what it left on the phone.
    struct StoppedSessions: Equatable {
        var stopped: [String] = []
        var left: [DeviceSessionRow.Left] = []
    }

    /// Stops the runner and session broker serving an iPhone or iPad, clearing its screen-sharing indicator, or a phone's warm helper, the adb reverses Offsider set and its posture override.
    @MainActor
    static func stopSessions(udid: String) async -> StoppedSessions {
        if case .androidName = DeviceIDClassifier.classify(udid) {
            let helper = await AndroidBackend.stopWarmHelpers(host: .cli(), serial: udid).isEmpty ? [] : ["warm helper"]
            let reverses = await AndroidBackend.removeMetroReverses(host: .cli(), serial: udid)
            let postures = await AndroidBackend.resetRecordedPostures(host: .cli(), serial: udid)
            let airplanes = await AndroidBackend.resetRecordedAirplaneModes(host: .cli(), serial: udid)
            return StoppedSessions(
                stopped: helper + reverses.removed.flatMap(\.ports).map(MetroReverse.label) + (postures.reset.isEmpty ? [] : ["posture override"]) + (airplanes.reset.isEmpty ? [] : ["airplane mode"]),
                left: DeviceSessionRow.left(reverses: reverses.failed, postures: postures, airplanes: airplanes)
            )
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
        return StoppedSessions(stopped: stopped)
    }
}

struct DeviceAccessAllow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Let agents drive a phone or tablet: a person at this Mac picks it from menus in their own terminal and confirms with Touch ID."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The physical device's ID; without it, choose from the connected ones. OFFSIDER_DEVICE is never read.", valueName: "id"))
    var device: String?

    @Option(name: .customLong("app"), help: ArgumentHelp("An app Offsider may drive on it (repeatable); without it, choose from the apps installed on the device.", valueName: "id"))
    var apps: [String] = []

    @Option(name: .customLong("expires"), help: ArgumentHelp("How long the allowance lasts: <n>m, <n>h, <n>d (at most 30d) or never; without it, a one-app choice recommends 7d, any app 12h, and a test device stays until removed.", valueName: "time"))
    var expires: String?

    @Option(name: .customLong("team"), help: ArgumentHelp("For an iPhone or iPad: the Apple development team ID that signs Offsider's runner app on it; without it, choose from your Keychain's teams. OFFSIDER_IOS_TEAM_ID wins over it.", valueName: "id"))
    var team: String?

    @Option(name: .customLong("metro-port"), help: ArgumentHelp("For an Android phone: a port of Metro on this Mac that rn open may map to it with adb reverse (repeatable), or none; without it, choose. Every app on the phone can reach Metro while the reverse is set.", valueName: "port|none"))
    var metroPortArguments: [String] = []

    @Flag(name: .customLong("test-device"), help: "Let agents drive the whole device: every app, system alerts and Settings, until removed. Only for a device kept for testing, with nothing personal on it.")
    var testDevice = false

    @Flag(name: .customLong("plan"), help: "Print each connected phone with the complete command that adds it. Changes nothing, reaches no phone and needs no terminal, so an agent can read it.")
    var plan = false

    /// `--metro-port` as ports, empty for `none`; nil when it was not given, so the step asks.
    var metroPorts: [Int]? {
        metroPortArguments.isEmpty ? nil : metroPortArguments == ["none"] ? [] : try? DeviceAccess.metroPorts(metroPortArguments.joined(separator: " "))
    }

    @OptionGroup var output: DeviceJSONOption

    var json: Bool { output.json }

    @OptionGroup(visibility: .private) var listFilters: DeviceListFilters

    func validate() throws {
        try listFilters.refuse(in: Self.self)
        if plan, device != nil || !apps.isEmpty || expires != nil || team != nil || !metroPortArguments.isEmpty || testDevice {
            throw ValidationError("--plan changes nothing, so it takes only --json.")
        }
        if let expires { _ = try DeviceAccess.expiry(expires) }
        if let team, !DeviceAllowance.isTeamID(team) {
            throw ValidationError("--team takes a 10-character Apple team ID such as ABCDE12345; '\(team)' is not one.")
        }
        for app in apps where !DeviceAllowance.isAppID(app) {
            throw ValidationError("--app takes a bundle id or package name, such as com.example.app; '\(app)' is not one.")
        }
        guard Set(apps).count == apps.count else { throw ValidationError("--app names the same app twice.") }
        if testDevice, !apps.isEmpty { throw ValidationError("--test-device drives the whole device, so it takes no --app.") }
        if !metroPortArguments.isEmpty, metroPortArguments != ["none"] {
            guard !metroPortArguments.contains("none") else { throw ValidationError("--metro-port none stands alone, without ports.") }
            do {
                _ = try DeviceAccess.metroPorts(metroPortArguments.joined(separator: " "))
            } catch let error as ValidationError {
                throw ValidationError("--metro-port: \(error.message)")
            }
        }
    }

    /// What the person chose; `lifetime` nil means until removed.
    struct Choice {
        let row: DeviceSummary
        let key: String
        let team: String?
        let apps: [String]
        let lifetime: TimeInterval?
        var metroPorts: [Int] = []
        /// The end a change kept, which Touch ID's wait must not push back.
        var keptExpiry: Date?
        var testDevice = false
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
        let console = Console.current
        if plan {
            console.data(try await planOutput(context: DeviceAccessContext.current) + "\n")
            return
        }
        let output: String
        do {
            output = try await perform(context: DeviceAccessContext.current)
        } catch let interrupted as Interrupted {
            if console.out.profile != .person { console.data(interrupted.output + "\n") }
            throw interrupted.failure
        }
        // A person read the receipt on the terminal already; stdout gets it only when someone else reads it.
        if json || console.out.profile != .person { console.data(output + "\n") }
    }

    /// The commands that would add what is plugged in; lists rows and teams only.
    @MainActor
    func planOutput(context: DeviceAccessContext) async throws -> String {
        let rows = try await Console.current.progress("Looking for devices") { try await context.physicalDevices().rows }
        let profile = context.profile()
        let built = DeviceAddPlan.make(
            rows: rows, policy: context.policy(), teams: context.signingTeams().map { DeviceAddPlan.Team(id: $0.id, name: $0.name, free: $0.free) }, now: context.now(),
            app: { $0 == .ios ? profile?.bundleID : profile?.package }
        )
        return json ? built.json() : built.text()
    }

    /// `Test iPhone stays allowed`, or `Test iPhone and Test Pixel stay allowed`.
    static func staysAllowed(_ names: [String]) -> String {
        "\(LoginDirectory.list(names)) \(names.count > 1 ? "stay" : "stays") allowed."
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
        let instead = "`offsider devices add --plan` prints the command to give the user, to run in their own terminal."
        try PersonPresence.requireTerminal(instead: instead)
        let store = try context.requireStore()
        let policy = context.policy()
        let named = try device.map(DeviceAccess.physicalKey)
        var reports: [String] = []
        var savedNames: [String] = []
        var stopped: (any Error)?
        try await TerminalPrompt.runAsync(
            cancelled: AllowScreen.cancelled, instead: instead, descriptor: context.promptDescriptor, idle: context.promptIdle, keeps: true
        ) { prompt in
            prompt.lines(AllowScreen.header(width: prompt.width, style: prompt.style))
            var (row, connected, askedDevice) = try await pickDevice(on: prompt, context: context, policy: policy, named: named)
            var allowedNow: Set<String> = []
            /// Where this device's lines begin, so a stop erases them and keeps every earlier receipt.
            var deviceStart = prompt.mark
            while true {
                let choice: Choice
                let entry: DeviceAllowance?
                let droppedTampered: Bool
                do {
                    row = try await waitUntilReady(row, on: prompt, context: context)
                    choice = try await complete(row, on: prompt, context: context, policy: policy, later: !savedNames.isEmpty, askedDevice: askedDevice)
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
                let withdrawn = choice.row.platform == .android ? await context.withdrawMetroPorts(choice.key, choice.metroPorts) : MetroReverseOutcome()
                let removedPorts = withdrawn.removed.flatMap(\.ports).map(MetroReverse.label)
                let stuckPorts = withdrawn.failed.flatMap(\.ports).map(MetroReverse.label)
                let retry = "offsider session stop --device \(choice.key)"
                let notes = removedPorts.map { "Removed \($0)" } + stuckPorts.map { "Could not remove \($0): run `\(retry)`" }
                let setup = await finish(choice, on: prompt, context: context)
                await offerLogin(choice, on: prompt, context: context, policy: policy)
                prompt.lines(AllowScreen.allowed(name: name, key: choice.key, until: until, apps: choice.apps, metroPorts: choice.metroPorts, testDevice: choice.testDevice, notes: notes, ready: setup.ready, width: prompt.width, style: prompt.style))
                prompt.settle()
                reports.append(json
                    ? DeviceAccessReport.changeJSON(
                        action: "allow", platform: choice.row.platform, key: choice.key, allowance: entry, stopped: removedPorts,
                        notRemoved: stuckPorts, retry: stuckPorts.isEmpty ? nil : retry, ready: setup.ready, needs: setup.needs
                    )
                    : (AllowScreen.allowed(name: name, key: choice.key, until: until, apps: choice.apps, metroPorts: choice.metroPorts, testDevice: choice.testDevice, notes: notes, ready: setup.ready, width: .max, style: .detect(isTerminal: false)) + (setup.needs.map { [$0] } ?? [])).joined(separator: "\n"))
                allowedNow.insert(choice.key)
                savedNames.append(name)
                guard named == nil, !json else { return }
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
                askedDevice = true
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
                expires: chosen.keptExpiry ?? chosen.lifetime.map { Date(timeIntervalSince1970: now.addingTimeInterval($0).timeIntervalSince1970.rounded(.down)) },
                apps: chosen.apps,
                team: chosen.team,
                metroPorts: chosen.metroPorts,
                testDevice: chosen.testDevice
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

    /// One app recommends 7 days; any app on a phone stays at 12 hours.
    static func expiryRecommended(apps: [String]) -> Int {
        let oneApp = !apps.isEmpty && apps != [DeviceAllowance.wholeDevicePin]
        return oneApp ? expiryOptions.firstIndex { $0.value == DeviceAccess.oneAppExpiry } ?? recommendedExpiry : recommendedExpiry
    }

    /// How long a phone may ask for a person's hands before `add` stops waiting.
    static let setupWait: TimeInterval = 600

    /// Asks for the one step the phone waits on, watches its listing until it clears and asks for the next; reads rows only.
    @MainActor
    private func waitUntilReady(_ row: DeviceSummary, on prompt: TerminalPrompt, context: DeviceAccessContext) async throws -> DeviceSummary {
        guard Self.watchedAsk(row) != nil else { return row }
        let key = StableDeviceKey.of(row)
        let start = prompt.mark
        var current = row
        var shown: String?
        let deadline = context.now().addingTimeInterval(Self.setupWait)
        while let ask = Self.watchedAsk(current) {
            if ask != shown {
                prompt.rewind(to: start)
                prompt.lines(TerminalUI.warning(ask, width: prompt.width, style: prompt.style) + [prompt.style.dim(AllowScreen.watching)])
                shown = ask
            }
            if prompt.quitPressed(within: Self.setupPoll) { throw PromptCancelled() }
            guard context.now() < deadline else {
                throw CLIError.personRequired("\(ask) Offsider stopped waiting, and nothing was saved. Run the command again once that is done.")
            }
            let rows = (try? await context.physicalDevices().rows) ?? []
            current = rows.first { StableDeviceKey.of($0) == key } ?? current
        }
        prompt.rewind(to: start)
        return current
    }

    /// The step to watch the listing for. An iPhone listed with Developer Mode off may only be locked, so its app read or `finish` judges that.
    static func watchedAsk(_ row: DeviceSummary) -> String? {
        row.platform == .ios && row.state == IOSDeviceReadiness.developerModeOff.stateText ? nil : DeviceSetupAsk.ask(row)
    }

    /// Seconds between looks at a phone a person is setting up.
    static let setupPoll: TimeInterval = 2
    /// How often `finish` tries again while a person's step is outstanding.
    static let finishPoll: TimeInterval = 5

    /// What only a person can clear on the phone; anything else stops `finish`.
    static func personCanClear(_ error: any Error) -> Bool {
        guard let failure = error as? IOSDeviceError else { return false }
        return [.locked, .certificateNotTrusted, .uiAutomationOff, .developerModeOff, .untrusted, .preparing].contains(failure.kind)
    }

    /// The step a person's hands clear, asked by the phone's name, so the screen never shows its ID; nil when no person can clear it.
    static func setupAsk(_ error: any Error, row: DeviceSummary) -> String? {
        (error as? any OffsiderFailure)?.ask.map { PersonAsk.filled($0, name: AllowScreen.name(row), id: nil) }
    }

    /// Registers, builds and starts what the device needs, retrying while a person clears a step; the allowance stays whatever happens here.
    @MainActor
    private func finish(_ choice: Choice, on prompt: TerminalPrompt, context: DeviceAccessContext) async -> (ready: Bool, needs: String?) {
        let start = prompt.mark
        var shown: String?
        let deadline = context.now().addingTimeInterval(Self.setupWait)
        while true {
            do {
                let label = "Getting \(AllowScreen.name(choice.row)) ready"
                let ready = try await TerminalSpinner.run(label, terminal: prompt.terminalDescriptor) { try await context.prepare(choice.row) }
                prompt.rewind(to: start)
                return (ready, nil)
            } catch {
                let needs = Self.reason(error) + "."
                let ask = Self.setupAsk(error, row: choice.row) ?? needs
                guard Self.personCanClear(error), context.now() < deadline else {
                    prompt.rewind(to: start)
                    prompt.lines(TerminalUI.warning(ask, width: prompt.width, style: prompt.style))
                    return (false, needs)
                }
                if ask != shown {
                    prompt.rewind(to: start)
                    prompt.lines(TerminalUI.warning(ask, width: prompt.width, style: prompt.style) + [prompt.style.dim(AllowScreen.watching)])
                    shown = ask
                }
                if prompt.quitPressed(within: Self.finishPoll) {
                    prompt.rewind(to: start)
                    prompt.lines(TerminalUI.warning(ask, width: prompt.width, style: prompt.style))
                    return (false, needs)
                }
            }
        }
    }

    /// Skip is chosen; a cancel or failure here never costs the device it just allowed.
    @MainActor
    private func offerLogin(_ choice: Choice, on prompt: TerminalPrompt, context: DeviceAccessContext, policy: PhysicalDevicePolicy) async {
        guard !json, let store = context.credentials else { return }
        let start = prompt.mark
        do {
            let rows = [MenuRow(.cancel, [AllowScreen.skipLogin], recommended: true), MenuRow(.lock, [AllowScreen.addLogin, AllowScreen.addLoginDetail])]
            let wanted = try prompt.choose(AllowScreen.loginQuestion, rows: rows, selected: 0, keepsChoice: false) == 1
            prompt.rewind(to: start)
            guard wanted else { return }
            let app = try await loginApp(choice, on: prompt, context: context, policy: policy)
            prompt.rewind(to: start)
            prompt.lines([TerminalUI.receipt("Login", PromptScreen.label(app), style: prompt.style)])
            let questions = TerminalCredentialQuestions(prompt: prompt)
            _ = try CredentialCommand.perform(
                .set, app: app, key: nil, settings: choice.testDevice ? LoginSettingsEdit() : LoginSettingsEdit(devices: .any), personConfirmed: true,
                json: false, store: store, questions: questions, readCredential: questions.credential
            )
            prompt.rewind(to: start)
            prompt.lines([TerminalUI.receipt("Login", "saved for \(PromptScreen.label(app))", style: prompt.style)])
        } catch where error is PromptCancelled || error is PromptTimedOut {
            prompt.rewind(to: start)
        } catch {
            prompt.rewind(to: start)
            prompt.lines(TerminalUI.warning("No login saved: \(Self.reason(error)). `offsider credential add` saves one later.", width: prompt.width, style: prompt.style))
        }
    }

    /// The pinned app when there is just one; else its apps, the project's first, or typing.
    @MainActor
    private func loginApp(_ choice: Choice, on prompt: TerminalPrompt, context: DeviceAccessContext, policy: PhysicalDevicePolicy) async throws -> String {
        if choice.apps.count == 1, choice.apps != [DeviceAllowance.wholeDevicePin] { return choice.apps[0] }
        let listed = (try? await TerminalSpinner.run("Reading its apps", terminal: prompt.terminalDescriptor) { try await context.installedApps(choice.row) }) ?? []
        let menu = Self.appMenu(listed, platform: choice.row.platform, policy: policy, profile: context.profile(), front: nil)
        let offered = menu.choices.filter { if case .app = $0 { return true } else { return $0 == .type } }
        var rows = AppMenu(choices: offered, recommended: menu.recommended).rows()
        if rows.isEmpty { rows = [MenuRow(.type, [AllowScreen.typeApp])] }
        let index = try prompt.choose(AllowScreen.appQuestion, rows: rows, selected: 0, keepsChoice: false)
        if index < offered.count, case .app(let app) = offered[index] { return app.id }
        let typed = try typeApp(on: prompt, platform: choice.row.platform, policy: policy, label: "  App ID: ")
        guard let id = typed.value.first else { throw PromptCancelled() }
        return id
    }

    /// The steps after the device is known: team, app, Metro, how long, the summary and Touch ID.
    @MainActor
    /// `later` marks a device after the first: there `--team` applies only to an iPhone or iPad and `--metro-port` only to a phone, and each is skipped for the other.
    private func complete(_ row: DeviceSummary, on prompt: TerminalPrompt, context: DeviceAccessContext, policy: PhysicalDevicePolicy, later: Bool = false, askedDevice: Bool = true) async throws -> Choice {
        let key = StableDeviceKey.of(row) ?? row.id
        let team = row.platform == .ios || !later ? self.team : nil
        if team != nil, row.platform != .ios {
            throw CLIError(errorDescription: "--team is for an iPhone or iPad, and \(key) is an Android phone. Nothing was saved.", reason: .usage)
        }
        let metroPorts = row.platform == .android || !later ? self.metroPorts : nil
        if let metroPorts, !metroPorts.isEmpty, row.platform != .android {
            throw CLIError(errorDescription: "--metro-port is for an Android phone, and \(key) is an iPhone or iPad. Nothing was saved.", reason: .usage)
        }
        if case .refused(let refusal) = policy.decision(platform: row.platform, key: key), refusal.isManaged {
            throw CLIError.deviceNotAllowed(name: row.name, key: key, refusal: refusal)
        }
        for app in apps {
            if let problem = Self.appProblem(app, platform: row.platform, policy: policy) {
                throw CLIError(errorDescription: problem, reason: .appNotAllowed)
            }
        }
        // A device already allowed is being changed: each step starts on what it has now, since saving replaces the whole entry.
        var current: DeviceAllowance?
        if case .allowed(let entry) = policy.decision(platform: row.platform, key: key, now: context.now()) { current = entry }
        if testDevice, let off = policy.managed.testDeviceRefusal {
            throw CLIError(errorDescription: "\(off), so \(key) cannot be a test device. Nothing was saved.", reason: .appNotAllowed)
        }
        var teams: [SigningTeam] = []
        if row.platform == .ios, team == nil {
            teams = try await TerminalSpinner.run("Reading your signing teams", terminal: prompt.terminalDescriptor) { context.signingTeams() }
        }
        // One team has nothing to choose, unless it would replace the one this device already has.
        let onlyTeam = teams.count == 1 && (current?.team == nil || current?.team == teams[0].id) ? teams[0] : nil
        let offersTest = policy.managed.testDeviceRefusal == nil
        var steps = stepNames(platform: row.platform, askDevice: askedDevice, askTeam: onlyTeam == nil, askUse: offersTest)
        /// Runs the step with its `2/4` marker, then leaves one receipt line in place of everything it drew.
        func step<T>(_ name: String, _ body: (String?) async throws -> (value: T, shown: String)) async throws -> (value: T, shown: String) {
            let start = prompt.mark
            let marker = steps.firstIndex(of: name).map { "\($0 + 1)/\(steps.count)" }
            let (value, shown) = try await body(marker)
            prompt.rewind(to: start)
            prompt.lines([TerminalUI.receipt(name, shown, style: prompt.style)])
            return (value, shown)
        }
        var chosenWhole = testDevice
        if apps.isEmpty, !testDevice, offersTest {
            chosenWhole = try await step("Use") { try pickUse(on: prompt, current: current, step: $0) }.value
            if chosenWhole { steps.removeAll { ["App", "Metro", "How long"].contains($0) } }
        }
        var chosenTeam = team
        var shownTeam = team.map { "team \($0)" }
        if let onlyTeam {
            chosenTeam = onlyTeam.id
            shownTeam = Self.teamShown(onlyTeam, among: teams)
            prompt.lines([TerminalUI.receipt("Team", Self.teamShown(onlyTeam, among: teams), style: prompt.style)])
        } else if row.platform == .ios, team == nil {
            let picked = try await step("Team") { try await pickTeam(on: prompt, teams: teams, current: current?.team, step: $0) }
            chosenTeam = picked.value
            shownTeam = picked.value == nil ? nil : picked.shown
        }
        var chosenApps = apps
        if apps.isEmpty, !chosenWhole {
            chosenApps = try await step("App") { try await pickApp(on: prompt, row: row, context: context, policy: policy, current: current, step: $0) }.value
        }
        // A use decided by flag or the test device row needs no more questions: the rest take their defaults.
        let settled = chosenWhole || !apps.isEmpty
        var chosenPorts = metroPorts ?? (settled ? current?.metroPorts ?? [] : [])
        if row.platform == .android, metroPorts == nil, !settled {
            chosenPorts = try await step("Metro") { try pickMetroPorts(on: prompt, current: current?.metroPorts ?? [], step: $0) }.value
        }
        let lifetime: TimeInterval?
        var keptExpiry: Date?
        if let expires {
            lifetime = try DeviceAccess.expiry(expires)
        } else if settled {
            if let current, current.testDevice == chosenWhole {
                lifetime = current.expires?.timeIntervalSince(context.now())
                keptExpiry = current.expires
            } else {
                lifetime = chosenWhole ? nil : try DeviceAccess.expiry(DeviceAccess.oneAppExpiry)
            }
        } else {
            let kept = current.map { entry in (entry.expires?.timeIntervalSince(context.now()), AllowScreen.until(entry.expires, now: context.now(), timeZone: context.timeZone)) }
            let picked = try await step("How long") { try pickExpiry(on: prompt, current: kept, step: $0, apps: chosenApps) }
            lifetime = picked.value
            if picked.shown == kept?.1 { keptExpiry = current?.expires }
        }
        let name = AllowScreen.name(row)
        let start = prompt.mark
        prompt.lines([""] + AllowScreen.summary(row, apps: chosenApps, lifetime: lifetime, team: shownTeam, metroPorts: chosenPorts, testDevice: chosenWhole, width: prompt.width, style: prompt.style))
        prompt.lines([prompt.style.dim(AllowScreen.confirm)])
        let reach = chosenPorts.isEmpty ? "" : " and let its apps reach \(AllowScreen.metro(chosenPorts))"
        let whole = chosenWhole ? " as a \(AllowScreen.wholeDevice) with nothing personal on it" : ""
        let register = row.platform == .ios && chosenTeam != nil ? " and register it with your Apple team" : ""
        try await PersonPresence.confirm(reason: "allow Offsider to drive \(name) (\(PromptScreen.visible(key)))\(whole)\(reach)\(register)")
        prompt.rewind(to: start)
        return Choice(row: row, key: key, team: chosenTeam, apps: chosenApps, lifetime: lifetime, metroPorts: chosenPorts, keptExpiry: keptExpiry, testDevice: chosenWhole)
    }

    /// The steps this run shows, in order; a flag given on the command line skips its step, and a use settled by flag skips the rest.
    func stepNames(platform: DevicePlatform, askDevice: Bool = true, askTeam: Bool = true, askUse: Bool = true) -> [String] {
        let settled = testDevice || !apps.isEmpty
        var names: [String] = []
        if device == nil, askDevice { names.append("Device") }
        if !settled, askUse { names.append("Use") }
        if platform == .ios, team == nil, askTeam { names.append("Team") }
        if !settled { names.append("App") }
        if platform == .android, metroPortArguments.isEmpty, !settled { names.append("Metro") }
        if expires == nil, !settled { names.append("How long") }
        return names
    }

    /// The chosen device and every USB-connected physical device the scan found.
    @MainActor
    private func pickDevice(
        on prompt: TerminalPrompt, context: DeviceAccessContext, policy: PhysicalDevicePolicy, named: (platform: DevicePlatform, key: String)?
    ) async throws -> (DeviceSummary, [DeviceSummary], asked: Bool) {
        var teams: [SigningTeam]?
        func scan() async throws -> (rows: [DeviceSummary], warnings: [String]) {
            try await TerminalSpinner.run("Looking for devices", terminal: prompt.terminalDescriptor) { try await context.physicalDevices() }
        }
        if let named {
            let rows = try await scan().rows
            guard let match = rows.first(where: { $0.connection == "usb" && $0.platform == named.platform && StableDeviceKey.of($0) == named.key }) else {
                throw CLIError(
                    errorDescription: "\(named.key) is not a physical device connected over USB. Connect it with a cable, then run `offsider devices add` and choose it.",
                    reason: .deviceNotFound, hint: "offsider devices --physical"
                )
            }
            return (match, [], false)
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
            // The count is the longest run any connected device could take; the pick renumbers from step 2.
            if teams == nil, team == nil, wired.contains(where: { $0.platform == .ios }) { teams = context.signingTeams() }
            let oneTeam = teams?.count == 1
            let total = Set(wired.map(\.platform)).map { stepNames(platform: $0, askTeam: !oneTeam).count }.max() ?? 1
            let allAllowed = wired.isEmpty && !allowed.isEmpty
            if wired.count == 1, allowed.isEmpty, wireless.isEmpty {
                prompt.rewind(to: start)
                prompt.lines([TerminalUI.receipt("Device", AllowScreen.name(wired[0]), style: prompt.style)])
                return (wired[0], wired, false)
            }
            let menu = wired.map { AllowScreen.deviceRow($0, key: StableDeviceKey.of($0) ?? $0.id, style: prompt.style) }
                + allowed.map { AllowScreen.allowedRow($0.0, detail: AccessStatusScreen.detail($0.1, now: now, timeZone: context.timeZone, team: false, style: prompt.style), style: prompt.style) }
                + wireless.map { AllowScreen.deviceRow($0, key: StableDeviceKey.of($0) ?? $0.id, style: prompt.style) }
            do {
                let index = try prompt.choose(
                    AllowScreen.deviceQuestion, step: wired.isEmpty ? nil : "1/\(total)", rows: menu,
                    warning: usb.isEmpty ? AllowScreen.noDevice : nil,
                    notes: usb.isEmpty ? warnings : allAllowed ? [AllowScreen.allAllowed] : [],
                    commands: allAllowed ? [("Withdraw", AccessStatusScreen.removeCommand(allowed.count == 1 ? allowed[0].1.key : nil))] : [],
                    rescan: true, keepsChoice: false
                )
                prompt.rewind(to: start)
                let chosen = index < wired.count ? wired[index] : allowed[index - wired.count].0
                prompt.lines([TerminalUI.receipt("Device", AllowScreen.name(chosen), style: prompt.style)])
                return (chosen, index < wired.count ? wired : [], true)
            } catch is PromptRefresh {
                prompt.rewind(to: start)
            }
        }
    }

    @MainActor
    private func pickTeam(on prompt: TerminalPrompt, teams: [SigningTeam], current: String?, step: String?) async throws -> (value: String?, shown: String) {
        let problem = "A team ID is 10 letters and digits, such as ABCDE12345."
        guard !teams.isEmpty else {
            prompt.lines(TerminalUI.warning(AllowScreen.noTeam, width: prompt.width, style: prompt.style))
            let typed = try prompt.ask("  Team ID: ") { answer in
                let text = answer.trimmingCharacters(in: .whitespaces)
                return text.isEmpty || DeviceAllowance.isTeamID(text) ? nil : problem
            }.trimmingCharacters(in: .whitespaces).uppercased()
            return typed.isEmpty ? (current, current ?? "none") : (typed, typed)
        }
        let rows = Self.teamRows(teams) + [MenuRow(.type, [AllowScreen.typeTeam])]
        let kept = current.map { AllowScreen.keepRow(PromptScreen.label($0)) }
        let index = try prompt.choose(AllowScreen.teamQuestion, step: step, rows: (kept.map { [$0] } ?? []) + rows, keepsChoice: false) - (kept == nil ? 0 : 1)
        if index < 0, let current { return (current, PromptScreen.label(current)) }
        if index < teams.count { return (teams[index].id, Self.teamShown(teams[index], among: teams)) }
        let typed = try prompt.ask("  Team ID: ") { DeviceAllowance.isTeamID($0.trimmingCharacters(in: .whitespaces)) ? nil : problem }
            .trimmingCharacters(in: .whitespaces).uppercased()
        return (typed, typed)
    }

    /// The receipt's words for a team, with room for what tells it from a long-named twin.
    static func teamShown(_ team: SigningTeam, among teams: [SigningTeam]) -> String {
        PromptScreen.label(team.shown(among: teams), cap: 120)
    }

    /// A team's name, whether it is free where Xcode says, then its ID and the email its certificate holds, if any, as one dim detail.
    static func teamRows(_ teams: [SigningTeam]) -> [MenuRow] {
        let plans = teams.contains { $0.free != nil }
        return teams.map { team in
            let plan = team.free.map { $0 ? AllowScreen.freeTeam : AllowScreen.paidTeam } ?? ""
            let detail = ([team.id] + (team.account.map { [$0] } ?? [])).joined(separator: "  ")
            return MenuRow(.team, [PromptScreen.label(team.name)] + (plans ? [plan] : []) + [PromptScreen.label(detail)], recommended: teams.count == 1)
        }
    }

    /// One app, or a test device once the person says nothing personal is on it; what the device has now starts chosen, and a device already a test device is not asked again.
    @MainActor
    private func pickUse(on prompt: TerminalPrompt, current: DeviceAllowance?, step: String?) throws -> (value: Bool, shown: String) {
        let rows = [MenuRow(.app, [AllowScreen.useOneApp, AllowScreen.useOneAppDetail], recommended: true), MenuRow(.testDevice, [AllowScreen.testDeviceRow, AllowScreen.testDeviceRowDetail])]
        let isTest = current?.testDevice == true
        let index = try prompt.choose(AllowScreen.useQuestion, step: step, rows: rows, selected: isTest ? 1 : 0, keepsChoice: false)
        guard index == 1 else { return (false, AllowScreen.useOneApp) }
        if !isTest {
            let answer = try prompt.choose(AllowScreen.personalQuestion, rows: Self.personalRows, selected: 0, keepsChoice: false)
            guard answer == Self.personalNoIndex else { throw PromptCancelled() }
        }
        return (true, AllowScreen.wholeDevice)
    }

    /// The apps chosen. A test device is settled earlier, so what can stay here is a pin or any app.
    @MainActor
    private func pickApp(on prompt: TerminalPrompt, row: DeviceSummary, context: DeviceAccessContext, policy: PhysicalDevicePolicy, current: DeviceAllowance?, step: String?) async throws -> (value: [String], shown: String) {
        let kept = current.flatMap { entry -> DeviceAllowance? in
            if entry.testDevice { return nil }
            return entry.pinnedApps.contains { Self.appProblem($0, platform: row.platform, policy: policy) != nil } ? nil : entry
        }
        func keep(_ entry: DeviceAllowance) -> (value: [String], shown: String) {
            (entry.apps, AllowScreen.apps(entry.apps))
        }
        let listed: [InstalledApp]
        let front: String?
        do {
            (listed, front) = try await TerminalSpinner.run("Reading its apps", terminal: prompt.terminalDescriptor) {
                (try await context.installedApps(row), await context.frontApp(row))
            }
        } catch {
            prompt.lines(TerminalUI.warning(Self.appsProblem(error, row: row), width: prompt.width, style: prompt.style))
            let lead = step.map { "\($0) " } ?? "  "
            if let kept {
                let answer = try typeApp(on: prompt, platform: row.platform, policy: policy, label: lead + "App ID (Return to keep \(keep(kept).shown)): ")
                return answer.value.isEmpty ? keep(kept) : answer
            }
            return try typeApp(on: prompt, platform: row.platform, policy: policy, label: lead + "App ID (Return for any app): ")
        }
        let menu = Self.appMenu(listed, platform: row.platform, policy: policy, profile: context.profile(), front: front)
        let rows = (kept.map { [AllowScreen.keepRow(keep($0).shown)] } ?? []) + menu.rows()
        let index = try prompt.choose(AllowScreen.appQuestion, step: step, rows: rows, selected: kept == nil ? menu.selected : 0, keepsChoice: false) - (kept == nil ? 0 : 1)
        if index < 0, let kept { return keep(kept) }
        switch menu.choices[index] {
        case .app(let app): return ([app.id], PromptScreen.label(app.name ?? app.id))
        case .any: return ([], AllowScreen.apps([]))
        case .wholeDevice: return ([DeviceAllowance.wholeDevicePin], Self.wholeDeviceLabel.lowercased())
        case .type: return try typeApp(on: prompt, platform: row.platform, policy: policy, label: "  App ID: ")
        }
    }

    /// Why the app menu is missing, in the person's words: never a raw `devicectl` error, or a `doctor` that refuses a device not yet allowed.
    static func appsProblem(_ error: any Error, row: DeviceSummary) -> String {
        if row.platform == .ios, row.state == IOSDeviceReadiness.developerModeOff.stateText { return AllowScreen.appsDeveloperModeOff }
        switch (error as? any OffsiderFailure)?.reason {
        case .deviceLocked?: return AllowScreen.appsLocked
        case .developerModeOff?: return AllowScreen.appsDeveloperModeOff
        default: break
        }
        switch (error as? IOSDeviceError)?.kind {
        case .diskImageFailed?: return AllowScreen.appsDiskImageFailed
        case .devicectlFailed?: return AllowScreen.appsUnread
        default: return "Could not read its apps (\(reason(error))). Type an app ID."
        }
    }

    /// "Yes, stop" comes first and chosen, so Enter never widens anything.
    static let personalRows = [MenuRow(.cancel, [AllowScreen.personalYes], recommended: true), MenuRow(.testDevice, [AllowScreen.personalNo])]
    static let personalNoIndex = 1

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
            recommended ?? choices.firstIndex { if case .app = $0 { return true } else { return false } } ?? choices.firstIndex(of: .type) ?? 0
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

    /// None first and chosen by default: a reverse opens Metro to every app on the phone.
    @MainActor
    private func pickMetroPorts(on prompt: TerminalPrompt, current: [Int], step: String?) throws -> (value: [Int], shown: String) {
        let now = current.map(String.init).joined(separator: ", ")
        let kept = current.isEmpty ? [] : [AllowScreen.keepRow(now)]
        let rows = kept + [
            MenuRow(.lock, [AllowScreen.noMetro, AllowScreen.noMetroDetail], recommended: true),
            MenuRow(.link, ["8081", AllowScreen.metroPortDetail]),
            MenuRow(.type, [AllowScreen.typePorts]),
        ]
        let index = try prompt.choose(AllowScreen.metroQuestion, step: step, rows: rows, selected: 0, keepsChoice: false) - kept.count
        let ports: [Int]
        switch index {
        case -1: ports = current
        case 0: ports = []
        case 1: ports = [8081]
        default:
            let typed = try prompt.ask("  Ports (\(current.isEmpty ? "" : "now \(now); ")such as 8081 8742, Return for none): ") { answer in
                do {
                    _ = try DeviceAccess.metroPorts(answer)
                    return nil
                } catch let error as ValidationError {
                    return error.message
                } catch {
                    return "\(error)"
                }
            }
            ports = try DeviceAccess.metroPorts(typed)
        }
        return (ports, ports.isEmpty ? "none" : ports.map(String.init).joined(separator: ", "))
    }

    @MainActor
    private func pickExpiry(on prompt: TerminalPrompt, current: (lifetime: TimeInterval?, shown: String)?, step: String?, apps: [String]) throws -> (value: TimeInterval?, shown: String) {
        let options = Self.expiryOptions
        let recommended = Self.expiryRecommended(apps: apps)
        let rows = options.enumerated().map { MenuRow($1.mark, [$1.label], recommended: $0 == recommended) }
        let kept = current.map { [AllowScreen.keepRow($0.shown)] } ?? []
        let index = try prompt.choose(AllowScreen.expiryQuestion, step: step, rows: kept + rows, selected: kept.isEmpty ? recommended : 0, keepsChoice: false) - kept.count
        if index < 0, let current { return (current.lifetime, current.shown) }
        if let value = options[index].value {
            let lifetime = try DeviceAccess.expiry(value)
            return (lifetime, AllowScreen.duration(lifetime))
        }
        let typed = try prompt.ask("  How long (like 45m, 2h, 7d or never): ") { answer in
            do {
                _ = try DeviceAccess.expiry(answer)
                return nil
            } catch let error as ValidationError {
                return error.message.replacingOccurrences(of: "--expires", with: "A duration")
            } catch {
                return "\(error)"
            }
        }
        let lifetime = try DeviceAccess.expiry(typed)
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
        abstract: "Show the phones and tablets agents may drive and any managed policy; with --device, exit 7 (device_not_allowed) unless that one is allowed."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("Check only this device.", valueName: "id"))
    var device: String?

    @OptionGroup var output: DeviceJSONOption

    var json: Bool { output.json }

    @OptionGroup(visibility: .private) var listFilters: DeviceListFilters

    func validate() throws {
        try listFilters.refuse(in: Self.self)
    }

    func run() async throws {
        let console = Console.current
        let context = DeviceAccessContext.current
        if !json, device == nil {
            let page = screen(context: context)
            console.show(Page(page.blocks, notices: console.out.profile == .person ? page.notices : []))
            return
        }
        let (output, refusal) = try perform(context: context)
        console.data(output)
        // Its one JSON document is on stdout, so the failure adds only its stderr line and exit code.
        if let refusal { throw json ? ReportedFailure(underlying: refusal, exitCode: refusal.exitCode) : refusal }
    }

    /// The whole list: a person's screen, and beside it the text agents parse.
    func screen(context: DeviceAccessContext) -> Page {
        let policy = context.policy()
        let now = context.now()
        return AccessStatusScreen.page(policy, now: now, timeZone: context.timeZone, agent: DeviceAccessReport.statusText(policy, now: now, path: Self.path(context)), style: Console.current.out.canvas.style)
    }

    static func path(_ context: DeviceAccessContext) -> String {
        context.store()?.path ?? "~/.config/offsider/\(DeviceAllowListStore.fileName)"
    }

    /// The text or JSON agents parse, and the error to exit with when `--device` is not allowed.
    func perform(context: DeviceAccessContext) throws -> (String, CLIError?) {
        let policy = context.policy()
        let now = context.now()
        let target = try device.map(DeviceAccess.physicalKey)
        let output = json
            ? policy.statusJSON(now: now, only: target)
            : DeviceAccessReport.statusText(policy, now: now, path: Self.path(context))
        guard let target else { return (output, nil) }
        switch policy.decision(platform: target.platform, key: target.key, now: now) {
        case .allowed(let entry):
            let extra = json ? "" : "\(target.key) is allowed\(entry.expires.map { " until \(ProcessStamp.timestamp($0))" } ?? "").\n"
            return (output + extra, nil)
        case .refused(let refusal):
            let name = policy.list.entry(platform: target.platform, key: target.key)?.name ?? policy.list.newerEntry(platform: target.platform, key: target.key)?.name
            return (output, CLIError.deviceNotAllowed(name: name, key: target.key, refusal: refusal))
        }
    }
}

struct DeviceAccessRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop agents driving a phone or tablet and stop its runner and session broker; on a terminal, choose it from a menu and offer to uninstall the runner."
    )

    @Option(name: .customLong("device"), help: ArgumentHelp("The physical device's ID; without it, a person chooses from the allowed ones. OFFSIDER_DEVICE is never read.", valueName: "id"))
    var device: String?

    @OptionGroup var output: DeviceJSONOption

    var json: Bool { output.json }

    @OptionGroup(visibility: .private) var listFilters: DeviceListFilters

    func validate() throws {
        try listFilters.refuse(in: Self.self)
    }

    @MainActor
    func run() async throws {
        let console = Console.current
        let removal = try await remove(context: DeviceAccessContext.current, person: !json && console.out.profile == .person)
        let notices = removal.notices.map(\.forPersonOnly)
        DevicePersonView.emit(removal.text, json: json, person: removal.person, notices: notices, console: console)
    }

    /// The agent's text or JSON, and what a person sees after anything the runner question already drew.
    struct Removal {
        var text: String
        var person: [Block] = []
        var notices: [Notice] = []
    }

    @MainActor
    func perform(context: DeviceAccessContext) async throws -> String {
        try await remove(context: context).text
    }

    /// Draws a person's receipt above the runner question when `person`; otherwise the question shows the agent's text.
    @MainActor
    func remove(context: DeviceAccessContext, person: Bool = false) async throws -> Removal {
        guard let device = try device ?? pickAllowed(context: context) else {
            return Removal(text: Self.nothingAllowed, person: DevicePersonView.receipt("Nothing to withdraw", ["no phone or tablet is allowed"]))
        }
        let target = try DeviceAccess.physicalKey(device)
        let store = try context.requireStore()
        let existing = try? store.load()
        let listed = existing.map { $0.list.entry(platform: target.platform, key: target.key) != nil || $0.list.newerEntry(platform: target.platform, key: target.key) != nil } ?? false
        let tampered = existing.map { !context.seal.isIntact($0) } ?? true
        var removed: DeviceAllowance?
        var removedNewer: NewerDeviceEntry?
        if listed || tampered {
            try store.update({ current in
                removed = current.list.entry(platform: target.platform, key: target.key)
                removedNewer = current.list.newerEntry(platform: target.platform, key: target.key)
                let base = context.seal.isIntact(current) ? current.list : .empty
                return base.pruned(now: context.now()).removing(platform: target.platform, key: target.key)
            }, commit: { try context.seal.seal($0) })
        }
        let hadRunner = target.platform == .ios && context.hasRunner(target.key)
        let sessionsResult = await Console.current.progress("Stopping its sessions") { await context.stopSessions(target.key) }
        let stopped = sessionsResult.stopped
        let left = sessionsResult.left
        if json {
            return Removal(text: DeviceAccessReport.changeJSON(
                action: "remove", platform: target.platform, key: target.key, allowance: removed, stopped: stopped,
                notRemoved: left.flatMap(\.parts), retry: left.first?.retry
            ))
        }
        let removedName = removed?.name ?? removedNewer?.name
        var text = removedName.map { "Removed \($0) (\(target.key)) from the allow-list; Offsider will not drive it again until a person allows it." }
            ?? "\(target.key) was not on the allow-list."
        if tampered, existing != nil { text += " The allow-list had been changed outside Offsider, so every entry was dropped." }
        if !stopped.isEmpty { text += " Stopped its \(stopped.joined(separator: " and "))." }
        for entry in left { text += " " + entry.sentence }
        let sessions = stopped.isEmpty ? nil : "stopped its \(stopped.joined(separator: " and "))"
        let receipt = removed.map { DevicePersonView.receipt("Withdrew \(AccessStatusScreen.name($0))", [sessions]) }
            ?? removedNewer.map { DevicePersonView.receipt("Withdrew \(PromptScreen.label($0.name))", [sessions]) }
            ?? DevicePersonView.receipt("Nothing to withdraw", ["\(target.key) was not on the list", sessions])
        let dropped: [Notice] = (tampered && existing != nil ? [.warning("The list was changed outside Offsider, so every entry was dropped")] : []) + left.map(\.notice)
        guard hadRunner else { return Removal(text: text, person: receipt, notices: dropped) }
        let clean = Self.cleanCommand(target.key)
        guard context.interactive() else {
            let installed = Notice.note("Its runner is still installed", mark: .clean, see: clean, label: "Remove")
            return Removal(text: text + " Uninstall Offsider's runner from it with `\(clean)`.", person: receipt, notices: dropped + [installed])
        }
        let answer = try TerminalPrompt.run(cancelled: "Kept the runner; `\(clean)` removes it later.", descriptor: context.promptDescriptor, keeps: true) { prompt in
            prompt.lines(person ? Self.drawn(receipt, notices: dropped, width: prompt.width, style: prompt.style) : [text])
            return try prompt.ask(Self.cleanQuestion) { Self.yesOrNo($0) == nil ? "Type y or n." : nil }
        }
        guard Self.yesOrNo(answer) == true else {
            return Removal(text: "Kept the runner; `\(clean)` removes it later.", person: DevicePersonView.receipt("Kept the runner") + [.commands(title: nil, [Shortcut(clean, "removes it later")])])
        }
        let report = await Console.current.progress("Uninstalling the runner") { await context.cleanRunner(target.key) }
        let cleaned = DevicePersonView.cleaned(report)
        return Removal(text: RunnerSessions.cleanText(report).trimmingCharacters(in: .newlines), person: cleaned.blocks, notices: cleaned.notices)
    }

    /// A person's receipt and notices as the prompt draws them, above its question.
    static func drawn(_ blocks: [Block], notices: [Notice], width: Int, style: TerminalStyle) -> [String] {
        let canvas = Canvas(columns: width + 1, style: style)
        let text = PersonRenderer.body(blocks, canvas: canvas) + PersonRenderer.notices(notices, canvas: canvas, afterBody: false)
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    static let cleanQuestion = "Also uninstall its runner? (Y/n) "
    static let removeQuestion = "Which one to withdraw?"
    static let nothingAllowed = "No phone or tablet is allowed, so there is nothing to withdraw."

    /// The allowed device a person picks, or nil when none is allowed. Without a terminal, `--device` is needed.
    @MainActor
    func pickAllowed(context: DeviceAccessContext) throws -> String? {
        guard !json, context.interactive() else {
            throw CLIError(
                errorDescription: "devices remove needs --device <id> without a terminal. `offsider devices status` lists the allowed ones.",
                reason: .usage, hint: "offsider devices status"
            )
        }
        let now = context.now()
        let policy = context.policy()
        let entries = AccessStatusScreen.allowed(policy, now: now)
        let newer = policy.list.newer
        guard !entries.isEmpty || !newer.isEmpty else { return nil }
        let index = try TerminalPrompt.run(cancelled: "Cancelled; nothing was withdrawn.", descriptor: context.promptDescriptor) { prompt in
            let rows = entries.map { entry in
                MenuRow(entry.platform == .android ? .android : entry.name.contains("iPad") ? .iPad : .iPhone, [
                    AccessStatusScreen.name(entry), AccessStatusScreen.detail(entry, now: now, timeZone: context.timeZone, team: false, style: prompt.style),
                ])
            } + newer.map { entry in
                MenuRow(entry.platform == .android ? .android : entry.name.contains("iPad") ? .iPad : .iPhone, [PromptScreen.label(entry.name), "needs a newer Offsider"])
            }
            return try prompt.choose(Self.removeQuestion, rows: rows)
        }
        return (entries.map(\.key) + newer.map(\.key))[index]
    }

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
