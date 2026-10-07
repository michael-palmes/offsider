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

        With no tag, login uses the default. One saved login is the default, including one saved earlier under a tag such as dev.

        Examples:
          offsider login dev --device DEVICE_ID
          offsider login dev --project . --json --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The credential tag, such as dev. Omit it to use the default login.", valueName: "tag"))
    var key: String?

    @Option(name: .customLong("turnstile"), help: ArgumentHelp("auto (default), required or off. auto handles a widget already on screen.", valueName: "mode"))
    var turnstile: LoginTurnstileMode?

    @Option(name: .customLong("timeout"), help: ArgumentHelp("Give up after this many seconds, from 1 to 60 (default 15), while the submit button stays disabled.", valueName: "seconds"))
    var timeoutOption: Double?

    @Option(name: .customLong("project"), help: ArgumentHelp("Directory to search for offsider.login.json. Without it, the search starts at the current directory.", valueName: "path"))
    var project: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout. identity and password are the word filled, never the secret.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let defaultTimeout: Double = 15

    var timeout: Double { timeoutOption ?? Self.defaultTimeout }

    func validate() throws {
        if let key, LoginKey(rawValue: key) == nil { throw ValidationError(CredentialCommand.keyMessage) }
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
        let report = try await watchdog.guarding(setupThen: timeout * 2 + 30, device: deviceOption.id) { ready in
            try await Self.perform(on: route, profile: profile, mode: mode, key: key, timeout: timeout, logger: logger, onPrepared: ready)
        }
        print(json ? report.jsonLine() : report.textLine())
    }

    /// One lock, already held by the caller.
    @MainActor
    static func perform(
        on route: DeviceRouter.Route,
        profile: LoginProfile?,
        mode: LoginTurnstileMode,
        key requestedKey: String?,
        timeout: TimeInterval,
        logger: OffsiderLogger,
        store: any LoginCredentialStoring = KeychainLoginCredentialStore(),
        onPrepared: @Sendable () -> Void = {}
    ) async throws -> LoginReport {
        try await route.backend.prepare()
        onPrepared()
        let tree = try await route.backend.accessibilityTree(for: route.device)
        let app = try ForegroundAppLookup.identifier(in: tree, forLogin: true)
        let canonical = try store.canonical(of: app)
        let key = try resolveKey(requestedKey, app: app, canonical: canonical, device: route.device.rawValue, store: store)
        let credential = try stored(app: canonical, key: key, foreground: app, store: store)
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
        return try await LoginFlow.run(app: app, key: key, credential: credential, profile: profile, turnstile: mode, timeout: timeout, services: services)
    }

    static func resolveKey(_ key: String?, app: String, canonical: String, device: String, store: any LoginCredentialStoring) throws -> String {
        if let key, let parsed = LoginKey(rawValue: key) { return parsed.rawValue }
        if let marked = try store.defaultKey(app: canonical) { return marked }
        let keys = try store.keys(app: canonical)
        if keys.count == 1, let only = keys.first { return only }
        if keys.isEmpty {
            throw CLIError(
                errorDescription: "No login credential is saved for \(app).",
                reason: .commandFailed,
                hint: "offsider credential set --device \(device)"
            )
        }
        let shown = keys.map(LoginCredential.displayKey).joined(separator: ", ")
        let example = keys.first { $0 != LoginCredential.defaultAccountKey } ?? "dev"
        throw CLIError(
            errorDescription: "Several login credentials are saved for \(app) (\(shown)) and none is the default. Pass the tag, for example offsider login \(example) --device \(device).",
            reason: .selectorAmbiguous,
            hint: "offsider credential status --device \(device)"
        )
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
