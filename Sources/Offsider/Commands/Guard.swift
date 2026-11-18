import ArgumentParser
import Foundation
import OffsiderCore

struct GuardCommand: AsyncParsableCommand, AppNaming {
    static let configuration = CommandConfiguration(
        commandName: "guard",
        abstract: "Name the controls of an app an agent asks you before tapping, or never taps, so it can drive everything else freely.",
        discussion: """
        Rules live in `offsider.guard.json` in the app's repository: `ask` for controls that move money or assets, `never` for \
        ones that change sign-in or account security. Everything else in the app is free. Offsider checks the control under every \
        tap, drag and Return key, whatever the command looked like.

        An agent may write and tighten the file; a new or stricter rule applies at once. Only a person approves it, in their own \
        terminal with Touch ID, and nothing an agent changes can loosen what was approved.

          status    where an app's guard stands and what to do next (start here)
          init      write a starter offsider.guard.json for the app
          check     check the file; with --device, say which rules match the screen now
          show      list the rules in force
          approve   a person approves the file's rules for its apps

        Examples:
          offsider guard status --app com.example.app --json
          offsider guard init --app com.example.app --app com.example.app.ios
          offsider guard check --device <DEVICE_ID> --app com.example.app
          offsider guard approve
        """
    )

    enum Action: String, CaseIterable {
        case status, `init`, check, show, approve
    }

    @Argument(help: ArgumentHelp("status, init, check, show or approve.", valueName: "action"))
    var action: String

    @Option(name: .customLong("app"), help: ArgumentHelp("The app's bundle ID or package (repeatable with init); without it, the apps the file names.", valueName: "bundle-id"), transform: AppID.parse)
    var apps: [String] = []

    @Option(name: .customLong("project"), help: ArgumentHelp("The folder to find or write offsider.guard.json in (default: the working directory, searched up to the repository root).", valueName: "dir"))
    var project: String?

    @Option(name: .customLong("device"), help: ArgumentHelp("With check: the device whose screen the rules are tried on.", valueName: "id"))
    var device: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    var namedApp: String? { apps.first }

