import Foundation
import OffsiderCore

/// Fills a sign-in form, settles Turnstile, and taps submit once. The secret stays in the injected type call.
@MainActor
enum LoginFlow {
    struct Services {
        var readTree: () async throws -> UITree
        var typeText: (_ text: String, _ field: UINode) async throws -> Void
        var tap: (_ point: UIPoint, _ tree: UITree) async throws -> Void
        var readTurnstile: () async throws -> TurnstilePhase
        var performTurnstile: () async throws -> TurnstileReport
        /// Optional extra dismiss after a tap above the keys. The login command leaves this empty: Back can leave the sign-in screen.
        var hideKeyboard: () async throws -> Void = {}
        var clock: PollClock
    }

    static func run(
        app: String,
        key: String,
        credential: LoginCredential,
        profile: LoginProfile?,
        turnstile: LoginTurnstileMode,
        timeout: TimeInterval,
        services: Services
    ) async throws -> LoginReport {
        if let profile, !profile.isFor(app) {
            throw CLIError(
                errorDescription: "offsider.login.json is for \(profile.appIDs.joined(separator: " and ")), and the app in front is \(app). Nothing was typed.",
                reason: .commandFailed
            )
        }
        var tree = try await services.readTree()
        tree = try await revealSubmit(in: tree, profile: profile, services: services)
        let form = try detect(in: tree, profile: profile, afterTyping: false)
        try requireName(form.identity, what: "email or username")
        try requireName(form.password, what: "password")
        try await type(credential.username, into: form.identity, services: services)
        tree = try await services.readTree()
        guard let identity = LoginForm.match(form.identity, in: tree) else {
            throw CLIError(
                errorDescription: "The email or username field left the screen. The password was not typed.",
                reason: .selectorNotFound
            )
        }
        guard identity.value == credential.username else {
            throw CLIError(
                errorDescription: "The email or username field did not keep the username that was typed. The password was not typed.",
                reason: .textNotAccepted
            )
        }
        try await type(credential.password, into: form.password, services: services)
        tree = try await services.readTree()
        guard let password = LoginForm.match(form.password, in: tree) else {
            throw CLIError(
                errorDescription: "The password field left the screen. The submit button was not tapped.",
                reason: .selectorNotFound
            )
        }
        guard masked(password.value, length: credential.password.count) else {
            throw CLIError(
                errorDescription: "The password field did not show one bullet per character. The submit button was not tapped.",
                reason: .textNotAccepted
            )
        }
        let submitNow = LoginForm.match(form.submit, in: tree) ?? form.submit
        tree = try await dismissKeyboard(in: tree, submit: submitNow, shell: form.turnstileShell, services: services)
        let filled = try detect(in: tree, profile: profile, afterTyping: true)
        let step = try await LoginTurnstileRunner.settle(mode: turnstile, read: services.readTurnstile, perform: services.performTurnstile)
        return try await waitUntilEnabled(filled.submit, app: app, key: key, turnstile: step, timeout: timeout, services: services)
    }

    private static func detect(in tree: UITree, profile: LoginProfile?, afterTyping: Bool) throws -> LoginForm.Found {
        do {
            return try LoginForm.detect(in: tree, profile: profile)
        } catch let error as LoginFormError {
            if afterTyping {
                let reason: FailureReason = error.kind == .ambiguous ? .selectorAmbiguous : .selectorNotFound
                throw CLIError(
                    errorDescription: "The form changed after the fields were filled. The submit button was not tapped.",
                    reason: reason
                )
            }
            let reason: FailureReason = error.kind == .ambiguous ? .selectorAmbiguous : .selectorNotFound
            throw CLIError(errorDescription: error.message, reason: reason)
        }
    }

    private static func requireName(_ field: UINode, what: String) throws {
        let hasID = field.id?.isEmpty == false
        let hasLabel = field.label?.isEmpty == false
        guard hasID || hasLabel else {
            throw CLIError(
                errorDescription: "The \(what) field has no id or label, so it cannot be typed into. Nothing was typed.",
                reason: .selectorNotFound
            )
        }
    }

    private static func type(_ text: String, into field: UINode, services: Services) async throws {
        try await services.typeText(text, field)
    }

    private static func masked(_ value: String?, length: Int) -> Bool {
        guard let value, value.count == length, length > 0 else { return false }
        return value.allSatisfy { $0 == SecureText.bullet }
    }

    /// The keys can be the only nodes below the password, so the submit button is missing until the keyboard goes.
    private static func revealSubmit(in tree: UITree, profile: LoginProfile?, services: Services) async throws -> UITree {
        if (try? LoginForm.detect(in: tree, profile: profile)) != nil { return tree }
        guard LoginForm.credentialsAreVisible(in: tree, profile: profile), keyboardOnScreen(keyboards(in: tree), in: tree) else {
            return tree
        }
        var current = tree
        let gone: (UITree) -> Bool = { !keyboardOnScreen(keyboards(in: $0), in: $0) }
        if let point = KeyboardDismiss.point(in: tree) {
            try await services.tap(point, tree)
            current = try await readUntil(gone, services: services)
        }
        if !gone(current) {
            try await services.hideKeyboard()
            current = try await readUntil(gone, services: services)
        }
        return current
    }

    static let keyboardSettle: TimeInterval = 1.5

