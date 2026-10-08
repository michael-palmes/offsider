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
    /// Account key of the untagged default login. It is not a tag a person can pass.
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

    /// The word shown for a stored key. The untagged slot is `default`.
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

    public func storageData() -> Data {
        let object = ["username": username, "password": password]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public init?(storageData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: storageData) as? [String: String],
              let username = object["username"],
              let password = object["password"]
        else { return nil }
        self.init(username: username, password: password)
    }
}

/// A saved credential as `status` may print it: the key and the username, never the password.
public struct LoginCredentialSummary: Equatable, Sendable {
    public var key: String
    public var username: String
    /// True for the login `login` uses when no tag is passed.
    public var isDefault: Bool

    public init(key: String, username: String, isDefault: Bool = false) {
        self.key = key
        self.username = username
        self.isDefault = isDefault
    }
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
