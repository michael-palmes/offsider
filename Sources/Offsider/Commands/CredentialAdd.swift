import Foundation
import OffsiderAndroid
import OffsiderCore

/// An app `credential add` saves a login for; `platform` is known when the picker found it.
struct LoginTarget: Equatable, Sendable {
    var id: String
    var platform: DevicePlatform?
}

/// Everything `credential add` reaches outside the process when a person picks the apps; tests bind their own.
struct CredentialAddContext: Sendable {
    @TaskLocal static var current = CredentialAddContext.live

    var profile: @Sendable () -> LoginProfile?
    /// The app in front on each running simulator and emulator, never a phone.
    var frontApps: @Sendable @MainActor () async -> [(app: String, platform: DevicePlatform, device: String)]
    /// An Android phone on the allow-list now, read from the file alone so no Keychain prompt shows; `login` checks the sealed list.
    var phoneAllowed: @Sendable () -> Bool
    /// A pseudo-terminal in tests; nil opens `/dev/tty`.
    var promptDescriptor: Int32?

    static let live = CredentialAddContext(
        profile: { (try? LoginProfiles.load(project: nil, warn: { _ in })) ?? nil },
        frontApps: { await CredentialAddContext.liveFrontApps() },
        phoneAllowed: {
            let now = Date()
            let entries = (try? DevicePolicySources.store()?.load().list.entries) ?? []
            return entries.contains { $0.platform == .android && ($0.expires ?? .distantFuture) > now }
        },
        promptDescriptor: nil
    )

    /// At most four running devices, each read with one bounded shell command: `launchctl list` on a simulator, `dumpsys` on an emulator.
    @MainActor
    static func liveFrontApps() async -> [(app: String, platform: DevicePlatform, device: String)] {
        guard let rows = try? await DevicePicker.virtualDevices() else { return [] }
        var found: [(app: String, platform: DevicePlatform, device: String)] = []
        for row in DevicePickerScreen.runningDevices(rows).prefix(4) {
            let app: String?
            switch row.platform {
            case .ios:
                let listing = try? await ProcessCapture.run(executable: "/usr/bin/xcrun", arguments: ["simctl", "spawn", row.id, "launchctl", "list"], timeout: 5)
                app = listing.flatMap { $0.status == 0 ? SimLaunchctl.likelyForeground($0.stdout)?.bundleID : nil }
            case .android:
                let top = try? await AndroidBackend(log: { _, _ in }).foreground(on: DeviceID(rawValue: row.id, platform: .android)).top
                app = top?.split(separator: "/").first.map(String.init)
            }
            if let app { found.append((app, row.platform, PromptScreen.label(row.name))) }
        }
        return found
    }
}

