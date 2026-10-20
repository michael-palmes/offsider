import Foundation

/// A short name for one saved sign-in, such as `dev`. It is not a secret.
public struct LoginKey: Equatable, Sendable, RawRepresentable {
    public let rawValue: String

    public init?(rawValue: String) {
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(text.count), let first = text.unicodeScalars.first else { return nil }
        let letters = (65...90).contains(first.value) || (97...122).contains(first.value)
        let digits = (48...57).contains(first.value)
        guard letters || digits else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard text.compare("default", options: .caseInsensitive) != .orderedSame else { return nil }
        self.rawValue = text
    }
}

/// A test username and password. Printing the value withholds both, so neither reaches a log or an error.
public struct LoginCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let usernameLengths = 1...254
    public static let passwordLengths = 1...128
    /// Splits the Keychain account into the app id and the key. Neither id uses this character.
    public static let accountSeparator: Character = "\u{1}"
    /// Account key of the unnamed default login. It is not a name a person can pass.
    public static let defaultAccountKey = "*"
    /// First character of a Keychain account that links another bundle id to an app. It stores no password.
    public static let linkMark: Character = "\u{2}"

    public let username: String
    public let password: String

    /// Nil unless both values are printable US-keyboard text `type` can send. The username is trimmed. The password is not.
    public init?(username: String, password: String) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.usernameLengths.contains(username.count), TextToHIDEvents.validateText(username) else { return nil }
        guard Self.passwordLengths.contains(password.count), TextToHIDEvents.validateText(password) else { return nil }
        self.username = username
        self.password = password
    }

    public var description: String { "<credential withheld>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public static func account(app: String, key: String) -> String {
        app + String(accountSeparator) + key
    }

    public static func linkAccount(member: String) -> String {
        String(linkMark) + member
    }

    /// The word shown for a stored key. The unnamed slot is `default`.
    public static func displayKey(_ key: String) -> String {
        key == defaultAccountKey ? "default" : key
    }

    /// Nil when `account` is not an app id and a login key. A link account is not a credential.
    public static func parseAccount(_ account: String) -> (app: String, key: String)? {
        let parts = account.split(separator: accountSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        if parts[1] == defaultAccountKey || LoginKey(rawValue: parts[1]) != nil {
            return (parts[0], parts[1])
        }
        return nil
    }

    public static func linkedMember(_ account: String) -> String? {
        guard let first = account.first, first == linkMark else { return nil }
        let member = String(account.dropFirst())
        guard !member.isEmpty else { return nil }
        return member
    }

    /// Version 2 data with default settings. A save that keeps settings goes through `StoredLogin`.
    public func storageData() -> Data {
        StoredLogin(credential: self).storageData()
    }

    /// Reads version 1 or 2 data.
    public init?(storageData: Data) {
        guard let stored = StoredLogin(storageData: storageData) else { return nil }
        self = stored.credential
    }
}

/// Which devices a saved login may be typed into. `virtual` means simulators and emulators.
public enum LoginDeviceScope: String, Equatable, Sendable, CaseIterable {
    case virtual
    case any
}

