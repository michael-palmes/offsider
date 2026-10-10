import Foundation

/// What `credential set` should do before it asks for a password.
public enum LoginSetIntent: Equatable, Sendable {
    /// Write this key. `makeDefault` is true when this login is the one `login` uses with no tag.
    case write(key: String, makeDefault: Bool)
    /// Saved logins already exist and the terminal should ask.
    case choose
    /// The tag is already saved and the terminal should ask before replacing it.
    case confirm(key: String, makeDefault: Bool)
    /// A message for the user. Nothing is saved.
    case refused(String)
}

/// What `credential join` should do. It never reads a password.
public enum LoginJoinIntent: Equatable, Sendable {
    case join(canonical: String)
    case already(canonical: String)
    case choose
    case refused(String)
}

/// An answer to the set menu: update one saved login, or create a tagged one.
public enum LoginSetChoice: Equatable, Sendable {
    case update(key: String)
    case create
}

/// The rules for the default login, tags, and sharing one app across bundle ids.
public enum LoginDirectory {
    public static func setIntent(entries: [LoginCredentialSummary], tag: String?, update: Bool, interactive: Bool) -> LoginSetIntent {
        if entries.isEmpty {
            if let tag { return .write(key: tag, makeDefault: true) }
            return .write(key: LoginCredential.defaultAccountKey, makeDefault: true)
        }
        if let tag {
            if let existing = entries.first(where: { $0.key == tag }) {
                guard update else {
                    if interactive { return .confirm(key: tag, makeDefault: existing.isDefault) }
                    return .refused("The tag \(tag) is already saved for this app. Pass --update to replace it. Nothing was saved.")
                }
                return .write(key: tag, makeDefault: existing.isDefault)
            }
            return .write(key: tag, makeDefault: false)
        }
        if update {
            if let marked = entries.first(where: \.isDefault) {
                return .write(key: marked.key, makeDefault: true)
            }
            if entries.count == 1, let only = entries.first {
                return .write(key: only.key, makeDefault: true)
            }
            let tags = entries.map { LoginCredential.displayKey($0.key) }.joined(separator: ", ")
            return .refused("Several logins are saved for this app (\(tags)) and none is the default. Pass the tag to update. Nothing was saved.")
        }
        if interactive { return .choose }
        return .refused("This app already has a saved login. Pass --update to replace the default, or a tag such as qa to add another. Nothing was saved.")
    }

    /// True when adding another login should mark the sole existing one as the default.
    public static func shouldStampDefault(_ entries: [LoginCredentialSummary], writing key: String) -> String? {
        guard entries.count == 1, let only = entries.first, only.key != key, !only.isDefault else { return nil }
        return only.key
    }

    public static func joinIntent(foreground: String, groups: [LoginAppGroup], requested: String?, interactive: Bool) -> LoginJoinIntent {
        if groups.contains(where: { $0.canonical == foreground }) {
            if let requested, resolve(requested, in: groups) == foreground { return .already(canonical: foreground) }
            return .refused("This app already has its own saved logins. Nothing was linked.")
        }
        if let linked = groups.first(where: { $0.members.contains(foreground) }) {
            if let requested {
                guard let target = resolve(requested, in: groups) else {
                    return .refused("No saved login belongs to \(requested). Nothing was linked.")
                }
                if target != linked.canonical {
                    return .refused("This app is already linked to \(linked.canonical). Nothing was linked.")
                }
            }
            return .already(canonical: linked.canonical)
        }
        guard !groups.isEmpty else {
            return .refused("No login is saved yet. Save one with credential set, then join. Nothing was linked.")
        }
        if let requested {
            guard let target = resolve(requested, in: groups) else {
                return .refused("No saved login belongs to \(requested). Nothing was linked.")
            }
            return .join(canonical: target)
        }
        if groups.count == 1, let only = groups.first { return .join(canonical: only.canonical) }
        if interactive { return .choose }
        let names = groups.map(\.canonical).joined(separator: ", ")
        return .refused("Several apps have saved logins (\(names)). Pass --app with the one to share. Nothing was linked.")
    }

    /// The menu row at `index`: a saved login to update, or the last row to add one.
    public static func setChoice(at index: Int, entries: [LoginCredentialSummary]) -> LoginSetChoice {
        entries.indices.contains(index) ? .update(key: entries[index].key) : .create
    }

    private static func resolve(_ requested: String, in groups: [LoginAppGroup]) -> String? {
        if let own = groups.first(where: { $0.canonical == requested }) { return own.canonical }
        return groups.first { $0.members.contains(requested) }?.canonical
    }
}