extension CredentialCommand {
    /// `add` for several apps, or for the apps a person picks: one username and password, saved for each.
    @MainActor
    func addMany(key: String?, settings: LoginSettingsEdit, store: any LoginCredentialStoring, styled: TerminalOutput?, context: CredentialAddContext = .current) async throws {
        let console = Console.current
        let edit = try contextEdit()
        guard !stdin, isatty(STDIN_FILENO) != 0 else {
            let targets = apps.map { LoginTarget(id: $0, platform: nil) }
            if !settings.loosening.isEmpty {
                try await PersonPresence.confirm(reason: Self.looseningReason(key: key, apps: targets.map(\.id), settings: settings))
            }
            let read = stdin ? Self.readFromStandardInput : {
                throw CLIError(errorDescription: "credential add asks for the username on a terminal. Without one, pass --stdin.", reason: .usage)
            }
            console.data(try Self.performMany(
                targets, key: key, update: update, edit: edit, settings: settings, personConfirmed: !settings.loosening.isEmpty, json: json, styled: styled, store: store,
                warn: { console.line(Self.warning, person: .warning(Self.personWarning)) }, readCredential: read
            ) + "\n")
            return
        }
        let text = try await TerminalPrompt.runAsync(cancelled: PromptScreen.cancelledNothingSaved, descriptor: context.promptDescriptor) { prompt in
            prompt.lines(CredentialScreen.header(app: nil, key: key, width: prompt.width, style: prompt.style))
            let targets = apps.isEmpty
                ? try await Self.pickApps(on: prompt, context: context, store: store)
                : apps.map { LoginTarget(id: $0, platform: nil) }
            if !apps.isEmpty { prompt.lines([TerminalUI.receipt("Apps", LoginDirectory.list(targets.map(\.id)), style: prompt.style)]) }
            var phones = false
            if settings.devices == nil, targets.contains(where: { $0.platform != .ios }), context.phoneAllowed() {
                phones = try Self.askPhones(on: prompt)
            }
            let chosen = Self.settings(settings, phones: phones)
            let loosening = targets.contains { !Self.settings(chosen, for: $0).loosening.isEmpty }
            if loosening {
                let start = prompt.mark
                prompt.lines([prompt.style.dim(AllowScreen.confirm)])
                let looser = targets.map { Self.settings(chosen, for: $0) }.first { !$0.loosening.isEmpty } ?? chosen
                try await PersonPresence.confirm(reason: Self.looseningReason(key: key, apps: targets.map(\.id), settings: looser))
                prompt.rewind(to: start)
            }
            let questions = TerminalCredentialQuestions(prompt: prompt)
            if targets.count == 1 {
                return try Self.perform(
                    .set, app: targets[0].id, key: key, update: update, edit: edit, settings: Self.settings(chosen, for: targets[0]), personConfirmed: loosening,
                    json: json, styled: styled, store: store, questions: questions, readCredential: questions.credential
                )
            }
            return try Self.performMany(
                targets, key: key, update: update, edit: edit, settings: chosen, personConfirmed: loosening, json: json, styled: styled, store: store,
                questions: questions, readCredential: questions.credential
            )
        }
        console.data(text + "\n")
    }

    /// The flags' settings, with phones turned on when the person chose them.
    static func settings(_ settings: LoginSettingsEdit, phones: Bool) -> LoginSettingsEdit {
        guard phones else { return settings }
        var next = settings
        next.devices = .any
        return next
    }

    /// An iPhone never takes `login`, so an app the picker knows is iOS is never saved for phones by the phone question.
    static func settings(_ settings: LoginSettingsEdit, for target: LoginTarget) -> LoginSettingsEdit {
        guard target.platform == .ios, settings.devices == .any else { return settings }
        var next = settings
        next.devices = nil
        return next
    }

    static func looseningReason(key: String?, apps: [String], settings: LoginSettingsEdit) -> String {
        let name = key.map(LoginCredential.displayKey) ?? "default"
        return "let the saved login \(name) for \(LoginDirectory.list(apps)) \(settings.loosening.joined(separator: " and "))"
    }

    /// Asks whether the login may be typed on allowed Android phones too; leaves one receipt line.
    @MainActor
    static func askPhones(on prompt: TerminalPrompt) throws -> Bool {
        let start = prompt.mark
        let rows = [
            MenuRow(.mac, [CredentialScreen.virtualOnly], recommended: true),
            MenuRow(.android, [CredentialScreen.phonesToo, CredentialScreen.phonesDetail]),
        ]
        let index = try prompt.choose(CredentialScreen.phonesQuestion, rows: rows, keepsChoice: false)
        prompt.rewind(to: start)
        prompt.lines([TerminalUI.receipt("Where", index == 1 ? CredentialScreen.phonesReceipt : CredentialScreen.virtualReceipt, style: prompt.style)])
        return index == 1
    }