    func parsedAction() throws -> Action {
        guard let parsed = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(action)'. Use status, init, check, show or approve.")
        }
        return parsed
    }

    func validate() throws {
        let parsed = try parsedAction()
        if device != nil, parsed != .check { throw ValidationError("--device goes with check, not \(parsed.rawValue).") }
        if apps.count > 1, parsed != .`init` { throw ValidationError("\(parsed.rawValue) takes one --app.") }
        if parsed == .`init`, apps.isEmpty { throw ValidationError("init needs the app: offsider guard init --app <bundle id or package>.") }
        guard Set(apps).count == apps.count else { throw ValidationError("--app names the same app twice.") }
    }

    /// What the command reads; tests bind their own folder, approvals and seal.
    struct Context: Sendable {
        var directory: @Sendable () -> String
        var store: @Sendable () -> GuardApprovalStore?
        var seal: any GuardSealing
        var now: @Sendable () -> Date

        static let live = Context(directory: { FileManager.default.currentDirectoryPath }, store: { GuardSources.store() }, seal: KeychainGuardSeal(), now: { Date() })
    }

    @TaskLocal static var context = Context.live

    @MainActor
    func run() async throws {
        let context = Self.context
        let loaded = GuardSources.load(from: project ?? context.directory(), store: context.store(), seal: context.seal)
        let output: String
        switch try parsedAction() {
        case .status: output = try status(loaded)
        case .show: output = try show(loaded)
        case .`init`: output = try start(loaded, context: context)
        case .check: output = try await check(loaded)
        case .approve: output = try await approve(loaded, context: context)
        }
        Console.current.data(output + "\n")
    }

    /// The apps a report covers: the one named, else every app with rules.
    func reported(_ loaded: GuardSources.Loaded) throws -> [GuardSet] {
        if let problem = loaded.problem { throw CLIError(errorDescription: "\(problem) Fix the file, or move it aside.", reason: .usage) }
        let names = apps.isEmpty ? loaded.apps : apps
        return names.map(loaded.set(for:))
    }

    func status(_ loaded: GuardSources.Loaded) throws -> String {
        GuardReport.status(try reported(loaded), file: loaded.file?.path, json: json)
    }

    func show(_ loaded: GuardSources.Loaded) throws -> String {
        GuardReport.show(try reported(loaded), json: json)
    }

    func start(_ loaded: GuardSources.Loaded, context: Context) throws -> String {
        if let file = loaded.file {
            throw CLIError(errorDescription: "\(file.path) already exists, so nothing was written. Edit it, then run `offsider guard check`.", reason: .usage, hint: "offsider guard check")
        }
        let folder = URL(fileURLWithPath: project ?? context.directory()).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError(errorDescription: "\(folder) is not a folder. Pass --project with the app's repository.", reason: .usage)
        }
        let path = (folder as NSString).appendingPathComponent(GuardConfig.fileName)
        let config = GuardStarter.config(apps: apps)
        do {
            try config.encoded().write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
        } catch {
            throw CLIError(errorDescription: "Could not write \(path): \(error.localizedDescription)", reason: .commandFailed)
        }
        return GuardReport.started(path: path, config: config, json: json)
    }

    @MainActor
    func check(_ loaded: GuardSources.Loaded) async throws -> String {
        let sets = try reported(loaded)
        guard !sets.isEmpty else {
            throw CLIError(errorDescription: "No guard rules here to check. Run `offsider guard init --app <bundle id or package>` in the app's repository.", reason: .usage)
        }
        var seen: [String: (screen: Bool, control: Bool)] = [:]
        var front: String?
        if let device {
            let logger = OffsiderLogger()
            let watchdog = DeviceWatchdog()
            let locking = DeviceIDClassifier.classify(device).platform == .android
            let route = try await DeviceRouter.routeForInput(device, logger: logger, watchdog: watchdog, locking: locking)
            if let app = apps.first, let phone = route.backend as? any AppTargetSelecting { _ = phone.selectApp(app, on: route.device) }
            let tree = try await Console.current.progress("Reading the screen") {
                try await watchdog.guardingTreeStart(on: route)
                return try await route.backend.accessibilityTree(for: route.device)
            }
            front = try? ForegroundApp.identifier(in: tree, pathForPID: { pid in Int32(exactly: pid).flatMap { ProcessPath.of(pid: $0) } })
            for rule in sets.flatMap(\.rules) { seen[rule.name] = GuardJudge.seen(rule, in: tree) }
        }
        return GuardReport.check(sets, file: loaded.file?.path, front: front, seen: seen, json: json)
    }

    @MainActor
    func approve(_ loaded: GuardSources.Loaded, context: Context) async throws -> String {
        let instead = "Give the user this command to run in their own terminal, in the app's repository: `offsider guard approve`."
        try PersonPresence.requireTerminal(instead: instead)
        if let problem = loaded.problem { throw CLIError(errorDescription: "\(problem) Fix the file, or move it aside.", reason: .usage) }
        guard let file = loaded.file else {
            throw CLIError(errorDescription: "No \(GuardConfig.fileName) here or above, so there is nothing to approve. Run this in the app's repository, or pass --project.", reason: .usage)
        }
        if let app = apps.first, !file.config.apps.contains(app) {
            throw CLIError(errorDescription: "\(file.path) does not cover \(app). Add it to the file's apps first.", reason: .usage)
        }
        guard let store = context.store() else {
            throw CLIError(errorDescription: "This account has no home folder, so approvals cannot be kept.", reason: .commandFailed)
        }
        let config = file.config
        let lines = GuardReport.approvalSummary(config, loosened: config.apps.flatMap { app in loaded.set(for: app).loosened.map { "\(app): \($0)" } })
        try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved, instead: instead) { prompt in
            prompt.lines(lines)
            guard try prompt.choose("Approve these rules?", options: ["🔐  Approve", "❌  Cancel"]) == 0 else { throw PromptCancelled() }
        }
        try await PersonPresence.confirm(reason: "approve the guard rules for \(config.apps.joined(separator: ", "))")
        try store.update({ current in
            // Approvals edited outside Offsider are dropped: only what a person approves here is kept.
            (loaded.sealIntact ? current : .empty).approving(config, source: file.path, now: Date(timeIntervalSince1970: context.now().timeIntervalSince1970.rounded(.down)))
        }, commit: { data, apps in try context.seal.store(GuardSealRecord(data: data, apps: apps)) })
        return GuardReport.approved(config, file: file.path, json: json)
    }

    /// For `devices add`, whose person has just confirmed with Touch ID: shows this repository's unapproved guard rules, approves on a yes and returns the receipt lines.
    @MainActor
    static func offerApproval(on prompt: TerminalPrompt, context: Context = GuardCommand.context) -> [String] {
        guard (try? ProjectGuide.locate(fileName: GuardConfig.fileName, from: context.directory())) != nil, let store = context.store() else { return [] }
        let loaded = GuardSources.load(from: context.directory(), store: store, seal: context.seal)
        guard loaded.problem == nil, let file = loaded.file else { return [] }
        let sets = file.config.apps.map(loaded.set(for:))
        guard sets.contains(where: { $0.state != .ready || !$0.loosened.isEmpty || !$0.added.isEmpty }) else { return [] }
        prompt.lines([""] + GuardReport.approvalSummary(file.config, loosened: sets.flatMap { set in set.loosened.map { "\(set.app): \($0)" } }))
        guard (try? prompt.choose("Approve these rules?", options: ["🔐  Approve", "⏭  Not now"])) == 0 else {
            return ["Guard rules not approved. Later: \(GuardReport.approveCommand)"]
        }
        do {
            try store.update({ current in
                (loaded.sealIntact ? current : .empty).approving(file.config, source: file.path, now: Date(timeIntervalSince1970: context.now().timeIntervalSince1970.rounded(.down)))
            }, commit: { data, apps in try context.seal.store(GuardSealRecord(data: data, apps: apps)) })
        } catch {
            return ["Could not save the guard approval: \(error). Later: \(GuardReport.approveCommand)"]
        }
        return [GuardReport.approved(file.config, file: file.path, json: false)]
    }
}
