import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

struct CredentialCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credential",
        abstract: "Save, check, remove or share a test username and password for one app.",
        discussion: """
        The password is kept in your login Keychain, never in a file, an argument or Offsider's output. \
        The first login saved for an app is the default, so login with no tag uses it. A tag such as dev \
        or qa names another login for that same app. The same tag may be saved again for a different app, \
        and login types a credential only into an app it was saved for.

        set asks for the username or email, then the password twice, showing a dot for each character, or \
        reads two lines with --stdin. Both must be characters the keyboard can type: the username 1 to 254, \
        the password 1 to 128. When a login is already saved, a terminal shows a menu to update one or add a \
        tagged one, and asks before replacing a saved tag. Without a terminal, pass --update or a tag. Save \
        test development credentials only. Anything that can run commands as you can then type them into this app.

        join links the app in front to an app that already has saved logins, so both bundle ids share them. \
        It does not ask for the password. When only one app has logins, that is the one. When several do, \
        a terminal asks, and otherwise --app names the saved app.

        Without --app, set, status and remove use the app in front on --device (or OFFSIDER_DEVICE). --app \
        names a bundle id or package when that app is not in front, and then --device is not required. \
        join always reads the app in front. A physical iPhone or iPad is refused when the command would \
        read it. login fills the form.

        Examples:
          offsider credential set --device DEVICE_ID
          offsider credential set dev --device DEVICE_ID
          offsider credential set qa --update --app com.example.app
          offsider credential join --device DEVICE_ID
          offsider credential status --app com.example.app
        """
    )

    enum Action: String, CaseIterable {
        case set
        case status
        case remove
        case join
    }

    @Argument(help: ArgumentHelp("set, status, remove or join.", valueName: "action"))
    var action: String

    @Argument(help: ArgumentHelp("A tag such as dev. Omit it to use the default login. join does not take one.", valueName: "tag"))
    var key: String?

    @Flag(name: .customLong("stdin"), help: "With set: read the username, then the password, from two lines of standard input.")
    var stdin = false

    @Flag(name: .customLong("update"), help: "With set: replace the default login, or the tagged one, instead of adding a login.")
    var update = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout. It never includes the password.")
    var json = false

    @Option(name: .customLong("app"), help: ArgumentHelp("For set, status and remove: the bundle id or package, when that app is not in front. For join: which saved app to share with.", valueName: "id"))
    var app: String?

    @OptionGroup
    var device: CredentialDeviceOption

    func validate() throws {
        let parsed = try parsedAction()
        if stdin, parsed != .set { throw ValidationError("--stdin goes with set, not \(parsed.rawValue).") }
        if update, parsed != .set { throw ValidationError("--update goes with set, not \(parsed.rawValue).") }
        if let key {
            guard parsed != .join else { throw ValidationError("join does not take a tag.") }
            guard LoginKey(rawValue: key) != nil else { throw ValidationError(Self.keyMessage) }
        }
        if let app, Self.appID(app) == nil {
            throw ValidationError("--app must be a bundle id or package, such as com.example.app.")
        }
        if parsed == .join {
            if device.resolved == nil { throw ValidationError(DeviceDefault.missingMessage) }
        } else if app == nil, device.resolved == nil {
            throw ValidationError(DeviceDefault.missingMessage)
        }
    }

    func run() async throws {
        let parsed = try parsedAction()
        let key = key.map { LoginKey(rawValue: $0)?.rawValue ?? $0 }
        let store = KeychainLoginCredentialStore()
        let person = isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0
        let styled = json || isatty(STDOUT_FILENO) == 0 ? nil : TerminalOutput(style: .detect(isTerminal: true), device: suggestedDevice)
        if parsed == .join {
            let foreground = try await finding(person) { try await resolveForeground() }
            let chooseApp: (([LoginAppGroup]) throws -> String)? = isatty(STDIN_FILENO) != 0 ? Self.chooseApp : nil
            print(try Self.join(foreground: foreground, requested: app.flatMap(Self.appID), json: json, styled: styled, store: store, chooseApp: chooseApp))
            return
        }
        let app = try await finding(person && app == nil) { try await resolveApp() }
        guard parsed == .set, !stdin, isatty(STDIN_FILENO) != 0 else {
            let read = stdin ? Self.readFromStandardInput : {
                throw CLIError(errorDescription: "credential set asks for the username on a terminal. Without one, pass --stdin.", reason: .usage)
            }
            print(try Self.perform(parsed, app: app, key: key, update: update, json: json, styled: styled, store: store, warn: { print(Self.warning, to: &standardError) }, readCredential: read))
            return
        }
        print(try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved) { prompt in
            prompt.lines(CredentialScreen.header(app: app, key: key, style: prompt.style))
            let questions = TerminalCredentialQuestions(prompt: prompt)
            return try Self.perform(.set, app: app, key: key, update: update, json: json, styled: styled, store: store, questions: questions, readCredential: questions.credential)
        })
    }

    /// How a suggested command names this device: nothing when `OFFSIDER_DEVICE` already does.
    var suggestedDevice: String {
        guard let resolved = device.resolved else { return "--device <id>" }
        return resolved.source == .environment ? "" : "--device \(resolved.id)"
    }

    private func finding<T>(_ spin: Bool, _ work: () async throws -> T) async throws -> T {
        guard spin else { return try await work() }
        return try await TerminalSpinner.run("Finding the app in front…", work)
    }

    static let keyMessage = "A credential tag is 1 to 32 characters from A-Z, a-z, 0-9, '.', '_' and '-', starting with a letter or digit, such as dev. The word default is reserved."
    static let warning = "Save test development credentials only. Anything that can run commands as you can then type them into this app. The password is never printed."

    static func appID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return trimmed
    }

    func parsedAction() throws -> Action {
        guard let parsed = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(action)'. Use set, status, remove or join.")
        }
        return parsed
    }

    /// The app in front. `join` uses this even when `--app` names the saved app to share with.
    func resolveForeground() async throws -> String {
        let deviceID = device.resolved?.id ?? ""
        try CLIError.refuseOnPhone(deviceID, command: "credential", alternative: "Use a simulator or an Android device.")
        return try await readForeground(deviceID)
    }

    /// The foreground app, unless `--app` named one. A physical iPhone is refused before the prompt.
    func resolveApp() async throws -> String {
        if let app, let id = Self.appID(app) { return id }
        let deviceID = device.resolved?.id ?? ""
        try CLIError.refuseOnPhone(deviceID, command: "credential", alternative: "Pass --app with the bundle id, such as com.example.app. login fills a form on a simulator or an Android device.")
        return try await readForeground(deviceID)
    }

    private func readForeground(_ deviceID: String) async throws -> String {
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        let route = try await DeviceRouter.routeForInput(deviceID, logger: logger, watchdog: watchdog, locking: false)
        return try await watchdog.guarding(setupThen: 0, device: deviceID) { ready in
            try await route.backend.prepare()
            ready()
            let tree = try await route.backend.accessibilityTree(for: route.device)
            return try ForegroundAppLookup.identifier(in: tree, forLogin: false)
        }
    }

    static func perform(
        _ action: Action,
        app: String,
        key: String?,
        update: Bool = false,
        json: Bool,
        styled: TerminalOutput? = nil,
        store: any LoginCredentialStoring,
        questions: (any CredentialQuestions)? = nil,
        warn: () -> Void = {},
        readCredential: () throws -> LoginCredential
    ) throws -> String {
        func render(_ report: CredentialReport) -> String {
            if json { return report.jsonLine() }
            guard let styled else { return report.textLine() }
            return report.styledText(style: styled.style, device: styled.device)
        }
        let canonical = try store.canonical(of: app)
        let shared = try sharedIDs(app: app, canonical: canonical, store: store)
        switch action {
        case .set:
            let entries = try store.list(app: canonical)
            let target = try writeTarget(entries: entries, tag: key, update: update, questions: questions)
            if let stamp = LoginDirectory.shouldStampDefault(entries, writing: target.key) {
                try store.markDefault(app: canonical, key: stamp)
            }
            if questions == nil { warn() }
            let credential = try readCredential()
            try store.save(credential, app: canonical, key: target.key, isDefault: target.makeDefault)
            let report = CredentialReport(action: "set", app: app, key: target.key, username: credential.username, saved: true, isDefault: target.makeDefault, also: shared)
            return render(report)
        case .status:
            if let key {
                let saved = try store.load(app: canonical, key: key)
                let marked = try store.defaultKey(app: canonical) == key
                let sole: Bool
                if marked || saved == nil {
                    sole = marked
                } else {
                    sole = try store.keys(app: canonical).count == 1
                }
                let report = CredentialReport(action: "status", app: app, key: key, username: saved?.username, saved: saved != nil, isDefault: saved != nil && sole, also: shared)
                return render(report)
            }
            var listed = try store.list(app: canonical)
            if listed.count == 1 { listed[0].isDefault = true }
            let report = CredentialReport(action: "status", app: app, saved: !listed.isEmpty, listed: listed, also: shared)
            return render(report)
        case .remove:
            let removing = try removeTarget(entries: try store.list(app: canonical), tag: key)
            let removed = try store.remove(app: canonical, key: removing)
            let report = CredentialReport(action: "remove", app: app, key: removing, saved: false, removed: removed, also: shared)
            return render(report)
        case .join:
            throw CLIError(errorDescription: "join is not a saved login.", reason: .usage)
        }
    }

    static func join(
        foreground: String,
        requested: String?,
        json: Bool,
        styled: TerminalOutput? = nil,
        store: any LoginCredentialStoring,
        chooseApp: (([LoginAppGroup]) throws -> String)? = nil
    ) throws -> String {
        let groups = try store.groups()
        let intent = LoginDirectory.joinIntent(foreground: foreground, groups: groups, requested: requested, interactive: chooseApp != nil)
        let canonical: String
        let already: Bool
        switch intent {
        case .join(let target):
            canonical = target
            already = false
        case .already(let target):
            canonical = target
            already = true
        case .choose:
            guard let chooseApp else {
                throw CLIError(errorDescription: "Several apps have saved logins. Pass --app with the one to share. Nothing was linked.", reason: .usage)
            }
            canonical = try chooseApp(groups)
            already = false
        case .refused(let message):
            throw CLIError(errorDescription: message, reason: message.contains("Pass --app") ? .usage : .commandFailed)
        }
        if !already { try store.join(member: foreground, canonical: canonical) }
        let report = CredentialReport(action: "join", app: foreground, saved: !already, linked: canonical)
        if json { return report.jsonLine() }
        return styled.map { report.styledText(style: $0.style, device: $0.device) } ?? report.textLine()
    }

    private static func chooseApp(_ groups: [LoginAppGroup]) throws -> String {
        try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingLinked) { prompt in
            groups[try prompt.choose(CredentialScreen.joinTitle, options: CredentialScreen.joinOptions(groups: groups))].canonical
        }
    }

    private struct WriteTarget {
        var key: String
        var makeDefault: Bool
    }

    private static func writeTarget(
        entries: [LoginCredentialSummary],
        tag: String?,
        update: Bool,
        questions: (any CredentialQuestions)?
    ) throws -> WriteTarget {
        switch LoginDirectory.setIntent(entries: entries, tag: tag, update: update, interactive: questions != nil) {
        case .write(let key, let makeDefault):
            return WriteTarget(key: key, makeDefault: makeDefault)
        case .refused(let message):
            throw CLIError(errorDescription: message, reason: .usage)
        case .confirm(let key, let makeDefault):
            guard let questions, let entry = entries.first(where: { $0.key == key }), try questions.replaces(entry) else { throw PromptCancelled() }
            return WriteTarget(key: key, makeDefault: makeDefault)
        case .choose:
            guard let questions else {
                throw CLIError(errorDescription: "credential set asks for a choice on a terminal. Without one, pass --update or a tag.", reason: .usage)
            }
            switch try questions.loginToChange(entries: entries) {
            case .update(let key):
                let marked = entries.first { $0.key == key }?.isDefault ?? (entries.count == 1)
                return WriteTarget(key: key, makeDefault: marked)
            case .create:
                let tag = try questions.newTag(taken: entries.map(\.key))
                guard let parsed = LoginKey(rawValue: tag), !entries.contains(where: { $0.key == parsed.rawValue }) else {
                    throw CLIError(errorDescription: "\(keyMessage) Nothing was saved.", reason: .usage)
                }
                return WriteTarget(key: parsed.rawValue, makeDefault: false)
            }
        }
    }

    private static func removeTarget(entries: [LoginCredentialSummary], tag: String?) throws -> String {
        if let tag { return tag }
        if let marked = entries.first(where: \.isDefault) { return marked.key }
        if entries.count == 1, let only = entries.first { return only.key }
        if entries.isEmpty { return LoginCredential.defaultAccountKey }
        let tags = entries.map { LoginCredential.displayKey($0.key) }.joined(separator: ", ")
        throw CLIError(errorDescription: "Several logins are saved (\(tags)). Pass the tag to remove. Nothing was removed.", reason: .usage)
    }

    private static func sharedIDs(app: String, canonical: String, store: any LoginCredentialStoring) throws -> [String] {
        let group = try store.groups().first { $0.canonical == canonical }
        var others = group?.members ?? []
        if canonical != app { others.append(canonical) }
        return others.filter { $0 != app }.sorted()
    }

    /// A username and password `type` can send. The message names neither value.
    static func credential(username: String, password: String) throws -> LoginCredential {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LoginCredential.usernameLengths.contains(name.count), TextToHIDEvents.validateText(name) else {
            throw CLIError(errorDescription: "The username or email must be 1 to 254 characters the keyboard can type. Nothing was saved.", reason: .usage)
        }
        guard LoginCredential.passwordLengths.contains(password.count), TextToHIDEvents.validateText(password) else {
            throw CLIError(errorDescription: "The password must be 1 to 128 characters the keyboard can type. Nothing was saved.", reason: .usage)
        }
        guard let credential = LoginCredential(username: name, password: password) else {
            throw CLIError(errorDescription: "The username or password cannot be typed. Nothing was saved.", reason: .usage)
        }
        return credential
    }

    static func readFromStandardInput() throws -> LoginCredential {
        guard let username = readLine(strippingNewline: true), let password = readLine(strippingNewline: true) else {
            throw CLIError(errorDescription: "Standard input must be the username, then the password, on two lines. Nothing was saved.", reason: .usage)
        }
        return try credential(username: username, password: password)
    }
}