/// A saved login's encrypted data: the credential and the settings only a person may loosen.
/// `links` are the other app ids a person confirmed with `credential join`; the unencrypted link items are only an index.
public struct StoredLogin: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let version = 2

    public var credential: LoginCredential
    /// Sorted and unique.
    public private(set) var links: [String]
    /// `login` asks for Touch ID or the login password before it reads or types this login.
    public var confirm: Bool
    public var devices: LoginDeviceScope
    /// A person allowed typing into a web view, which also needs `webLogin` in `offsider.login.json`.
    public var webLogin: Bool

    public init(credential: LoginCredential, links: [String] = [], confirm: Bool = false, devices: LoginDeviceScope = .virtual, webLogin: Bool = false) {
        self.credential = credential
        self.links = Set(links).sorted()
        self.confirm = confirm
        self.devices = devices
        self.webLogin = webLogin
    }

    public var description: String { "<saved login withheld>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    public mutating func link(_ member: String) {
        links = Set(links + [member]).sorted()
    }

    public mutating func unlink(_ member: String) {
        links.removeAll { $0 == member }
    }

    /// `{"v":2,"username","password","links","confirm","devices","webLogin"}`.
    public func storageData() -> Data {
        let object: [String: Any] = [
            "v": Self.version,
            "username": credential.username,
            "password": credential.password,
            "links": links,
            "confirm": confirm,
            "devices": devices.rawValue,
            "webLogin": webLogin,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Version 1 (`{"username","password"}`) reads with no links, no confirmation and virtual devices only. A newer version is nil.
    public init?(storageData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: storageData) as? [String: Any],
              let username = object["username"] as? String,
              let password = object["password"] as? String,
              let credential = LoginCredential(username: username, password: password)
        else { return nil }
        guard let version = object["v"] else {
            self.init(credential: credential)
            return
        }
        guard let number = version as? Int, number == Self.version else { return nil }
        guard let links = (object["links"] ?? [String]()) as? [String],
              let confirm = Self.flag(object["confirm"]),
              let devices = LoginDeviceScope(rawValue: object["devices"] as? String ?? LoginDeviceScope.virtual.rawValue),
              let webLogin = Self.flag(object["webLogin"])
        else { return nil }
        self.init(credential: credential, links: links, confirm: confirm, devices: devices, webLogin: webLogin)
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let value else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// `--devices`, `--confirm`/`--no-confirm` and `--web-login`/`--no-web-login` on `credential set` or `describe`.
public struct LoginSettingsEdit: Equatable, Sendable {
    public var devices: LoginDeviceScope?
    public var confirm: Bool?
    public var webLogin: Bool?

    public init(devices: LoginDeviceScope? = nil, confirm: Bool? = nil, webLogin: Bool? = nil) {
        self.devices = devices
        self.confirm = confirm
        self.webLogin = webLogin
    }

    public var isEmpty: Bool { devices == nil && confirm == nil && webLogin == nil }

    /// What this edit lets an agent do that it could not before, as phrases for the person confirming it. Empty when it only tightens.
    public var loosening: [String] {
        var phrases: [String] = []
        if devices == .any { phrases.append("be typed on physical devices") }
        if confirm == false { phrases.append("be typed without asking you first") }
        if webLogin == true { phrases.append("be typed into web views") }
        return phrases
    }

    /// `--devices any` turns confirmation on unless `--no-confirm` came with it.
    public func applied(to stored: StoredLogin) -> StoredLogin {
        var next = stored
        if let devices {
            next.devices = devices
            if devices == .any, confirm == nil { next.confirm = true }
        }
        if let confirm { next.confirm = confirm }
        if let webLogin { next.webLogin = webLogin }
        return next
    }
}

/// A saved credential as `status` may print it: the key and the username, never the password.
public struct LoginCredentialSummary: Equatable, Sendable {
    public var key: String
    public var username: String
    /// True for the login `login` uses when no name is passed.
    public var isDefault: Bool

    public init(key: String, username: String, isDefault: Bool = false) {
        self.key = key
        self.username = username
        self.isDefault = isDefault
    }
}

/// A saved login's key and default mark, which is all `credential set` weighs before it asks for a password.
public protocol LoginMark {
    var key: String { get }
    var isDefault: Bool { get }
}

extension LoginCredentialSummary: LoginMark {}
extension LoginEntry: LoginMark {}

/// A saved login as its Keychain attributes describe it: the key, the default mark and the context, never the username.
public struct LoginEntry: Equatable, Sendable {
    public var key: String
    /// The stored mark only. A sole unmarked login is still the default at login time.
    public var isDefault: Bool
    public var stored: LoginContextRead

    public init(key: String, isDefault: Bool = false, stored: LoginContextRead = .saved(.empty)) {
        self.key = key
        self.isDefault = isDefault
        self.stored = stored
    }

    public init(key: String, isDefault: Bool = false, context: LoginContext) {
        self.init(key: key, isDefault: isDefault, stored: .saved(context))
    }

    /// Empty when the stored context is damaged or from a newer Offsider.
    public var context: LoginContext {
        if case .saved(let context) = stored { return context }
        return .empty
    }

    /// The word a person passes, and `default` for the unnamed slot.
    public var name: String { LoginCredential.displayKey(key) }
}

/// One app's saved logins, and the other bundle ids that share them.
public struct LoginAppGroup: Equatable, Sendable {
    public var canonical: String
    public var members: [String]

    public init(canonical: String, members: [String]) {
        self.canonical = canonical
        self.members = members
    }
}
