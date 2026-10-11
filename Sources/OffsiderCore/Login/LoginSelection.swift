import Foundation

/// Which saved login a name, `--where` tags or the default picks.
public enum LoginSelectionOutcome: Equatable, Sendable {
    case chosen(LoginEntry)
    /// The name asked for is not saved.
    case missing(String)
    case noneSaved
    /// No saved login has every `--where` tag. Holds every saved login.
    case noMatch([LoginEntry])
    /// Several saved logins have every `--where` tag. Holds the matches.
    case ambiguous([LoginEntry])
    /// Several logins are saved and none is the default. Holds every saved login.
    case noDefault([LoginEntry])
}

/// The rules for choosing a saved login. Nothing here reads a username or a password.
public enum LoginSelection {
    /// A name wins over `filter`; callers refuse both together. The default never breaks a tie between `--where` matches.
    public static func resolve(entries: [LoginEntry], name: String?, where filter: [LoginTag]) -> LoginSelectionOutcome {
        if let name {
            return entries.first { $0.key == name }.map(LoginSelectionOutcome.chosen) ?? .missing(name)
        }
        guard !entries.isEmpty else { return .noneSaved }
        if !filter.isEmpty {
            let found = entries.filter { matches($0, where: filter) }
            switch found.count {
            case 0: return .noMatch(entries)
            case 1: return .chosen(found[0])
            default: return .ambiguous(found)
            }
        }
        if let marked = entries.first(where: \.isDefault) { return .chosen(marked) }
        if entries.count == 1 { return .chosen(entries[0]) }
        return .noDefault(entries)
    }

    /// True when the login has every tag in `filter`. A bare word matches only a bare tag.
    public static func matches(_ entry: LoginEntry, where filter: [LoginTag]) -> Bool {
        let tags = Set(entry.context.tags)
        return filter.allSatisfy(tags.contains)
    }

    /// `platform=<platform>` when adding it to `filter` leaves exactly one of `matches`. A hint, never applied for the caller.
    public static func platformRefinement(_ matches: [LoginEntry], where filter: [LoginTag], platform: DevicePlatform) -> LoginTag? {
        guard !filter.contains(where: { $0.key == LoginTag.platformKey }) else { return nil }
        let tag = LoginTag(platform: platform)
        return matches.filter { self.matches($0, where: [tag]) }.count == 1 ? tag : nil
    }

    /// `qa-admin (env=staging role=admin · Admin on staging)`. Never a username.
    public static func line(_ entry: LoginEntry) -> String {
        let context = entry.context
        let parts = [context.tags.map(\.rawValue).joined(separator: " "), context.about ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? entry.name : "\(entry.name) (\(parts.joined(separator: " · ")))"
    }
}
