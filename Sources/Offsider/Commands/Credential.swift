import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

struct CredentialCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credential",
        abstract: "Save, describe, check, remove or share a test username and password for one app, and track who is signed in.",
        discussion: """
        The password is kept in your login Keychain, never in a file, an argument or Offsider's output. \
        The first login saved for an app is the default, so login with no name uses it. A name such as dev \
        or qa saves another login for that same app. The same name may be saved again for a different app, \
        and login types a credential only into an app it was saved for.

        set asks for the username or email, then the password twice, showing a dot for each character, or \
        reads two lines with --stdin. Both must be characters the keyboard can type: the username 1 to 254, \
        the password 1 to 128. When a login is already saved, a terminal shows a menu to update one or add a \
        named one, and asks before replacing a saved name. For a new login and no describe flags, it then \
        asks what the login is for and its tags, and both may be left empty. Without a terminal, pass --update \
        or a name. Save test development credentials only. Anything that can run commands as you can then \
        type them into this app.

        join links the app in front to an app that already has saved logins, so both bundle ids share them. \
        It does not ask for the password. When only one app has logins, that is the one. When several do, \
        a terminal asks, and otherwise --app names the saved app.

        describe sets a saved login's notes and tags without reading its password: --about (what it can do, \
        and when to use it), --avoid (tests it must not be used for), --state (what the account holds now), \
        and --tag or --untag, each repeatable. A note is one line of at most 200 characters with no email \
        address, and "" clears it. A tag is a word or key=value, such as credit or role=admin, and a login \
        holds at most 16. set takes the same flags. Notes and tags are not secret: status shows them.

        status with no name lists every saved login with its tags and notes, read without decrypting \
        anything, so it shows no username. status with a name also shows that login's username. status \
        --where shows the one login that login --where would choose, without its username: no match exits 2 \
        (user_not_found) and several exit 6 (user_ambiguous).

        login records which saved login it last signed in on each device. status shows where each login was \
        last signed in, and which one is signed in on --device. signed-out clears that record for the app on \
        --device after you sign out in the app itself, and exits 0 even when nothing was recorded. It needs \
        --device and takes no name. remove also clears the login's records on every device.

        Without --app, set, status, describe, remove and signed-out use the app in front on --device (or \
        OFFSIDER_DEVICE). --app names a bundle id or package when that app is not in front, and then --device \
        is not required, except by signed-out. join always reads the app in front. A physical iPhone or iPad \
        is refused when the command would read it, and by signed-out. login fills the form.

        Examples:
          offsider credential set --device DEVICE_ID
          offsider credential set dev --device DEVICE_ID
          offsider credential set qa --update --app com.example.app
          offsider credential describe qa-admin --tag role=admin --app com.example.app
          offsider credential join --device DEVICE_ID
          offsider credential status --json --app com.example.app
          offsider credential signed-out --device DEVICE_ID
        """
    )

    enum Action: String, CaseIterable {
        case set
        case status
        case describe
        case remove
        case join
        case signedOut = "signed-out"
    }

    @Argument(help: ArgumentHelp("set, status, describe, remove, join or signed-out.", valueName: "action"))
    var action: String

    @Argument(help: ArgumentHelp("The saved login's name, such as dev. Omit it to use the default login. join and signed-out do not take one.", valueName: "name"))
    var key: String?

    @Flag(name: .customLong("stdin"), help: "With set: read the username, then the password, from two lines of standard input.")
    var stdin = false

    @Flag(name: .customLong("update"), help: "With set: replace the default login, or the named one, instead of adding a login.")
    var update = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout. It never includes the password.")
    var json = false

    @Option(name: .customLong("app"), help: ArgumentHelp("For set, status, describe, remove and signed-out: the bundle id or package, when that app is not in front. For join: which saved app to share with.", valueName: "id"))
    var app: String?

    @Option(name: .customLong("about"), help: ArgumentHelp("With set or describe: what the login can do, and when to use it. \"\" clears it.", valueName: "text"))
    var about: String?

    @Option(name: .customLong("avoid"), help: ArgumentHelp("With set or describe: tests the login must not be used for. \"\" clears it.", valueName: "text"))
    var avoid: String?

    @Option(name: .customLong("state"), help: ArgumentHelp("With set or describe: what the account holds now, such as 3 items in the cart. \"\" clears it.", valueName: "text"))
    var state: String?

    @Option(name: .customLong("tag"), help: ArgumentHelp("With set or describe: add a tag, a word or key=value such as role=admin. Repeatable.", valueName: "tag"))
    var tags: [String] = []

    @Option(name: .customLong("untag"), help: ArgumentHelp("With set or describe: remove a tag. Repeatable.", valueName: "tag"))
    var untags: [String] = []

    @Flag(name: .customLong("clear-tags"), help: "With set or describe: remove every tag before --tag adds any.")
    var clearTags = false

    @Option(name: .customLong("where"), help: ArgumentHelp("With status: show the one saved login with this tag, as login --where would choose it. Repeatable. Not with a name.", valueName: "tag"))
    var filters: [String] = []

    @OptionGroup
    var device: CredentialDeviceOption

    func validate() throws {
        let parsed = try parsedAction()
        if stdin, parsed != .set { throw ValidationError("--stdin goes with set, not \(parsed.rawValue).") }
        if update, parsed != .set { throw ValidationError("--update goes with set, not \(parsed.rawValue).") }
        if let flag = contextFlags.first, parsed != .set, parsed != .describe {
            throw ValidationError("\(flag) goes with set or describe, not \(parsed.rawValue).")
        }
        if parsed == .describe, contextFlags.isEmpty {
            throw ValidationError("describe needs at least one of --about, --avoid, --state, --tag, --untag or --clear-tags.")
        }
        _ = try contextEdit()
        if !filters.isEmpty, parsed != .status { throw ValidationError("--where goes with status or login, not credential \(parsed.rawValue).") }
        _ = try LoginCommand.whereTags(filters, named: key != nil)
        if let key {
            guard parsed != .join, parsed != .signedOut else { throw ValidationError("\(parsed.rawValue) does not take a name.") }
            guard LoginKey(rawValue: key) != nil else { throw ValidationError(Self.keyMessage) }
        }
        if let app, Self.appID(app) == nil {
            throw ValidationError("--app must be a bundle id or package, such as com.example.app.")
        }
        if parsed == .join || parsed == .signedOut {
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
        let deviceID = device.resolved?.id
        if parsed == .signedOut { try Self.refuseSignedOutOnPhone(deviceID ?? "") }
        let app = try await finding(person && app == nil) { try await resolveApp() }
        let edit = try contextEdit()
        let filter = try LoginCommand.whereTags(filters, named: key != nil)
        guard parsed == .set, !stdin, isatty(STDIN_FILENO) != 0 else {
            let read = stdin ? Self.readFromStandardInput : {
                throw CLIError(errorDescription: "credential set asks for the username on a terminal. Without one, pass --stdin.", reason: .usage)
            }
            let notice = DispatchWorkItem { FileHandle.standardError.write(Data(Self.keychainWriteNotice.utf8)) }
            print(try Self.perform(
                parsed, app: app, key: key, update: update, edit: edit, where: filter, json: json, styled: styled, store: store,
                tracker: .live(), deviceID: deviceID,
                keychainWillWrite: { DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: notice) },
                keychainDidWrite: { notice.cancel() },
                warn: { print(Self.warning, to: &standardError) },
                readCredential: read
            ))
            return
        }
        print(try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved) { prompt in
            prompt.lines(CredentialScreen.header(app: app, key: key, style: prompt.style))
            let questions = TerminalCredentialQuestions(prompt: prompt)
            return try Self.perform(.set, app: app, key: key, update: update, edit: edit, json: json, styled: styled, store: store, questions: questions, readCredential: questions.credential)
        })
    }

    /// Context flags given on the command line, in the order help lists them.
    var contextFlags: [String] {
        [
            ("--about", about != nil), ("--avoid", avoid != nil), ("--state", state != nil),
            ("--tag", !tags.isEmpty), ("--untag", !untags.isEmpty), ("--clear-tags", clearTags),
        ].filter(\.1).map(\.0)
    }

    func contextEdit() throws -> LoginContextEdit {
        do {
            return try LoginContextEdit.parse(about: about, avoid: avoid, state: state, tag: tags, untag: untags, clearTags: clearTags)
        } catch let problem as LoginContextProblem {
            throw ValidationError(problem.message)
        }
    }

    /// A rebuilt offsider changing an item's attributes waits on a macOS prompt, so the wait is never timed out.
    static let keychainWriteNotice = "Waiting for macOS to let offsider change the saved login's notes and tags. Answer the Keychain prompt.\n"

    /// How a suggested command names this device: nothing when `OFFSIDER_DEVICE` already does.
    var suggestedDevice: String {
        guard let resolved = device.resolved else { return "--device <id>" }
        return resolved.source == .environment ? "" : "--device \(resolved.id)"
    }

    private func finding<T>(_ spin: Bool, _ work: () async throws -> T) async throws -> T {
        guard spin else { return try await work() }
        return try await TerminalSpinner.run("Finding the app in front…", work)
    }

    static let keyMessage = "A saved login's name is 1 to 32 characters from A-Z, a-z, 0-9, '.', '_' and '-', starting with a letter or digit, such as dev. The word default is reserved."
    static let warning = "Save test development credentials only. Anything that can run commands as you can then type them into this app. The password is never printed."

    static func appID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...256).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return trimmed
    }

    func parsedAction() throws -> Action {
        guard let parsed = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(action)'. Use set, status, describe, remove, join or signed-out.")
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

    /// `tracker` reads sign-ins for status and clears them for remove and signed-out; nil means nothing is recorded. `deviceID` is the device in hand.
    static func perform(
        _ action: Action,
        app: String,
        key: String?,
        update: Bool = false,
        edit: LoginContextEdit = LoginContextEdit(),
        where filter: [LoginTag] = [],
        json: Bool,
        styled: TerminalOutput? = nil,
        store: any LoginCredentialStoring,
        questions: (any CredentialQuestions)? = nil,
        tracker: SignInTracker? = nil,
        deviceID: String? = nil,
        now: Date = Date(),
        keychainWillWrite: () -> Void = {},
        keychainDidWrite: () -> Void = {},
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
            let entries = try store.entries(app: canonical)
            let target = try writeTarget(entries: entries, name: key, update: update, questions: questions) { try store.list(app: canonical) }
            let existing = entries.first { $0.key == target.key }
            var context = edit.isEmpty ? nil : try edited(existing?.stored ?? .saved(.empty), with: edit, key: target.key, app: app, now: now)
            if questions == nil { warn() }
            let credential = try readCredential()
            if let questions, existing == nil, edit.isEmpty {
                let asked = try questions.context()
                if !asked.isEmpty { context = try edited(.saved(.empty), with: asked, key: target.key, app: app, now: now) }
            }
            if let stamp = LoginDirectory.shouldStampDefault(entries, writing: target.key) {
                try store.markDefault(app: canonical, key: stamp)
            }
            try store.save(credential, app: canonical, key: target.key, isDefault: target.makeDefault, context: context)
            let report = CredentialReport(
                action: "set", app: app, key: target.key, username: credential.username, saved: true, isDefault: target.makeDefault, also: shared,
                context: context ?? existing?.context ?? .empty
            )
            return render(report)
        case .status:
            let entries = try store.entries(app: canonical)
            let recorded = tracker?.signIns(app: canonical) ?? [:]
            let here = deviceID.flatMap { tracker?.signedInHere(app: canonical, deviceID: $0) }
            let inHand = deviceID != nil
            if !filter.isEmpty {
                let entry = try LoginCommand.resolveLogin(nil, where: filter, app: app, entries: entries, device: nil)
                let report = CredentialReport(
                    action: "status", app: app, key: entry.key, saved: true, isDefault: entry.isDefault || entries.count == 1,
                    also: shared, context: entry.context, signIns: recorded, signedInHere: here, deviceInHand: inHand, filter: filter
                )
                return render(report)
            }
            if let key {
                guard let entry = entries.first(where: { $0.key == key }), let saved = try store.load(app: canonical, key: key) else {
                    return render(CredentialReport(action: "status", app: app, key: key, saved: false, also: shared, signedInHere: here, deviceInHand: inHand))
                }
                let report = CredentialReport(
                    action: "status", app: app, key: key, username: saved.username, saved: true, isDefault: entry.isDefault || entries.count == 1,
                    also: shared, context: entry.context, signIns: recorded, signedInHere: here, deviceInHand: inHand
                )
                return render(report)
            }
            var listed = entries
            if listed.count == 1 { listed[0].isDefault = true }
            let report = CredentialReport(
                action: "status", app: app, saved: !listed.isEmpty, listed: listed, also: shared, signIns: recorded, signedInHere: here, deviceInHand: inHand
            )
            return render(report)
        case .describe:
            let entries = try store.entries(app: canonical)
            let target = try describeTarget(entries: entries, name: key, app: app)
            guard let entry = entries.first(where: { $0.key == target }) else { throw missingLogin(target, app: app) }
            let next = try edited(entry.stored, with: edit, key: target, app: app, now: now)
            let changed = entry.stored != .saved(next)
            if changed {
                keychainWillWrite()
                defer { keychainDidWrite() }
                guard try store.setContext(next, app: canonical, key: target) else { throw missingLogin(target, app: app) }
            }
            let report = CredentialReport(
                action: "describe", app: app, key: target, saved: true, isDefault: entry.isDefault || entries.count == 1, also: shared,
                context: next, changed: changed
            )
            return render(report)
        case .remove:
            let removing = try removeTarget(entries: try store.entries(app: canonical), name: key)
            let removed = try store.remove(app: canonical, key: removing)
            tracker?.ledger.clear(app: canonical, key: removing)
            let report = CredentialReport(action: "remove", app: app, key: removing, saved: false, removed: removed, also: shared)
            return render(report)
        case .signedOut:
            guard let tracker, let deviceID else { throw CLIError(errorDescription: DeviceDefault.missingMessage, reason: .usage) }
            try refuseSignedOutOnPhone(deviceID)
            let signedOut = try tracker.signOut(app: canonical, deviceID: deviceID)
            let report = CredentialReport(
                action: "signed-out", app: app, key: signedOut.cleared?.key, saved: false, also: shared,
                device: signedOut.device, platform: signedOut.platform, cleared: signedOut.cleared != nil
            )
            return render(report)
        case .join:
            throw CLIError(errorDescription: "join is not a saved login.", reason: .usage)
        }
    }

    /// login never runs on a physical iPhone or iPad, so nothing is recorded there to clear.
    static func refuseSignedOutOnPhone(_ deviceID: String) throws {
        try CLIError.refuseOnPhone(deviceID, command: "credential signed-out", alternative: "login does not run there, so Offsider records no sign-in on it.")
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
        try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingLinked, instead: "Pass --app with the one to share instead.") { prompt in
            groups[try prompt.choose(CredentialScreen.joinTitle, options: CredentialScreen.joinOptions(groups: groups))].canonical
        }
    }

    private struct WriteTarget {
        var key: String
        var makeDefault: Bool
    }

    /// `summaries` decrypts every login for its usernames, so only a person at a terminal reaches it.
    private static func writeTarget(
        entries: [LoginEntry],
        name: String?,
        update: Bool,
        questions: (any CredentialQuestions)?,
        summaries: () throws -> [LoginCredentialSummary]
    ) throws -> WriteTarget {
        switch LoginDirectory.setIntent(entries: entries, name: name, update: update, interactive: questions != nil) {
        case .write(let key, let makeDefault):
            return WriteTarget(key: key, makeDefault: makeDefault)
        case .refused(let message):
            throw CLIError(errorDescription: message, reason: .usage)
        case .confirm(let key, let makeDefault):
            guard let questions, let entry = try summaries().first(where: { $0.key == key }), try questions.replaces(entry) else { throw PromptCancelled() }
            return WriteTarget(key: key, makeDefault: makeDefault)
        case .choose:
            guard let questions else {
                throw CLIError(errorDescription: "credential set asks for a choice on a terminal. Without one, pass --update or a name.", reason: .usage)
            }
            let listed = try summaries()
            switch try questions.loginToChange(entries: listed) {
            case .update(let key):
                let marked = listed.first { $0.key == key }?.isDefault ?? (listed.count == 1)
                return WriteTarget(key: key, makeDefault: marked)
            case .create:
                let name = try questions.newName(taken: listed.map(\.key))
                guard let parsed = LoginKey(rawValue: name), !listed.contains(where: { $0.key == parsed.rawValue }) else {
                    throw CLIError(errorDescription: "\(keyMessage) Nothing was saved.", reason: .usage)
                }
                return WriteTarget(key: parsed.rawValue, makeDefault: false)
            }
        }
    }

    /// `edit` applied to a stored context. A damaged one starts empty, and a newer Offsider's is never overwritten.
    private static func edited(_ stored: LoginContextRead, with edit: LoginContextEdit, key: String, app: String, now: Date) throws -> LoginContext {
        let base: LoginContext
        switch stored {
        case .saved(let context):
            base = context
        case .damaged:
            base = .empty
        case .newer(let version):
            throw CLIError(
                errorDescription: "The notes and tags of \(LoginCredential.displayKey(key)) for \(app) were saved by a newer Offsider (context version \(version)), so this one leaves them alone. Nothing was saved.",
                reason: .commandFailed
            )
        }
        do {
            return try edit.applied(to: base, now: now)
        } catch let problem as LoginContextProblem {
            throw CLIError(errorDescription: problem.message, reason: .usage)
        }
    }

    private static func describeTarget(entries: [LoginEntry], name: String?, app: String) throws -> String {
        if let name { return name }
        if let marked = entries.first(where: \.isDefault) { return marked.key }
        if entries.count == 1, let only = entries.first { return only.key }
        if entries.isEmpty {
            throw CLIError(errorDescription: "No login is saved for \(app), so there is nothing to describe. Nothing was changed.", reason: .commandFailed, hint: "offsider credential set --app \(app)")
        }
        let names = entries.map(\.name).joined(separator: ", ")
        throw CLIError(errorDescription: "Several logins are saved (\(names)) and none is the default. Pass the name to describe. Nothing was changed.", reason: .usage)
    }

    private static func missingLogin(_ key: String, app: String) -> CLIError {
        let argument = key == LoginCredential.defaultAccountKey ? "" : " \(key)"
        return CLIError(
            errorDescription: "No login named \(LoginCredential.displayKey(key)) is saved for \(app). Nothing was changed.",
            reason: .commandFailed,
            hint: "offsider credential set\(argument) --app \(app)"
        )
    }

    private static func removeTarget(entries: [LoginEntry], name: String?) throws -> String {
        if let name { return name }
        if let marked = entries.first(where: \.isDefault) { return marked.key }
        if entries.count == 1, let only = entries.first { return only.key }
        if entries.isEmpty { return LoginCredential.defaultAccountKey }
        let names = entries.map { LoginCredential.displayKey($0.key) }.joined(separator: ", ")
        throw CLIError(errorDescription: "Several logins are saved (\(names)). Pass the name to remove. Nothing was removed.", reason: .usage)
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
    func newName(taken: [String]) throws -> String
    func credential() throws -> LoginCredential
    /// The optional about line and tags for a new login, asked after the password.
    func context() throws -> LoginContextEdit
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

    func newName(taken: [String]) throws -> String {
        try prompt.ask(CredentialScreen.padded(CredentialScreen.nameLabel), placeholder: CredentialScreen.namePlaceholder) { CredentialScreen.nameProblem($0, taken: taken) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func credential() throws -> LoginCredential {
        let username = try prompt.ask(CredentialScreen.padded(CredentialScreen.usernameLabel), check: CredentialScreen.usernameProblem)
        let password = try prompt.askSecret(
            CredentialScreen.padded(CredentialScreen.passwordLabel), again: CredentialScreen.padded(CredentialScreen.againLabel), check: CredentialScreen.passwordProblem
        )
        return try CredentialCommand.credential(username: username, password: password)
    }

    func context() throws -> LoginContextEdit {
        let about = try prompt.ask(CredentialScreen.padded(CredentialScreen.aboutLabel), placeholder: CredentialScreen.aboutPlaceholder, check: CredentialScreen.aboutProblem)
        let tags = try prompt.ask(CredentialScreen.padded(CredentialScreen.tagsLabel), placeholder: CredentialScreen.tagsPlaceholder, check: CredentialScreen.tagsProblem)
        do {
            return try CredentialScreen.contextEdit(about: about, tags: tags)
        } catch let problem as LoginContextProblem {
            throw CLIError(errorDescription: "\(problem.message) Nothing was saved.", reason: .usage)
        }
    }
}
