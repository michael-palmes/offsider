import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

struct Init: AsyncParsableCommand {
    private static let skillFolderName = "offsider"

    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install Offsider's skill and permission rules for the AI agents on this Mac."
    )

    enum Client: String, ExpressibleByArgument, CaseIterable {
        case auto
        case claude
        case agents
    }

    @Option(help: "Target client: auto, claude, or agents. Defaults to auto-detect.")
    var client: Client = .auto

    @Option(help: "Custom destination skills directory (overrides --client).")
    var dest: String?

    @Flag(help: "Replace a skill named offsider that is not Offsider's; Offsider's own is updated without it.")
    var force: Bool = false

    @Flag(help: "Remove installed Offsider skill from target directories.")
    var uninstall: Bool = false

    @Flag(name: .customLong("print"), help: "Print bundled skill content to stdout.")
    var printSkill: Bool = false

    @Flag(name: .customLong("no-rules"), help: "Skip the permission rules for Claude Code and Codex.")
    var noRules: Bool = false

    @Flag(name: .customLong("rules-only"), help: "Add the permission rules without installing the skill.")
    var rulesOnly: Bool = false

    @Flag(name: .customLong("print-rules"), help: "Print the permission rules as JSON, to apply by hand.")
    var printRules: Bool = false

    func validate() throws {
        if printSkill, uninstall {
            throw ValidationError("--print cannot be used with --uninstall")
        }

        if printSkill, force {
            throw ValidationError("--print cannot be used with --force")
        }

        if printSkill, dest != nil {
            throw ValidationError("--print cannot be used with --dest")
        }

        if printSkill, client != .auto {
            throw ValidationError("--print cannot be used with --client")
        }

        if printRules, printSkill || uninstall || force || dest != nil || client != .auto || noRules || rulesOnly {
            throw ValidationError("--print-rules cannot be used with other options")
        }

        if rulesOnly, noRules || uninstall || force || dest != nil || printSkill {
            throw ValidationError("--rules-only cannot be used with --no-rules, --uninstall, --force, --dest or --print")
        }
    }

    func run() async throws {
        if printRules {
            Swift.print(AgentPermissionRules.printedJSON(), terminator: "")
            return
        }

        let interactive = isInteractiveTTY()
        if !printSkill, !rulesOnly, !interactive, dest == nil, client == .auto {
            throw CLIError(
                errorDescription: "Non-interactive mode requires --client or --dest for init. Use --print to output the skill content.",
                reason: .usage
            )
        }

        if printSkill {
            Swift.print(try Self.loadSkillMarkdown(), terminator: "")
            return
        }

        let home = Self.homeDirectoryPath()
        // Detected before the skill install, which may create ~/.claude/skills.
        var agents = noRules || uninstall || dest != nil ? [] : Self.rulesAgents(for: client, home: home)

        if rulesOnly {
            guard !agents.isEmpty else {
                throw CLIError(errorDescription: "No Claude Code or Codex folder found, so there is nowhere to add rules.", reason: .usage)
            }
            if client == .auto, interactive {
                agents = try Self.chooseInstall([(String, String)](), rules: agents, name: \.0, folder: \.1).rules
            }
            let (steps, failures) = Self.applyRules(agents, home: home)
            Console.current.show(InitScreen.page(steps))
            try Self.throwFirst(failures)
            return
        }

        var targets = try resolveTargets(for: uninstall ? .uninstall : .install)
        if !uninstall, dest == nil, client == .auto, interactive {
            (targets, agents) = try Self.chooseInstall(targets, rules: agents, name: \.name) { $0.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL.path }
        }

        if uninstall {
            try uninstallSkill(from: targets)
            return
        }

        if targets.isEmpty, agents.isEmpty {
            throw CLIError(errorDescription: "No install targets resolved.", reason: .initFailed)
        }
        var steps = targets.isEmpty ? [] : try installSkill(to: targets)
        let (ruleSteps, failures) = Self.applyRules(agents, home: home)
        steps += ruleSteps
        Console.current.show(InitScreen.page(steps, next: "offsider doctor"))
        try Self.throwFirst(failures)
    }

    /// With more than one skills folder detected, a person ticks which to install into; every one starts ticked.
    static func chooseAgents<Target>(_ targets: [Target], descriptor: Int32? = nil, name: (Target) -> String, folder: (Target) -> String) throws -> [Target] {
        try chooseInstall(targets, rules: [], descriptor: descriptor, name: name, folder: folder).skills
    }

    /// One row per distinct skills folder and one per agent that can take permission rules, all ticked; no picker for a single row.
    static func chooseInstall<Target>(
        _ targets: [Target],
        rules: [AgentPermissionRules.Agent],
        descriptor: Int32? = nil,
        name: (Target) -> String,
        folder: (Target) -> String
    ) throws -> (skills: [Target], rules: [AgentPermissionRules.Agent]) {
        let folders = SkillInstall.distinct(targets, resolvedPath: folder)
        guard folders.count + rules.count > 1 else { return (targets, rules) }
        let rows = folders.map { first in
            MenuRow([targets.filter { folder($0) == folder(first) }.map(name).joined(separator: " and "), TerminalText.homePath(folder(first), home: homeDirectoryPath())])
        } + rules.map { MenuRow($0.pickerRow) }
        let chosen = try TerminalPrompt.run(cancelled: InitScreen.cancelled, descriptor: descriptor) { prompt in
            try prompt.chooseMany(InitScreen.agentsQuestion, rows: rows, ticked: Set(rows.indices))
        }
        let kept = Set(chosen.filter { $0 < folders.count }.map { folder(folders[$0]) })
        let keptRules = chosen.filter { $0 >= folders.count }.map { rules[$0 - folders.count] }
        return (targets.filter { kept.contains(folder($0)) }, keptRules)
    }

    /// The agents to add rules for: every one installed under `home` for auto, else the one `--client` names when installed.
    static func rulesAgents(for client: Client, home: String) -> [AgentPermissionRules.Agent] {
        let detected = AgentPermissionRules.detect(home: home)
        switch client {
        case .auto: return detected
        case .claude: return detected.filter { $0 == .claudeCode }
        case .agents: return detected.filter { $0 == .codex }
        }
    }

    /// Merges the rules into each agent's file; a file that cannot be read safely is left untouched and reported.
    static func installRules(_ agents: [AgentPermissionRules.Agent], home: String) -> (lines: [String], failures: [String]) {
        let (steps, failures) = applyRules(agents, home: home)
        return (steps.map(\.line), failures)
    }

    private static func applyRules(_ agents: [AgentPermissionRules.Agent], home: String) -> (steps: [InitScreen.Step], failures: [String]) {
        var steps: [InitScreen.Step] = []
        var failures: [String] = []
        for agent in agents {
            let file = URL(fileURLWithPath: home).appendingPathComponent(agent.rulesFile)
            let shown = "~/" + agent.rulesFile
            do {
                let merge = try AgentPermissionRules.merge(agent, existing: try readCapped(file))
                if let content = merge.content {
                    try writeAtomically(content, to: file)
                }
                let line = AgentPermissionRules.resultLine(path: shown, added: merge.added)
                steps.append(InitScreen.Step(merge.added == 0 ? .rulesPresent : .rulesAdded(merge.added), who: agent.name, path: shown, line: line))
            } catch let error as AgentPermissionRules.MergeError {
                failures.append(AgentPermissionRules.failureLine(path: shown, error: error))
            } catch {
                failures.append("Could not add rules to \(shown): \(error.localizedDescription)")
            }
        }
        return (steps, failures)
    }

    /// The file's bytes, nil when it does not exist; reads at most one byte past the cap so a huge file is refused cheaply.
    static func readCapped(_ file: URL) throws -> Data? {
        do {
            return try UntrustedRead.data(atPath: file.resolvingSymlinksInPath().path, maxBytes: AgentPermissionRules.maxFileBytes + 1, truncate: true)
        } catch .missing {
            return nil
        } catch .notRegularFile {
            throw CLIError(errorDescription: "\(file.path) is not a regular file, so it was left as is.", reason: .initFailed)
        } catch {
            throw CLIError(errorDescription: "Could not read \(file.path) (\(error)).", reason: .initFailed)
        }
    }

    /// Writes beside the file (through a symlink to its target), 0600, then renames over it.
    static func writeAtomically(_ data: Data, to file: URL) throws {
        let target = file.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).offsider-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CLIError(errorDescription: "Could not write \(temporary.path).", reason: .initFailed)
        }
        if rename(temporary.path, target.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CLIError(errorDescription: "Could not replace \(target.path): \(String(cString: strerror(code))).", reason: .initFailed)
        }
    }

    private static func throwFirst(_ failures: [String]) throws {
        guard let first = failures.first else { return }
        for other in failures.dropFirst() { Console.current.line(other, person: .warning(other)) }
        throw CLIError(errorDescription: first, reason: .initFailed)
    }

    private enum Operation {
        case install
        case uninstall
    }

    private struct ClientInfo {
        let id: Client
        let name: String
        let skillsDirectory: URL
    }

    private static func loadSkillMarkdown() throws -> String {
        let data = try BundleIntegrity.verifiedData("skills/\(skillFolderName)/SKILL.md")
        return String(decoding: data, as: UTF8.self)
    }

    private func installSkill(to targets: [ClientInfo]) throws -> [InitScreen.Step] {
        let bundled = Data(try Self.loadSkillMarkdown().utf8)
        var steps: [InitScreen.Step] = []

        for (target, names) in Self.distinctFolders(targets) {
            let targetDirectory = target.skillsDirectory.appendingPathComponent(Self.skillFolderName, isDirectory: true)
            let targetFile = targetDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
            let action = SkillInstall.action(existing: FileManager.default.contents(atPath: targetFile.path), bundled: bundled, force: force)
            let who = names.joined(separator: " and ")
            let label = "\(who): \(targetFile.path)"
            switch action {
            case .upToDate:
                steps.append(InitScreen.Step(.upToDate, who: who, path: targetFile.path, line: "Already up to date -> \(label)"))
                continue
            case .refuse:
                throw CLIError(
                    errorDescription: "Another skill named offsider is at \(targetFile.path). Re-run with --force to replace it.",
                    reason: .initFailed
                )
            case .install, .update:
                break
            }
            do {
                try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                try bundled.write(to: targetFile, options: .atomic)
                let line = "\(action == .install ? "Installed" : "Updated") Offsider skill -> \(label)"
                steps.append(InitScreen.Step(action == .install ? .installed : .updated, who: who, path: targetFile.path, line: line))
            } catch {
                throw CLIError(
                    errorDescription: "Failed to install Offsider skill for \(target.name): \(error.localizedDescription)",
                    reason: .initFailed
                )
            }
        }

        if steps.isEmpty {
            throw CLIError(errorDescription: "No install targets resolved.", reason: .initFailed)
        }

        return steps
    }

    /// One entry per real folder, naming every client that shares it (a symlinked `~/.claude/skills` is one folder).
    private static func distinctFolders(_ targets: [ClientInfo]) -> [(ClientInfo, [String])] {
        let resolved = { (target: ClientInfo) in target.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL.path }
        return SkillInstall.distinct(targets, resolvedPath: resolved).map { first in
            (first, targets.filter { resolved($0) == resolved(first) }.map(\.name))
        }
    }

    /// `doctor`'s `install.skill` check over the clients' skill folders that hold an Offsider skill.
    static func doctorCheck() -> DoctorCheckResult {
        guard let bundled = try? Data(loadSkillMarkdown().utf8) else {
            return DoctorCheckResult(id: .installSkill, status: .skip, detail: "the bundled skill could not be read")
        }
        let clients = Client.allCases.filter { $0 != .auto }.compactMap { try? clientInfo(for: $0) }
        var installed: [String] = []
        var stale: [(file: String, client: String)] = []
        for (client, _) in distinctFolders(clients) {
            let file = client.skillsDirectory.appendingPathComponent("\(skillFolderName)/SKILL.md").path
            guard let data = FileManager.default.contents(atPath: file), SkillInstall.isOffsiderSkill(data) else { continue }
            installed.append(file)
            if data != bundled { stale.append((file, client.id.rawValue)) }
        }
        let verdict = SkillInstall.doctorVerdict(installed: installed, stale: stale, agent: Console.current.out.profile == .agent, clients: detectClients().map(\.id.rawValue))
        return DoctorCheckResult(id: .installSkill, verdict: verdict)
    }

    /// What `doctor`'s `install.rules` check reports: the installed agents still missing any of the rules.
    static func rulesDoctorVerdict(home: String = homeDirectoryPath()) -> DoctorRules.Verdict {
        let detected = AgentPermissionRules.detect(home: home)
        let lacking = detected.filter { agent in
            let existing = try? readCapped(URL(fileURLWithPath: home).appendingPathComponent(agent.rulesFile))
            return AgentPermissionRules.missing(agent, existing: existing ?? nil) > 0
        }
        return AgentPermissionRules.doctorVerdict(detected: detected, lacking: lacking)
    }

    private func uninstallSkill(from targets: [ClientInfo]) throws {
        var removed: [InitScreen.Step] = []

        for target in targets {
            let targetDirectory = target.skillsDirectory.appendingPathComponent(Self.skillFolderName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: targetDirectory.path) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: targetDirectory)
                let line = "Removed Offsider skill -> \(target.name): \(targetDirectory.path)"
                removed.append(InitScreen.Step(.removed, who: target.name, path: targetDirectory.path, line: line))
            } catch {
                throw CLIError(
                    errorDescription: "Failed to uninstall Offsider skill for \(target.name): \(error.localizedDescription)",
                    reason: .initFailed
                )
            }
        }

        Console.current.show(removed.isEmpty ? InitScreen.nothingToRemove : InitScreen.page(removed))
    }

    private func resolveTargets(for operation: Operation) throws -> [ClientInfo] {
        if let destination = dest {
            let resolvedDestination = try Self.resolveDestinationURL(from: destination)
            return [ClientInfo(id: .auto, name: "Custom", skillsDirectory: resolvedDestination)]
        }

        if client != .auto {
            return [try Self.clientInfo(for: client)]
        }

        let detected = Self.detectClients()
        if detected.isEmpty {
            if operation == .uninstall {
                return []
            }

            throw CLIError(
                errorDescription: "No supported AI clients detected. Use --client, --dest, or --print.",
                reason: .usage
            )
        }

        return detected
    }

    private static func detectClients() -> [ClientInfo] {
        Client.allCases
            .filter { $0 != .auto }
            .compactMap { try? clientInfoIfDetected(for: $0) }
    }

    private static func clientInfoIfDetected(for client: Client) throws -> ClientInfo? {
        let homeDirectory = homeDirectoryPath()
        let clientRootPath: String

        switch client {
        case .claude:
            clientRootPath = homeDirectory + "/.claude"
        case .agents:
            clientRootPath = homeDirectory + "/.agents"
        case .auto:
            return nil
        }

        guard FileManager.default.fileExists(atPath: clientRootPath) else {
            return nil
        }

        return try clientInfo(for: client)
    }

    private static func clientInfo(for client: Client) throws -> ClientInfo {
        let homeDirectory = homeDirectoryPath()

        switch client {
        case .claude:
            return ClientInfo(
                id: .claude,
                name: "Claude Code",
                skillsDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude/skills", isDirectory: true)
            )
        case .agents:
            return ClientInfo(
                id: .agents,
                name: "Agents Skills",
                skillsDirectory: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".agents/skills", isDirectory: true)
            )
        case .auto:
            throw CLIError(errorDescription: "Auto is not a concrete client target.", reason: .usage)
        }
    }

    static func homeDirectoryPath() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func isInteractiveTTY() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    private static func resolveDestinationURL(from rawValue: String) throws -> URL {
        let expandedPath = expandHomePrefix(rawValue)
        let standardizedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path

        guard standardizedPath != "/" else {
            throw CLIError(errorDescription: "Refusing to use filesystem root as skills destination.", reason: .usage)
        }

        return URL(fileURLWithPath: standardizedPath, isDirectory: true)
    }

    private static func expandHomePrefix(_ path: String) -> String {
        if path == "~" {
            return homeDirectoryPath()
        }

        if path.hasPrefix("~/") {
            let suffix = String(path.dropFirst(2))
            return URL(fileURLWithPath: homeDirectoryPath()).appendingPathComponent(suffix).path
        }

        return path
    }
}
