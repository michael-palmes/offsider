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

        set asks for the username or email, then the password twice with typing hidden, or reads two lines \
        with --stdin. Both must be characters the keyboard can type: the username 1 to 254, the password \
        1 to 128. When a login is already saved, a terminal asks whether to update one or create a tagged \
        one. Without a terminal, pass --update or a tag. Save test development credentials only. Anything \
        that can run commands as you can then type them into this app.

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
        if parsed == .join {
            let foreground = try await resolveForeground()
            print(try Self.join(foreground: foreground, requested: app.flatMap(Self.appID), interactive: isatty(STDIN_FILENO) != 0, json: json, store: store, choose: Self.readAnswer))
            return
        }
        let app = try await resolveApp()
        let interactive = !stdin && isatty(STDIN_FILENO) != 0
        let read = stdin ? Self.readFromStandardInput : { try Self.ask(app: app, key: key) }
        print(try Self.perform(parsed, app: app, key: key, update: update, interactive: interactive, json: json, store: store, warn: { print(Self.warning, to: &standardError) }, choose: Self.readAnswer, readCredential: read))
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
        interactive: Bool = false,
        json: Bool,
        store: any LoginCredentialStoring,
        warn: () -> Void = {},
        choose: (String) throws -> String = { _ in
            throw CLIError(errorDescription: "credential set asks for a choice on a terminal. Without one, pass --update or a tag.", reason: .usage)
        },
        readCredential: () throws -> LoginCredential
    ) throws -> String {
        let canonical = try store.canonical(of: app)
        let shared = try sharedIDs(app: app, canonical: canonical, store: store)
        switch action {
        case .set:
            let entries = try store.list(app: canonical)
            let target = try writeTarget(entries: entries, tag: key, update: update, interactive: interactive, app: app, choose: choose)
            if let stamp = LoginDirectory.shouldStampDefault(entries, writing: target.key) {
                try store.markDefault(app: canonical, key: stamp)
            }
            warn()
            let credential = try readCredential()
            try store.save(credential, app: canonical, key: target.key, isDefault: target.makeDefault)
            let report = CredentialReport(action: "set", app: app, key: target.key, username: credential.username, saved: true, isDefault: target.makeDefault, also: shared)
            return json ? report.jsonLine() : report.textLine()
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
                return json ? report.jsonLine() : report.textLine()
            }
            var listed = try store.list(app: canonical)
            if listed.count == 1 { listed[0].isDefault = true }
            let report = CredentialReport(action: "status", app: app, saved: !listed.isEmpty, listed: listed, also: shared)
            return json ? report.jsonLine() : report.textLine()
        case .remove:
            let removing = try removeTarget(entries: try store.list(app: canonical), tag: key)
            let removed = try store.remove(app: canonical, key: removing)
            let report = CredentialReport(action: "remove", app: app, key: removing, saved: false, removed: removed, also: shared)
            return json ? report.jsonLine() : report.textLine()
        case .join:
            throw CLIError(errorDescription: "join is not a saved login.", reason: .usage)
        }
    }

    static func join(
        foreground: String,
        requested: String?,
        interactive: Bool,
        json: Bool,
        store: any LoginCredentialStoring,
        choose: (String) throws -> String
    ) throws -> String {
        let groups = try store.groups()
        let intent = LoginDirectory.joinIntent(foreground: foreground, groups: groups, requested: requested, interactive: interactive)
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
            let answer = try choose(LoginDirectory.joinMenu(groups: groups))
            guard let target = LoginDirectory.interpretJoinChoice(answer, groups: groups) else {
                throw CLIError(errorDescription: "Type the number of the saved app. Nothing was linked.", reason: .usage)
            }
            canonical = target
            already = false
        case .refused(let message):
            throw CLIError(errorDescription: message, reason: message.contains("Pass --app") ? .usage : .commandFailed)
        }
        if !already { try store.join(member: foreground, canonical: canonical) }
        let report = CredentialReport(action: "join", app: foreground, saved: !already, linked: canonical)
        return json ? report.jsonLine() : report.textLine()
    }

    private struct WriteTarget {
        var key: String
        var makeDefault: Bool
    }

    private static func writeTarget(
        entries: [LoginCredentialSummary],
        tag: String?,
        update: Bool,
        interactive: Bool,
        app: String,
        choose: (String) throws -> String
    ) throws -> WriteTarget {
        switch LoginDirectory.setIntent(entries: entries, tag: tag, update: update, interactive: interactive) {
        case .write(let key, let makeDefault):
            return WriteTarget(key: key, makeDefault: makeDefault)
        case .refused(let message):
            throw CLIError(errorDescription: message, reason: .usage)
        case .choose:
            let answer = try choose(LoginDirectory.setMenu(app: app, entries: entries))
            switch LoginDirectory.interpretSetChoice(answer, entries: entries) {
            case .update(let key):
                let marked = entries.first { $0.key == key }?.isDefault ?? (entries.count == 1)
                return WriteTarget(key: key, makeDefault: marked)
            case .create:
                let tag = try choose("Tag for the new login, such as qa: ")
                guard let parsed = LoginKey(rawValue: tag) else {
                    throw CLIError(errorDescription: "\(keyMessage) Nothing was saved.", reason: .usage)
                }
                if entries.contains(where: { $0.key == parsed.rawValue }) {
                    throw CLIError(errorDescription: "The tag \(parsed.rawValue) is already saved for this app. Nothing was saved.", reason: .usage)
                }
                return WriteTarget(key: parsed.rawValue, makeDefault: false)
            case nil:
                let hint = entries.count == 1 ? "Type u or n." : "Type a number or n."
                throw CLIError(errorDescription: "\(hint) Nothing was saved.", reason: .usage)
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

    private static func readAnswer(_ prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIError(errorDescription: "credential set asks for a choice on a terminal. Without one, pass --update or a tag.", reason: .usage)
        }
        FileHandle.standardError.write(Data(prompt.utf8))
        guard let line = readLine(strippingNewline: true) else {
            throw CLIError(errorDescription: "Nothing was saved.", reason: .usage)
        }
        return line
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

    /// The username is visible. The password is asked twice with echo off, and the buffers are wiped.
    static func ask(app: String, key: String?) throws -> LoginCredential {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIError(errorDescription: "credential set asks for the username on a terminal. Without one, pass --stdin.", reason: .usage)
        }
        let which = key.map { " tag \(LoginCredential.displayKey($0))" } ?? ""
        FileHandle.standardError.write(Data("Username or email for \(app)\(which): ".utf8))
        guard let username = readLine(strippingNewline: true) else {
            throw CLIError(errorDescription: "credential set asks for the username on a terminal. Without one, pass --stdin.", reason: .usage)
        }
        let password = try prompt("Password (typing is hidden): ")
        guard try prompt("Type it again: ") == password else {
            throw CLIError(errorDescription: "The two passwords differ. Nothing was saved.", reason: .usage)
        }
        return try credential(username: username, password: password)
    }

    private static func prompt(_ text: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let line = readpassphrase(text, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            let message = errno == ENOTTY
                ? "credential set asks for the password on a terminal. Without one, pass --stdin."
                : "Could not read the password: \(String(cString: strerror(errno))). Nothing was saved."
            throw CLIError(errorDescription: message, reason: .usage)
        }
        return String(cString: line)
    }
}

/// `--device` without `--wait-lock`. `credential` never holds the device lock itself.
struct CredentialDeviceOption: ParsableArguments {
    @Option(name: .customLong("device"), help: ArgumentHelp("The device ID from `offsider list-devices` (default OFFSIDER_DEVICE). Not needed with --app.", valueName: "id"))
    var explicitID: String?

    var resolved: (id: String, source: DeviceSource)? { DeviceDefault.resolve(explicit: explicitID) }
}