/// `--device` without `--wait-lock`. `credential` never holds the device lock itself.
struct CredentialDeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices` (default OFFSIDER_DEVICE). Not needed with --app.", valueName: "id"))
    var explicitID: String?

    var resolved: (id: String, source: DeviceSource)? { DeviceDefault.resolve(explicit: explicitID) }
}

/// How a report looks to a person at a terminal, and how its next steps name the device.
struct TerminalOutput {
    var style: TerminalStyle
    var device: String
}

/// What `credential set` asks a person at a terminal. Tests script the answers.
protocol CredentialQuestions {
    func loginToChange(entries: [LoginCredentialSummary]) throws -> LoginSetChoice
    func replaces(_ entry: LoginCredentialSummary) throws -> Bool
    func newTag(taken: [String]) throws -> String
    func credential() throws -> LoginCredential
}

struct TerminalCredentialQuestions: CredentialQuestions {
    let prompt: TerminalPrompt

    func loginToChange(entries: [LoginCredentialSummary]) throws -> LoginSetChoice {
        let index = try prompt.choose(CredentialScreen.menuTitle(entries: entries), options: CredentialScreen.menuOptions(entries: entries))
        return LoginDirectory.setChoice(at: index, entries: entries)
    }

    func replaces(_ entry: LoginCredentialSummary) throws -> Bool {
        try prompt.choose(CredentialScreen.replaceTitle(entry), options: CredentialScreen.replaceOptions) == 0
    }

    func newTag(taken: [String]) throws -> String {
        let label = PromptScreen.labels([CredentialScreen.tagLabel])[0]
        return try prompt.ask(label, placeholder: CredentialScreen.tagPlaceholder) { CredentialScreen.tagProblem($0, taken: taken) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func credential() throws -> LoginCredential {
        let labels = PromptScreen.labels([CredentialScreen.usernameLabel, CredentialScreen.passwordLabel, CredentialScreen.againLabel])
        let username = try prompt.ask(labels[0], check: CredentialScreen.usernameProblem)
        let password = try prompt.askSecret(labels[1], again: labels[2], check: CredentialScreen.passwordProblem)
        return try CredentialCommand.credential(username: username, password: password)
    }
}
