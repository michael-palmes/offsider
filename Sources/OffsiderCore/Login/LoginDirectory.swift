import Foundation

/// What `credential set` should do before it asks for a password.
public enum LoginSetIntent: Equatable, Sendable {
    /// Write this key. `makeDefault` is true when this login is the one `login` uses with no name.
    case write(key: String, makeDefault: Bool)
    /// Saved logins already exist and the terminal should ask.
    case choose
    /// The name is already saved and the terminal should ask before replacing it.
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

/// An answer to the set menu: update one saved login, or create a named one.
public enum LoginSetChoice: Equatable, Sendable {
    case update(key: String)
    case create
}

/// The rules for the default login, names, and sharing one app across bundle ids.
public enum LoginDirectory {
    public static func setIntent(entries: [any LoginMark], name: String?, update: Bool, interactive: Bool) -> LoginSetIntent {
        if entries.isEmpty {
            if let name { return .write(key: name, makeDefault: true) }
            return .write(key: LoginCredential.defaultAccountKey, makeDefault: true)
        }
        if let name {
            if let existing = entries.first(where: { $0.key == name }) {
                guard update else {
                    if interactive { return .confirm(key: name, makeDefault: existing.isDefault) }
                    return .refused("The name \(LoginCredential.displayKey(name)) is already saved for this app. Pass --update to replace it. Nothing was saved.")
                }
                return .write(key: name, makeDefault: existing.isDefault)
            }
            if name == LoginCredential.defaultAccountKey {
                return .refused(
                    "default names only a login saved without a name, and only an app's first login is saved that way. "
                        + "This app has named logins (\(names(entries))): pass one of those names with --update to replace it, or a new name to add one. Nothing was saved."
                )
            }
            return .write(key: name, makeDefault: false)
        }
        if update {
            if let marked = entries.first(where: \.isDefault) {
                return .write(key: marked.key, makeDefault: true)
            }
            if entries.count == 1, let only = entries.first {
                return .write(key: only.key, makeDefault: true)
            }
            let names = entries.map { LoginCredential.displayKey($0.key) }.joined(separator: ", ")
            return .refused("Several logins are saved for this app (\(names)) and none is the default. Pass the name to update. Nothing was saved.")
        }
        if interactive { return .choose }
        return .refused("This app already has a saved login. Pass --update to replace the default, or a name such as qa to add another. Nothing was saved.")
    }

    /// Why `default` matched nothing: no login of the app was saved without a name. Lists names, never usernames.
    public static func noUnnamedLogin(app: String, entries: [any LoginMark]) -> String {
        "No login named default is saved for \(app); default names only a login saved without a name. "
            + "Omit the name to use the default, or pass a saved name: \(names(entries))."
    }

    /// Up to five saved names, then how many more.
    public static func names(_ entries: [any LoginMark]) -> String {
        let shown = entries.prefix(5).map { LoginCredential.displayKey($0.key) }.joined(separator: ", ")
        return entries.count > 5 ? "\(shown) and \(entries.count - 5) more" : shown
    }

    /// True when adding another login should mark the sole existing one as the default.
    public static func shouldStampDefault(_ entries: [any LoginMark], writing key: String) -> String? {
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
        // A person always picks, even when only one app has logins.
        if interactive { return .choose }
        let names = groups.map(\.canonical).joined(separator: ", ")
        return .refused("Apps with saved logins: \(names). Pass --app with the one to share. Nothing was linked.")
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

extension CredentialScreen {
    /// The question `credential join` asks a person, naming both ids.
    public static func linkTitle(member: String, canonical: String) -> String {
        "Link \(member) to \(canonical)?"
    }

    public static let linkOptions = ["🔗  Link", "❌  Cancel"]
}