    /// The apps to save for: offsider.login.json's, those in front on running simulators and emulators, and those with logins, ticked as the picker says; typed when none fit.
    @MainActor
    static func pickApps(on prompt: TerminalPrompt, context: CredentialAddContext, store: any LoginCredentialStoring) async throws -> [LoginTarget] {
        let (profile, front, saved) = try await TerminalSpinner.run(CredentialScreen.lookingForApps, terminal: prompt.terminalDescriptor) {
            (context.profile(), await context.frontApps(), ((try? store.groups()) ?? []).flatMap { [$0.canonical] + $0.members })
        }
        let choices = LoginAppPicker.choices(profile: profile, front: front, saved: saved)
        let start = prompt.mark
        var picked: [LoginTarget] = []
        var typing = choices.isEmpty
        if !choices.isEmpty {
            let rows = choices.map(CredentialScreen.appRow) + [MenuRow(.type, [CredentialScreen.typeApps])]
            let ticked = Set(choices.indices.filter { choices[$0].ticked })
            let indices = try prompt.chooseMany(CredentialScreen.appsQuestion, rows: rows, ticked: ticked)
            picked = indices.filter { $0 < choices.count }.map { LoginTarget(id: choices[$0].id, platform: choices[$0].platform) }
            typing = picked.isEmpty || indices.contains(choices.count)
        }
        if typing {
            let have = picked.map(\.id)
            let answer = try prompt.ask(
                CredentialScreen.padded(CredentialScreen.appsLabel), placeholder: CredentialScreen.appsPlaceholder
            ) { CredentialScreen.appsProblem($0, have: have) }
            for id in LoginAppPicker.typed(answer) where !picked.contains(where: { $0.id == id }) {
                picked.append(LoginTarget(id: id, platform: nil))
            }
        }
        prompt.rewind(to: start)
        prompt.lines([TerminalUI.receipt("Apps", LoginDirectory.list(picked.map(\.id)), style: prompt.style)])
        return picked
    }

