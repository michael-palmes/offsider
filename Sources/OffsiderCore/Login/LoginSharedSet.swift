import Foundation

/// One app's part of a login saved to several apps at once.
public struct LoginSharedWrite: Equatable, Sendable {
    public var app: String
    public var key: String
    /// True when this login becomes the one `login` uses with no name for this app.
    public var makeDefault: Bool
    /// True when the app already had a login under `key`.
    public var replaces: Bool
    /// The app's sole earlier login, marked as its default before this one is added.
    public var stampDefault: String?

    public init(app: String, key: String, makeDefault: Bool, replaces: Bool, stampDefault: String? = nil) {
        self.app = app
        self.key = key
        self.makeDefault = makeDefault
        self.replaces = replaces
        self.stampDefault = stampDefault
    }
}

/// A saved name and the apps, of those being saved to, that hold it.
public struct LoginSharedName: Equatable, Sendable {
    public var key: String
    public var apps: [String]

    public init(key: String, apps: [String]) {
        self.key = key
        self.apps = apps
    }
}

/// What `credential add` with several apps should do before it asks for a password.
public enum LoginSharedSetIntent: Equatable, Sendable {
    case write([LoginSharedWrite])
    /// Some app has saved logins and no name was given: the terminal asks to update one or add another.
    case choose([LoginSharedName])
    /// The name is saved for these apps: the terminal asks before replacing it there.
    case confirm(key: String, apps: [String])
    /// A message for the user. Nothing is saved.
    case refused(String)
}

extension LoginDirectory {
    /// The same rules as `setIntent`, for one login saved to every app in `apps` under one name.
    /// An app that lacks the name gets it as a new login; `update` replaces it where it is saved.
    public static func sharedSetIntent(apps: [(app: String, entries: [any LoginMark])], name: String?, update: Bool, interactive: Bool) -> LoginSharedSetIntent {
        let saved = sharedNames(apps)
        let key: String
        if let name {
            key = name
        } else if saved.isEmpty {
            key = LoginCredential.defaultAccountKey
        } else if update {
            let defaults = Set(apps.compactMap { defaultKey($0.entries) })
            guard defaults.count == 1, let only = defaults.first else {
                return .refused("These apps have different default logins, or none. Pass the name to update. Nothing was saved.")
            }
            key = only
        } else if interactive {
            return .choose(saved)
        } else {
            return .refused("These apps already have saved logins. Pass --update to replace the default, or a name such as qa to add another. Nothing was saved.")
        }
        let holding = apps.filter { $0.entries.contains { $0.key == key } }.map(\.app)
        if !holding.isEmpty, !update {
            if interactive { return .confirm(key: key, apps: holding) }
            return .refused("The name \(LoginCredential.displayKey(key)) is already saved for \(list(holding)). Pass --update to replace it. Nothing was saved.")
        }
        var writes: [LoginSharedWrite] = []
        for (app, entries) in apps {
            let existing = entries.first { $0.key == key }
            if existing == nil, key == LoginCredential.defaultAccountKey, !entries.isEmpty {
                return .refused(
                    "default names only a login saved without a name, and \(app) has named logins (\(names(entries))). Pass a name to add one. Nothing was saved."
                )
            }
            writes.append(LoginSharedWrite(
                app: app, key: key, makeDefault: entries.isEmpty || existing?.isDefault == true, replaces: existing != nil,
                stampDefault: shouldStampDefault(entries, writing: key)
            ))
        }
        return .write(writes)
    }

    /// Every saved name across `apps`, in the order the apps and their entries come, with the apps that hold each.
    static func sharedNames(_ apps: [(app: String, entries: [any LoginMark])]) -> [LoginSharedName] {
        var names: [LoginSharedName] = []
        for (app, entries) in apps {
            for entry in entries {
                if let index = names.firstIndex(where: { $0.key == entry.key }) {
                    names[index].apps.append(app)
                } else {
                    names.append(LoginSharedName(key: entry.key, apps: [app]))
                }
            }
        }
        return names
    }

    /// The login `login` uses with no name: the marked one, else the only one.
    static func defaultKey(_ entries: [any LoginMark]) -> String? {
        entries.first(where: \.isDefault)?.key ?? (entries.count == 1 ? entries[0].key : nil)
    }

    /// `a`, `a and b`, or `a, b and c`.
    public static func list(_ items: [String]) -> String {
        items.count > 1 ? items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1] : items.joined()
    }
}

/// An app `credential add` offers to save a login for, and why.
public struct LoginAppChoice: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Named by offsider.login.json.
        case profile
        /// In front on a running simulator or emulator with this name.
        case front(device: String)
        /// Already has saved logins.
        case saved
    }

    public var id: String
    /// Nil when nothing says which platform the id belongs to.
    public var platform: DevicePlatform?
    public var source: Source
    public var ticked: Bool

    public init(id: String, platform: DevicePlatform?, source: Source, ticked: Bool) {
        self.id = id
        self.platform = platform
        self.source = source
        self.ticked = ticked
    }
}

/// The apps `credential add` offers when the person names none.
public enum LoginAppPicker {
    /// offsider.login.json's ids, then the apps in front on running simulators and emulators, then the apps with saved logins.
    /// The file's ids are ticked; without them, the apps in front are. Browsers and system apps are never offered.
    public static func choices(
        profile: LoginProfile?, front: [(app: String, platform: DevicePlatform, device: String)], saved: [String]
    ) -> [LoginAppChoice] {
        var choices: [LoginAppChoice] = []
        func add(_ id: String, _ platform: DevicePlatform?, _ source: LoginAppChoice.Source) {
            let platforms = platform.map { [$0] } ?? DevicePlatform.allCases
            guard !platforms.contains(where: { SystemAppDenyList.isDenied(id, platform: $0) }) else { return }
            if let index = choices.firstIndex(where: { $0.id == id }) {
                if choices[index].platform == nil { choices[index].platform = platform }
                return
            }
            choices.append(LoginAppChoice(id: id, platform: platform, source: source, ticked: false))
        }
        if let bundle = profile?.bundleID { add(bundle, .ios, .profile) }
        if let package = profile?.package { add(package, .android, .profile) }
        let named = !choices.isEmpty
        for app in front { add(app.app, app.platform, .front(device: app.device)) }
        for app in saved { add(app, nil, .saved) }
        for index in choices.indices {
            choices[index].ticked = named ? choices[index].source == .profile : choices[index].source != .saved
        }
        return choices
    }

    /// The app ids in a typed answer, split at spaces and commas.
    public static func typed(_ answer: String) -> [String] {
        answer.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }
}
