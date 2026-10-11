import ArgumentParser
import Foundation
import OffsiderCore

struct LoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Fill the sign-in form in front with a saved test credential and tap submit once.",
        discussion: """
        The fields are detected: one email or username field, one password field, and one Log in, Sign in, \
        Continue or Next button below the password. A control covered by another screen is ignored. Zero or \
        two matches type nothing. offsider.login.json, found like OFFSIDER.md, can pin ids for one app. \
        --project names the directory to search. Without it, a missing file is not an error.

        --timeout (default 15 seconds, from 1 to 60) is how long login waits for the submit button to enable.

        Exit 0 means the submit button was tapped. It does not mean the server accepted the login. The \
        password is never printed. A physical iPhone or iPad is refused.

        With no name, login uses the default. One saved login is the default, including one saved earlier under a name such as dev.

        --where picks the saved login with every tag given (credential describe sets tags). One match is used. \
        None exits 2 (user_not_found), and several exit 6 (user_ambiguous), as do several saved logins with no \
        default. Both list each login's name, tags and about note, never a username, and the default never \
        breaks a tie. A name and --where do not go together.

        After the tap, login records which saved login it signed in on this device (credential status shows \
        it). When no form is in front, the error names that login and how to switch users: sign out in the \
        app, run credential signed-out, then login again.

        Examples:
          offsider login dev --device DEVICE_ID
          offsider login --where role=admin --where env=staging --device DEVICE_ID
          offsider login dev --project . --json --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The saved login's name, such as dev. Omit it to use the default login.", valueName: "name"))
    var key: String?

    @Option(name: .customLong("where"), help: ArgumentHelp("Use the saved login with this tag, such as role=admin. Repeat to require more tags. Not with a name.", valueName: "tag"))
    var filters: [String] = []

    @Option(name: .customLong("turnstile"), help: ArgumentHelp("auto (default), required or off. auto handles a widget already on screen.", valueName: "mode"))
    var turnstile: LoginTurnstileMode?

    @Option(name: .customLong("timeout"), help: ArgumentHelp("Give up after this many seconds, from 1 to 60 (default 15), while the submit button stays disabled.", valueName: "seconds"))
    var timeoutOption: Double?

    @Option(name: .customLong("project"), help: ArgumentHelp("Directory to search for offsider.login.json. Without it, the search starts at the current directory.", valueName: "path"))
    var project: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout, also on a failure after typing began. identity and password are filled or not_filled, never the secret.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let defaultTimeout: Double = 15

    var timeout: Double { timeoutOption ?? Self.defaultTimeout }

    func validate() throws {
        if let key, LoginKey(rawValue: key) == nil { throw ValidationError(CredentialCommand.keyMessage) }
        _ = try Self.whereTags(filters, named: key != nil)
        guard timeout.isFinite, (1...60).contains(timeout) else {
            throw ValidationError("--timeout must be from 1 to 60 seconds.")
        }
        if let project, project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--project must not be empty.")
        }
    }

    func run() async throws {
        try CLIError.refuseOnPhone(
            deviceOption.id,
            command: "login",
            alternative: "Use a simulator or an Android device."
        )
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog)
        let profile = try LoginProfiles.load(project: project)
        let mode = LoginProfiles.mode(flag: turnstile, profile: profile)
        let filter = try Self.whereTags(filters, named: key != nil)
        let notice = DispatchWorkItem { FileHandle.standardError.write(Data(Self.keychainWaitNotice.utf8)) }
        var giveUp: DispatchWorkItem?
        let report: LoginReport
        do {
            report = try await watchdog.guarding(setupThen: timeout * 2 + 30, device: deviceOption.id) { ready in
                try await Self.perform(
                    on: route, profile: profile, mode: mode, key: key, where: filter, timeout: timeout, logger: logger, tracker: .live(),
                    onPrepared: ready,
                    keychainWillRead: { app in
                        watchdog.disarm()
                        let limit = DispatchWorkItem {
                            ErrorReporter.exitFromTimer(reason: .commandFailed, message: Self.keychainTimeoutMessage, hint: "offsider credential status --app \(app)")
                        }
                        giveUp = limit
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: notice)
                        DispatchQueue.global().asyncAfter(deadline: .now() + Self.keychainWaitLimit, execute: limit)
                    },
                    keychainDidRead: {
                        notice.cancel()
                        giveUp?.cancel()
                        ready()
                    }
                )
            }
        } catch {
            throw await Self.failure(error, json: json)
        }
        print(json ? report.jsonLine() : report.textLine())
    }

    /// Under --json, a login that began typing prints its own report of how far it got; an earlier failure keeps the error envelope.
    @MainActor
    static func failure(_ error: any Error, json: Bool, scope: CommandScope = .current, write: (String) -> Void = { print($0) }) async -> any Error {
        guard json, let stopped = error as? LoginFailure else { return error }
        let annotated = await scope.screenHint(for: stopped)
        var report = stopped.report
        report.error = ErrorReporter.payload(for: annotated)
        write(report.jsonLine())
        return ReportedFailure(underlying: annotated, exitCode: report.exitCode)
    }

    static let keychainWaitNotice = "Waiting for macOS to let offsider read the saved login. Answer the Keychain prompt.\n"
    static let keychainWaitLimit: TimeInterval = 300
    static let keychainTimeoutMessage = "The macOS Keychain prompt had no answer within 5 minutes, so the saved login was not read. Nothing was typed, and the device is free again."

    /// One lock, already held by the caller. A macOS prompt can hold the Keychain reads, so they run between the keychain callbacks.
    @MainActor
    static func perform(
        on route: DeviceRouter.Route,
        profile: LoginProfile?,
        mode: LoginTurnstileMode,
        key requestedKey: String?,
        where filter: [LoginTag] = [],
        timeout: TimeInterval,
        logger: OffsiderLogger,
        store: any LoginCredentialStoring = KeychainLoginCredentialStore(),
        tracker: SignInTracker? = nil,
        onPrepared: @Sendable () -> Void = {},
        keychainWillRead: (_ app: String) -> Void = { _ in },
        keychainDidRead: () -> Void = {}
    ) async throws -> LoginReport {
        try await route.backend.prepare()
        onPrepared()
        let tree = try await route.backend.accessibilityTree(for: route.device)
        let app = try ForegroundAppLookup.identifier(in: tree, forLogin: true)
        let canonical: String
        let entry: LoginEntry
        let credential: LoginCredential
        do {
            keychainWillRead(app)
            defer { keychainDidRead() }
            canonical = try store.canonical(of: app)
            entry = try resolveLogin(requestedKey, where: filter, app: app, entries: try store.entries(app: canonical), device: route.device)
            credential = try stored(app: canonical, key: entry.key, foreground: app, store: store)
        }
        let services = LoginFlow.Services(
            readTree: { try await route.backend.accessibilityTree(for: route.device) },
            typeText: { text, field in
                var typing = try Self.typingCommand(text: text, field: field, deviceID: route.device.rawValue)
                defer { typing.text = nil }
                try await typing.execute(on: route, progress: nil, logger: logger)
            },
            tap: { point, tree in
                let physical = try await route.backend.deviceCoordinates(for: [(x: point.x, y: point.y)], tree: tree, on: route.device)[0]
                try await route.backend.performTracked(.tapAt(x: physical.x, y: physical.y), on: route.device)
            },
            readTurnstile: {
                let status = try await Self.turnstileCommand(timeout: timeout, deviceID: route.device.rawValue).readStatus(on: route)
                return phase(of: status)
            },
            performTurnstile: {
                try await Self.turnstileCommand(timeout: timeout, deviceID: route.device.rawValue).perform(on: route, logger: logger)
            },
            clock: .live
        )
        let deviceID = route.device.rawValue
        var report: LoginReport
        do {
            report = try await LoginFlow.run(
                app: app, key: entry.key, credential: credential, profile: profile, turnstile: mode, timeout: timeout, services: services,
                lastSignIn: {
                    tracker?.last(app: canonical, deviceID: deviceID).map {
                        LoginFlow.LastSignIn(key: $0.record.key, since: $0.record.since, restarted: $0.restarted, deviceID: deviceID)
                    }
                }
            )
        } catch var failure as LoginFailure {
            failure.report.tags = entry.context.tags
            failure.report.filter = filter
            throw failure
        }
        tracker?.record(app: canonical, foreground: app, key: entry.key, deviceID: deviceID)
        report.tags = entry.context.tags
        report.filter = filter
        return report
    }

    /// The parsed `--where` tags. The usage error states the tag rule, or the clash with a name.
    static func whereTags(_ raw: [String], named: Bool) throws -> [LoginTag] {
        if named, !raw.isEmpty { throw ValidationError("Pass a name or --where, not both.") }
        return try raw.map { text in
            guard let tag = LoginTag(rawValue: text) else { throw ValidationError("--where \(LoginTag.problem(text) ?? LoginTag.rule)") }
            return tag
        }
    }

    /// The login a name, `--where` or the default picks; errors never show a username. `device` is nil for `credential status`.
    static func resolveLogin(_ name: String?, where filter: [LoginTag], app: String, entries: [LoginEntry], device: DeviceID?) throws -> LoginEntry {
        let requested = name.map { LoginKey(rawValue: $0)?.rawValue ?? $0 }
        let deviceArgument = device.map { "--device \($0.rawValue)" } ?? "--device <id>"
        let wanted = filter.map(\.rawValue).joined(separator: " ")
        switch LoginSelection.resolve(entries: entries, name: requested, where: filter) {
        case .chosen(let entry):
            return entry
        case .missing(let key):
            throw CLIError(
                errorDescription: "No login named \(LoginCredential.displayKey(key)) is saved for \(app).",
                reason: .commandFailed,
                hint: "offsider credential status --app \(app)"
            )
        case .noneSaved:
            throw CLIError(
                errorDescription: "No login credential is saved for \(app).",
                reason: .commandFailed,
                hint: device.map { "offsider credential set --device \($0.rawValue)" } ?? "offsider credential set --app \(app)"
            )
        case .noMatch(let all):
            throw CLIError(
                errorDescription: "No saved login for \(app) has every tag in --where \(wanted). Saved: \(listed(all)).",
                reason: .userNotFound,
                hint: "offsider credential status --app \(app) --json",
                users: all.map(FailureUser.init)
            )
        case .ambiguous(let matches):
            var hint = "offsider credential status --app \(app) --json"
            if let device, let refinement = LoginSelection.platformRefinement(matches, where: filter, platform: device.platform) {
                hint = "offsider login " + (filter + [refinement]).map { "--where \($0.rawValue)" }.joined(separator: " ") + " --device \(device.rawValue)"
            }
            throw CLIError(
                errorDescription: "\(matches.count) saved logins for \(app) have every tag in --where \(wanted): \(listed(matches)). Add a --where tag only one of them has, or pass its name.",
                reason: .userAmbiguous,
                hint: hint,
                users: matches.map(FailureUser.init)
            )
        case .noDefault(let all):
            let example = all.first { $0.key != LoginCredential.defaultAccountKey }?.name ?? "dev"
            throw CLIError(
                errorDescription: "Several logins are saved for \(app) (\(listed(all))) and none is the default. Pass the name or --where, for example offsider login \(example) \(deviceArgument).",
                reason: .userAmbiguous,
                hint: "offsider credential status --app \(app) --json",
                users: all.map(FailureUser.init)
            )
        }
    }

    /// Up to five logins as `name (tags · about)`, then how many more.
    private static func listed(_ entries: [LoginEntry]) -> String {
        let shown = entries.prefix(5).map(LoginSelection.line).joined(separator: "; ")
        return entries.count > 5 ? "\(shown); and \(entries.count - 5) more" : shown
    }

    /// A parsed `type` command. The placeholder `x` is replaced before anything is typed, so the secret never enters the argument list.
    static func typingCommand(text: String, field: UINode, deviceID: String) throws -> Type {
        var arguments = ["--replace"]
        if let id = field.id, !id.isEmpty {
            arguments += ["--into-id", id]
        } else if let label = field.label, !label.isEmpty {
            arguments += ["--into-label", label]
        }
        arguments += ["x", "--device", deviceID]
        var typing = try Type.parse(arguments)
        typing.text = text
        return typing
    }

    /// A parsed `turnstile` command. A bare `Turnstile()` leaves its option groups unread.
    static func turnstileCommand(timeout: TimeInterval, deviceID: String) throws -> Turnstile {
        try Turnstile.parse(["--timeout", String(timeout), "--device", deviceID])
    }

    private static func stored(app: String, key: String, foreground: String, store: any LoginCredentialStoring) throws -> LoginCredential {
        guard let credential = try store.load(app: app, key: key) else {
            throw CLIError(errorDescription: "No login credential \(LoginCredential.displayKey(key)) is saved for \(foreground).", reason: .commandFailed)
        }
        return credential
    }

    private static func phase(of status: TurnstileStatus) -> TurnstilePhase {
        switch status.state {
        case .checkbox:
            let frame = status.frame ?? UIFrame(x: 0, y: 0, width: TurnstileWidget.iosSquareSide, height: TurnstileWidget.iosSquareSide)
            return .ready(TurnstileTarget(frame: frame, logoOnRight: true))
        case .verifying:
            return .checking
        case .passed:
            return .passed
        case .challenge:
            return .visualChallenge
        case .absent:
            return .absent
        }
    }
}

extension LoginTurnstileMode: ExpressibleByArgument {}
