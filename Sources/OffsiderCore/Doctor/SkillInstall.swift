import Foundation

/// What `init` does with one skill folder, and what `doctor` says about the installed ones.
public enum SkillInstall {
    public enum Action: Equatable, Sendable {
        case install
        case upToDate
        /// An older Offsider skill, replaced from the digest-checked bundle with no `--force`.
        case update
        /// Someone else's skill in the folder; only `--force` replaces it.
        case refuse
    }

    public static func action(existing: Data?, bundled: Data, force: Bool) -> Action {
        guard let existing else { return .install }
        if existing == bundled { return .upToDate }
        return force || isOffsiderSkill(existing) ? .update : .refuse
    }

    /// True when the file's front matter names the skill `offsider`.
    public static func isOffsiderSkill(_ data: Data) -> Bool {
        let lines = String(decoding: data.prefix(4096), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        for line in lines.dropFirst() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "---" { return false }
            if text == "name: offsider" || text == "name: \"offsider\"" { return true }
        }
        return false
    }

    /// The first of each group of directories that resolve to the same place, so a symlinked folder installs once.
    public static func distinct<T>(_ items: [T], resolvedPath: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(resolvedPath($0)).inserted }
    }

    /// `install.skill` over the installed skills and the stale ones with their `--client`; an agent, which has no terminal for `init`'s picker, is told the client.
    public static func doctorVerdict(installed: [String], stale: [(file: String, client: String)], agent: Bool, clients: [String] = []) -> DoctorRules.Verdict {
        if installed.isEmpty {
            let named = clients.isEmpty ? ["claude", "agents"] : clients
            return (.skip, "No Offsider skill is installed for an agent", "Run \(agent ? named.map { "offsider init --client \($0)" }.joined(separator: " or ") : "offsider init").")
        }
        if let first = stale.first {
            let others = stale.count > 1 ? " and \(stale.count - 1) more" : ""
            let commands = agent ? stale.map { "offsider init --client \($0.client)" } : ["offsider init"]
            return (.warn, "\(first.file)\(others) differs from this version's skill", "Run \(commands.joined(separator: " and ")) to update \(commands.count > 1 ? "them" : "it").")
        }
        return (.pass, installed.count == 1 ? "\(installed[0]) matches this version" : "\(installed.count) installed skills match this version", nil)
    }
}
