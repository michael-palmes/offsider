import Foundation
import OffsiderCore

extension LoginFlow {
    /// Types the saved password into at most two password fields, or the saved email or username into one text field, in `app`. Never taps a button, presses Return or reads a password back.
    static func fill(
        _ target: LoginFillTarget,
        app: String,
        key: String,
        credential: LoginCredential,
        profile: LoginProfile?,
        webLogin: Bool = false,
        intoID: String?,
        replace: Bool,
        services: Services
    ) async throws -> LoginFillReport {
        if let profile, !profile.isFor(app) {
            throw CLIError(
                errorDescription: "offsider.login.json is for \(profile.appIDs.joined(separator: " and ")), and the app in front is \(app). Nothing was typed.",
                reason: .commandFailed
            )
        }
        var tree = try await services.readTree()
        let (fields, revealed) = try await fillTargets(target, intoID: intoID, replace: replace, in: tree, services: services)
        let origin = LoginForm.Origin(foreground: app, bundleForPID: services.bundleForPID)
        for field in fields { try refuseWebField(field, in: tree, origin: origin, app: app, key: key, profile: profile, webLogin: webLogin) }
        var report = LoginFillReport(app: app, key: key, target: target, fields: fields.map { LoginFillField(name: LoginFill.name($0)) })
        do {
            for (index, sample) in fields.enumerated() {
                let stopped = index == 0 ? "nothing was typed" : "\(fields[index...].map(LoginFill.name).joined(separator: " and ")) \(fields.count - index == 1 ? "was" : "were") not filled"
                try services.refuseRecording()
                try requireForeground(app, in: tree, services: services, stopped: stopped)
                if target == .password { tree = try await hideKeysForFocusProof(in: tree, fields: fields, services: services) }
                // The screen can change between fields, so each is found and judged again just before it is typed into.
                guard let field = LoginForm.match(sample, in: tree) else {
                    throw CLIError(errorDescription: "\(LoginFill.name(sample)) left the screen, so \(stopped).", reason: .selectorNotFound)
                }
                if target == .password { try refusing { try LoginFill.refuseRevealed(in: tree, revealed: revealed) } }
                try refusing { try LoginFill.check(field, target, replace: replace, revealed: revealed) }
                try refuseWebField(field, in: tree, origin: origin, app: app, key: key, profile: profile, webLogin: webLogin)
                try requireForeground(app, in: tree, services: services, stopped: stopped)
                services.step("typing the \(target.fieldName) \(LoginFill.name(field))", false)
                switch target {
                case .password:
                    let length = credential.password.count
                    try await InputSecrecy.$isSecret.withValue(true) {
                        try await services.typeText(credential.password, field)
                    }
                    tree = try await readUntil({ LoginForm.match(field, in: $0).map { masked($0.value, length: length) } == true }, services: services)
                    guard let now = LoginForm.match(field, in: tree) else {
                        throw CLIError(errorDescription: "\(LoginFill.name(field)) left the screen after typing.", reason: .selectorNotFound)
                    }
                    guard masked(now.value, length: length) else {
                        throw CLIError(errorDescription: "\(LoginFill.name(field)) did not show one bullet per character.", reason: .textNotAccepted)
                    }
                case .identity:
                    try await services.typeText(credential.username, field)
                    tree = try await readUntil({ LoginForm.match(field, in: $0)?.value == credential.username }, services: services)
                    guard LoginForm.match(field, in: tree)?.value == credential.username else {
                        throw CLIError(errorDescription: "\(LoginFill.name(field)) did not keep the email or username that was typed.", reason: .textNotAccepted)
                    }
                }
                report.fields[index].progress = .filled
            }
            if let prompt = await services.savePrompt(tree) {
                report.savePrompt = try await settleAfterFill(prompt, in: tree, services: services)
            }
        } catch {
            throw LoginFillFailure(report: report, underlying: error)
        }
        return report
    }