    /// The keys can still be sliding away when the tree is read straight after a dismiss.
    private static func readUntil(_ done: (UITree) -> Bool, services: Services) async throws -> UITree {
        let deadline = services.clock.now() + keyboardSettle
        while true {
            let tree = try await services.readTree()
            if done(tree) || services.clock.now() >= deadline { return tree }
            try await services.clock.sleep(.milliseconds(250))
        }
    }

    private static func keyboards(in tree: UITree) -> [UINode] {
        tree.roots.flatMap { $0.flattened() }.filter { $0.role == .keyboard && ($0.frame?.height ?? 0) > 0 }
    }

    private static func dismissKeyboard(in tree: UITree, submit: UINode, shell: UIFrame?, services: Services) async throws -> UITree {
        let keyboards = keyboards(in: tree)
        guard !keyboards.isEmpty else { return tree }
        let submitNow = LoginForm.match(submit, in: tree) ?? submit
        // A keyboard whose frame is below the screen is the input assistant's layout, not keys over the form.
        if !keyboardOnScreen(keyboards, in: tree), !covered(tree, submit: submitNow, shell: shell) {
            return tree
        }
        var current = tree
        let clear: (UITree) -> Bool = { !covered($0, submit: LoginForm.match(submit, in: $0) ?? submitNow, shell: shell) }
        if let point = KeyboardDismiss.point(in: tree) {
            try await services.tap(point, tree)
            current = try await readUntil(clear, services: services)
            if clear(current) { return current }
        }
        if !clear(current) {
            try await services.hideKeyboard()
            current = try await readUntil(clear, services: services)
            if !clear(current) { throw keyboardError() }
        }
        return current
    }

    private static func keyboardOnScreen(_ keyboards: [UINode], in tree: UITree) -> Bool {
        guard let viewport = tree.viewport else { return true }
        return keyboards.contains { $0.frame?.isVisible(in: viewport) == true }
    }

    private static func covered(_ tree: UITree, submit: UINode, shell: UIFrame?) -> Bool {
        if let frame = submit.frame, KeyboardDismiss.covers(frame.center, in: tree) { return true }
        if let shell, KeyboardDismiss.covers(shell.center, in: tree) { return true }
        return false
    }

    private static func keyboardError() -> CLIError {
        CLIError(
            errorDescription: "The keyboard covers the next control, so Turnstile was not checked and the submit button was not tapped.",
            reason: .targetUnderKeyboard
        )
    }

    private static func waitUntilEnabled(
        _ sample: UINode,
        app: String,
        key: String,
        turnstile: LoginTurnstileStep,
        timeout: TimeInterval,
        services: Services
    ) async throws -> LoginReport {
        let deadline = services.clock.now() + timeout
        while true {
            let tree = try await services.readTree()
            guard let submit = LoginForm.match(sample, in: tree), let frame = submit.frame else {
                throw CLIError(
                    errorDescription: "The form changed after the fields were filled. The submit button was not tapped.",
                    reason: .selectorNotFound
                )
            }
            if submit.enabled != false {
                try await services.tap(frame.center, tree)
                let label = submit.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = (label?.isEmpty == false) ? label : nil
                return LoginReport(app: app, key: key, turnstile: turnstile, submitLabel: shown)
            }
            if services.clock.now() >= deadline {
                throw CLIError(
                    errorDescription: "The submit button stayed disabled after \(seconds(timeout)). It was not tapped.",
                    reason: .conditionNotMet
                )
            }
            try await services.clock.sleep(.milliseconds(250))
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded.rounded() == rounded ? String(Int(rounded)) : String(rounded)
        return "\(text) s"
    }
}

/// Applies `LoginTurnstile.plan` with one re-read, and one more checkbox tap when a reload put the box back.
@MainActor
enum LoginTurnstileRunner {
    static func settle(
        mode: LoginTurnstileMode,
        read: () async throws -> TurnstilePhase,
        perform: () async throws -> TurnstileReport
    ) async throws -> LoginTurnstileStep {
        if mode == .off { return .off }
        let phase = try await read()
        switch LoginTurnstile.plan(phase: phase, mode: mode) {
        case .done(let step):
            return step
        case .challenge:
            throw challenge()
        case .ambiguous(let count):
            throw ambiguous(count)
        case .waitForWidget:
            let first = try await perform()
            let again = try await read()
            switch LoginTurnstile.plan(phase: again, mode: mode) {
            case .done(let step):
                return first.outcome == .tapped ? .tapped : step
            case .challenge:
                throw challenge()
            case .ambiguous(let count):
                throw ambiguous(count)
            case .waitForWidget:
                if case .ready = again {
                    let second = try await perform()
                    return first.outcome == .tapped || second.outcome == .tapped ? .tapped : .passed
                }
                if case .checking = again {
                    throw CLIError(
                        errorDescription: "The Turnstile widget was still checking. The submit button was not tapped.",
                        reason: .conditionNotMet
                    )
                }
                return first.outcome == .tapped ? .tapped : .passed
            }
        }
    }

    private static func challenge() -> CLIError {
        CLIError(
            errorDescription: "The Turnstile widget is showing a visual challenge. A tap on the checkbox cannot complete it. The submit button was not tapped.",
            reason: .turnstileChallenge
        )
    }

    private static func ambiguous(_ count: Int) -> CLIError {
        CLIError(
            errorDescription: "\(count) Turnstile checkboxes are on screen. The submit button was not tapped.",
            reason: .selectorAmbiguous
        )
    }
}
