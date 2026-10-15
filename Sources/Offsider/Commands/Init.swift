import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

struct Init: AsyncParsableCommand {
    private static let skillFolderName = "offsider"

    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Install Offsider skill files for detected AI clients."
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
    }

    func run() async throws {
        if !printSkill, !isInteractiveTTY(), dest == nil, client == .auto {
            throw CLIError(
                errorDescription: "Non-interactive mode requires --client or --dest for init. Use --print to output the skill content.",
                reason: .usage
            )
        }

        if printSkill {
            Swift.print(try Self.loadSkillMarkdown(), terminator: "")
            return
        }

        var targets = try resolveTargets(for: uninstall ? .uninstall : .install)
        if !uninstall, dest == nil, client == .auto, isInteractiveTTY() {
            targets = try Self.chooseAgents(targets)
        }

        if uninstall {
            try uninstallSkill(from: targets)
            return
        }

        try installSkill(to: targets)
    }

    /// With more than one skills folder detected, a person ticks which to install into; every one starts ticked.
    static func chooseAgents<Target>(_ targets: [Target], descriptor: Int32? = nil, name: (Target) -> String, folder: (Target) -> String) throws -> [Target] {
        let folders = SkillInstall.distinct(targets, resolvedPath: folder)
        guard folders.count > 1 else { return targets }
        let rows = folders.map { first in
            MenuRow([targets.filter { folder($0) == folder(first) }.map(name).joined(separator: " and "), InitScreen.shortPath(folder(first), home: homeDirectoryPath())])
        }
        let chosen = try TerminalPrompt.run(cancelled: InitScreen.cancelled, descriptor: descriptor) { prompt in
            try prompt.chooseMany(InitScreen.agentsQuestion, rows: rows, ticked: Set(rows.indices))
        }
        let kept = Set(chosen.map { folder(folders[$0]) })
        return targets.filter { kept.contains(folder($0)) }
    }

    private static func chooseAgents(_ targets: [ClientInfo]) throws -> [ClientInfo] {
        try chooseAgents(targets, name: \.name) { $0.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL.path }
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

    private func installSkill(to targets: [ClientInfo]) throws {
        let bundled = Data(try Self.loadSkillMarkdown().utf8)
        var lines: [String] = []

        for (target, names) in Self.distinctFolders(targets) {
            let targetDirectory = target.skillsDirectory.appendingPathComponent(Self.skillFolderName, isDirectory: true)
            let targetFile = targetDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
            let action = SkillInstall.action(existing: FileManager.default.contents(atPath: targetFile.path), bundled: bundled, force: force)
            let label = "\(names.joined(separator: " and ")): \(targetFile.path)"
            switch action {
            case .upToDate:
                lines.append("Already up to date -> \(label)")
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
                lines.append("\(action == .install ? "Installed" : "Updated") Offsider skill -> \(label)")
            } catch {
                throw CLIError(
                    errorDescription: "Failed to install Offsider skill for \(target.name): \(error.localizedDescription)",
                    reason: .initFailed
                )
            }
        }

        if lines.isEmpty {
            throw CLIError(errorDescription: "No install targets resolved.", reason: .initFailed)
        }

        Self.write(lines + ["Next: offsider doctor"])
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
        var stale: [String] = []
        for (client, _) in distinctFolders(clients) {
            let file = client.skillsDirectory.appendingPathComponent("\(skillFolderName)/SKILL.md").path
            guard let data = FileManager.default.contents(atPath: file), SkillInstall.isOffsiderSkill(data) else { continue }
            installed.append(file)
            if data != bundled { stale.append(file) }
        }
        return DoctorCheckResult(id: .installSkill, verdict: SkillInstall.doctorVerdict(installed: installed, stale: stale))
    }

    private func uninstallSkill(from targets: [ClientInfo]) throws {
        var removedPaths: [String] = []

        for target in targets {
            let targetDirectory = target.skillsDirectory.appendingPathComponent(Self.skillFolderName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: targetDirectory.path) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: targetDirectory)
                removedPaths.append("\(target.name): \(targetDirectory.path)")
            } catch {
                throw CLIError(
                    errorDescription: "Failed to uninstall Offsider skill for \(target.name): \(error.localizedDescription)",
                    reason: .initFailed
                )
            }
        }

        if removedPaths.isEmpty {
            fputs("No installed Offsider skill directories were found.\n", stdout)
            return
        }

        Self.write(removedPaths.map { "Removed Offsider skill -> \($0)" })
    }

    /// Plain lines to a pipe; on a terminal, the same results drawn with the terminal UI kit.
    private static func write(_ lines: [String]) {
        let terminal = isatty(STDOUT_FILENO) != 0
        let shown = terminal ? InitScreen.styled(lines, style: .detect(isTerminal: true)) : lines
        for line in shown { fputs("\(line)\n", stdout) }
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