    /// One login saved for every app in `targets`, named once; an app already linked to another is saved through that one.
    static func performMany(
        _ targets: [LoginTarget],
        key: String?,
        update: Bool = false,
        edit: LoginContextEdit = LoginContextEdit(),
        settings: LoginSettingsEdit = LoginSettingsEdit(),
        personConfirmed: Bool = false,
        json: Bool,
        styled: TerminalOutput? = nil,
        store: any LoginCredentialStoring,
        questions: (any SharedCredentialQuestions)? = nil,
        now: Date = Date(),
        warn: () -> Void = {},
        readCredential: () throws -> LoginCredential
    ) throws -> String {
        let key = key.map { storedKey($0) ?? $0 }
        if targets.contains(where: { !Self.settings(settings, for: $0).loosening.isEmpty }), !personConfirmed {
            throw CLIError.personRequired(
                "Letting a saved login \(settings.loosening.joined(separator: " and ")) needs a person at a terminal with Touch ID or the login password. Nothing was saved.",
                hint: "offsider credential add"
            )
        }
        for target in targets { try refuseSaving(target.id, platform: target.platform) }
        var apps: [(target: LoginTarget, canonical: String, entries: [LoginEntry])] = []
        for target in targets {
            let canonical = try store.canonical(of: target.id)
            if let index = apps.firstIndex(where: { $0.canonical == canonical }) {
                // One save serves both linked ids, so it takes settings meant for either platform.
                if apps[index].target.platform != target.platform { apps[index].target.platform = nil }
                continue
            }
            apps.append((target, canonical, try store.entries(app: canonical)))
        }
        let marks = apps.map { (app: $0.canonical, entries: $0.entries as [any LoginMark]) }
        var intent = LoginDirectory.sharedSetIntent(apps: marks, name: key, update: update, interactive: questions != nil)
        let writes: [LoginSharedWrite]
        while true {
            switch intent {
            case .write(let planned):
                writes = planned
            case .refused(let message):
                throw CLIError(errorDescription: message, reason: .usage)
            case .confirm(let name, let holding):
                guard let questions, try questions.replacesShared(key: name, apps: holding) else { throw PromptCancelled() }
                intent = LoginDirectory.sharedSetIntent(apps: marks, name: name, update: true, interactive: true)
                continue
            case .choose(let names):
                guard let questions else { throw CLIError(errorDescription: "credential add asks for a choice on a terminal. Without one, pass --update or a name.", reason: .usage) }
                switch try questions.sharedLoginToChange(names) {
                case .update(let name):
                    intent = LoginDirectory.sharedSetIntent(apps: marks, name: name, update: true, interactive: true)
                case .create:
                    let typed = try questions.newName(taken: names.map(\.key))
                    guard let parsed = LoginKey(rawValue: typed), !names.contains(where: { $0.key == parsed.rawValue }) else {
                        throw CLIError(errorDescription: "\(keyMessage) Nothing was saved.", reason: .usage)
                    }
                    intent = LoginDirectory.sharedSetIntent(apps: marks, name: parsed.rawValue, update: false, interactive: true)
                }
                continue
            }
            break
        }
        if questions == nil { warn() }
        let credential = try readCredential()
        var asked = LoginContextEdit()
        if let questions, edit.isEmpty, !writes.contains(where: \.replaces) { asked = try questions.context() }
        var reports: [CredentialReport] = []
        for (write, app) in zip(writes, apps) {
            let existing = app.entries.first { $0.key == write.key }
            var context: LoginContext?
            if !edit.isEmpty {
                context = try edited(existing?.stored ?? .saved(.empty), with: edit, key: write.key, app: app.target.id, now: now)
            } else if !asked.isEmpty {
                context = try edited(.saved(.empty), with: asked, key: write.key, app: app.target.id, now: now)
            }
            let next: StoredLogin
            do {
                if let stamp = write.stampDefault { try store.markDefault(app: app.canonical, key: stamp) }
                let base = try settingsBase(for: credential, key: write.key, existing: existing, entries: app.entries, app: app.canonical, store: store)
                next = Self.settings(settings, for: app.target).applied(to: base)
                if let mirrored = mirrored(context, existing: existing, stored: next) { context = mirrored }
                try store.saveStored(next, app: app.canonical, key: write.key, isDefault: write.makeDefault, context: context)
            } catch where !reports.isEmpty {
                throw CLIError(
                    errorDescription: "\(DeviceAccessAllow.reason(error)). The login was saved for \(LoginDirectory.list(reports.map(\.app))) only; run add again for the rest.",
                    reason: .commandFailed
                )
            }
            reports.append(CredentialReport(
                action: "set", app: app.target.id, key: write.key, username: credential.username, saved: true, isDefault: write.makeDefault,
                also: try sharedIDs(app: app.target.id, canonical: app.canonical, store: store), context: context ?? existing?.context ?? .empty
            ))
        }
        if json { return reports.map { UntrustedPaths.appending(untrustedPaths($0), to: $0.jsonLine()) }.joined(separator: "\n") }
        if let styled { return CredentialReport.styledSaved(reports, style: styled.style, device: styled.device) }
        return reports.map { $0.textLine() }.joined(separator: "\n")
    }
}

/// The two questions a login saved for several apps adds to `CredentialQuestions`. Tests script the answers.
protocol SharedCredentialQuestions: CredentialQuestions {
    func sharedLoginToChange(_ names: [LoginSharedName]) throws -> LoginSetChoice
    func replacesShared(key: String, apps: [String]) throws -> Bool
}

extension TerminalCredentialQuestions: SharedCredentialQuestions {
    func sharedLoginToChange(_ names: [LoginSharedName]) throws -> LoginSetChoice {
        let index = try prompt.choose(CredentialScreen.menuTitle(entries: []), options: CredentialScreen.sharedMenuOptions(names))
        return names.indices.contains(index) ? .update(key: names[index].key) : .create
    }

    func replacesShared(key: String, apps: [String]) throws -> Bool {
        try prompt.choose(CredentialScreen.replaceSharedTitle(key: key), options: CredentialScreen.replaceOptions) == 0
    }
}