    /// The fields a fill would type into on `tree`, hit-testing those the tree cannot place, or the refusal. `login` runs it once before the Keychain is read, so a screen it would refuse costs no Touch ID.
    static func fillTargets(
        _ target: LoginFillTarget, intoID: String?, replace: Bool, in tree: UITree, services: Services
    ) async throws -> (fields: [UINode], revealed: RevealedSecrets?) {
        var hits = HitTests()
        await hits.read(LoginFill.unsettled(target, in: tree, intoID: intoID), services: services)
        let revealed = await services.revealedSecrets()
        let fields = try refusing { try LoginFill.fields(target, in: tree, intoID: intoID, replace: replace, reachable: hits.reachable, revealed: revealed) }
        return (fields, revealed)
    }

    /// A field inside a web view takes the secret only when both the project file and the saved login opt in, as `login` asks of a sign-in form.
    private static func refuseWebField(
        _ field: UINode, in tree: UITree, origin: LoginForm.Origin, app: String, key: String, profile: LoginProfile?, webLogin: Bool
    ) throws {
        guard LoginForm.webContainer(of: field, in: tree, origin: origin) != nil, !(profile?.webLogin == true && webLogin) else { return }
        let name = key == LoginCredential.defaultAccountKey ? "default" : key
        throw CLIError(
            errorDescription: "\(LoginFill.name(field)) is inside a web view; nothing was typed. A person can allow web sign-in for this login with "
                + "`offsider credential describe \(name) --web-login --app \(app)` in their own terminal, together with \"webLogin\": true in offsider.login.json.",
            reason: .appNotAllowed
        )
    }

    /// Declines a save-password prompt where no person's saved passwords are at stake; anything else stops the command with the prompt left for a person.
    private static func settleAfterFill(_ prompt: SavePrompt, in tree: UITree, services: Services) async throws -> SavePromptOutcome {
        var why = prompt.savesPassword ? "Offsider found no decline control on it, and never taps Save." : "Offsider answers only a save-password prompt, and only by declining it."
        if !services.declinesPrompts {
            why = "On a phone in personal use that prompt is the person's to answer, so Offsider tapped nothing."
        } else if prompt.savesPassword, let point = prompt.decline {
            try await services.tap(point, tree)
            if await promptClosed(within: promptLeaves, interval: afterSubmitInterval, services: services) { return .declined }
            why = "Offsider tapped \(prompt.declineLabel ?? "its decline control") and the prompt stayed."
        }
        await services.noteDevice()
        throw CLIError(
            errorDescription: "The fields were filled, and then \(prompt.summary) came up over the app. \(why) Nothing was submitted.",
            reason: .systemPromptInFront,
            hint: CommandScope.current.describeHint(device: services.device),
            ask: prompt.ask
        )
    }

    /// A refusal from the field rules, as the error every command reports: exit 6 for an ambiguous screen, else 2 for a missing field or 3 for one it will not use.
    private static func refusing<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let refusal as LoginFillRefusal {
            let reason: FailureReason
            switch refusal.kind {
            case .missing, .unnamed: reason = .selectorNotFound
            case .ambiguous, .tooMany: reason = .selectorAmbiguous
            case .visible, .unreadable, .revealed: reason = .secretWouldShow
            case .holdsText: reason = .fieldNotEmpty
            }
            throw CLIError(errorDescription: refusal.message, reason: reason)
        }
    }
}

/// A fill that stopped: `report` says which fields were filled before it did.
struct LoginFillFailure: LocalizedError, UserFacingError, OffsiderFailure {
    var report: LoginFillReport
    let underlying: any Error

    private var failure: (any OffsiderFailure)? { underlying as? any OffsiderFailure }

    var reason: FailureReason { failure?.reason ?? ErrorReporter.payload(for: underlying).reason }
    var failureMessage: String {
        let message = failure?.failureMessage ?? OffsiderCommand.message(for: underlying)
        return report.progressNote.map { "\(message) \($0)" } ?? message
    }
    var hint: String? { failure?.hint }
    var ask: String? { failure?.ask }
    var candidates: [FailureCandidate] { failure?.candidates ?? [] }
    var coveredBy: CoverReport? { failure?.coveredBy }
    var users: [FailureUser] { failure?.users ?? [] }
    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
