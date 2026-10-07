import Foundation
import OffsiderCore
import Security

/// Where `login` finds a test username and password, keyed by the app and a short key.
protocol LoginCredentialStoring {
    func load(app: String, key: String) throws -> LoginCredential?
    /// Every saved credential for one app, username included, password dropped before return.
    /// `isDefault` is the stored mark only. A sole unmarked login is still the default at login time.
    func list(app: String) throws -> [LoginCredentialSummary]
    /// Keys for one app, from the item attributes, so the password is not decrypted.
    func keys(app: String) throws -> [String]
    /// The stored default mark, from item attributes. Nil when none is marked.
    func defaultKey(app: String) throws -> String?
    func save(_ credential: LoginCredential, app: String, key: String, isDefault: Bool) throws
    /// Marks one saved login as the default without reading its password.
    func markDefault(app: String, key: String) throws
    /// False when no credential was saved.
    func remove(app: String, key: String) throws -> Bool
    /// The app id whose logins this id uses. An id that was not joined returns itself.
    func canonical(of app: String) throws -> String
    /// Apps that have at least one saved login, with the other ids joined to each.
    func groups() throws -> [LoginAppGroup]
    /// Records that `member` uses the logins saved for `canonical`. The password is not copied.
    func join(member: String, canonical: String) throws
}

/// The login Keychain's generic passwords, one per app and key, never synchronised.
struct KeychainLoginCredentialStore: LoginCredentialStoring {
    static let service = "com.mpalmes.offsider.login"

    func load(app: String, key: String) throws -> LoginCredential? {
        var query = Self.query(app: app, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LoginKeychainFailure(operation: "read", app: app, key: key, status: status)
        }
        guard let credential = LoginCredential(storageData: data) else {
            throw LoginKeychainFailure(operation: "read", app: app, key: key, detail: Self.corrupt(key))
        }
        return credential
    }

    func list(app: String) throws -> [LoginCredentialSummary] {
        let marked = try defaultKey(app: app)
        var summaries: [LoginCredentialSummary] = []
        for key in try keys(app: app) {
            // A match-all query that also returns secret data is errSecParam, so each item is read on its own.
            guard let credential = try load(app: app, key: key) else { continue }
            summaries.append(LoginCredentialSummary(key: key, username: credential.username, isDefault: marked == key))
        }
        return summaries.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.key < rhs.key
        }
    }

    func keys(app: String) throws -> [String] {
        try Self.items().compactMap { item in
            guard let account = Self.account(item), let parsed = LoginCredential.parseAccount(account), parsed.app == app else {
                return nil
            }
            return parsed.key
        }.sorted()
    }

    func defaultKey(app: String) throws -> String? {
        try Self.items().compactMap { item in
            guard Self.isDefaultLabel(item[kSecAttrLabel as String] as? String), let account = Self.account(item), let parsed = LoginCredential.parseAccount(account), parsed.app == app else {
                return nil
            }
            return parsed.key
        }.sorted().first
    }

    func save(_ credential: LoginCredential, app: String, key: String, isDefault: Bool) throws {
        let data = credential.storageData()
        guard LoginCredential(storageData: data) != nil else {
            throw LoginKeychainFailure(operation: "save", app: app, key: key, detail: Self.corrupt(key))
        }
        let attributes = Self.secretAttributes(data, app: app, key: key, isDefault: isDefault)
        let status = SecItemUpdate(Self.query(app: app, key: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LoginKeychainFailure(operation: "save", app: app, key: key, status: status) }
        var item = Self.query(app: app, key: key)
        attributes.forEach { item[$0.key] = $0.value }
        item[kSecAttrDescription as String] = "Test sign-in credential"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw LoginKeychainFailure(operation: "save", app: app, key: key, status: added) }
    }

    func markDefault(app: String, key: String) throws {
        let status = SecItemUpdate(
            Self.query(app: app, key: key) as CFDictionary,
            Self.secretAttributes(Data(), app: app, key: key, isDefault: true).filter { $0.key != kSecValueData as String } as CFDictionary
        )
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "save", app: app, key: key, status: status) }
    }

    func remove(app: String, key: String) throws -> Bool {
        let status = SecItemDelete(Self.query(app: app, key: key) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "remove", app: app, key: key, status: status) }
        if try keys(app: app).isEmpty { try deleteLinks(to: app) }
        return true
    }

    func canonical(of app: String) throws -> String {
        for item in try Self.items() {
            guard let account = Self.account(item), LoginCredential.linkedMember(account) == app else { continue }
            if let label = item[kSecAttrLabel as String] as? String, !label.isEmpty { return label }
        }
        return app
    }

    func groups() throws -> [LoginAppGroup] {
        var canonicals = Set<String>()
        var members: [String: [String]] = [:]
        for item in try Self.items() {
            guard let account = Self.account(item) else { continue }
            if let member = LoginCredential.linkedMember(account) {
                let canonical = item[kSecAttrLabel as String] as? String ?? ""
                if !canonical.isEmpty { members[canonical, default: []].append(member) }
            } else if let parsed = LoginCredential.parseAccount(account) {
                canonicals.insert(parsed.app)
            }
        }
        return canonicals.sorted().map { app in
            LoginAppGroup(canonical: app, members: (members[app] ?? []).sorted())
        }
    }

    func join(member: String, canonical: String) throws {
        let account = LoginCredential.linkAccount(member: member)
        let query = Self.accountQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrLabel as String: canonical] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LoginKeychainFailure(operation: "link", app: member, key: "", status: status) }
        var item = query
        item[kSecValueData as String] = Data([0])
        item[kSecAttrLabel as String] = canonical
        item[kSecAttrDescription as String] = "Offsider login link"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw LoginKeychainFailure(operation: "link", app: member, key: "", status: added) }
    }

    private static let defaultMark = "default"

    /// The default mark lives in the label, which an attributes query returns. A comment alone may not.
    private static func isDefaultLabel(_ label: String?) -> Bool {
        label?.hasSuffix(", \(defaultMark))") == true
    }

    private static func secretAttributes(_ data: Data, app: String, key: String, isDefault: Bool) -> [String: Any] {
        let mark = isDefault ? ", \(defaultMark)" : ""
        var attributes: [String: Any] = [
            kSecAttrLabel as String: "Offsider login (\(app), \(LoginCredential.displayKey(key))\(mark))",
            kSecAttrComment as String: isDefault ? defaultMark : "",
        ]
        if !data.isEmpty { attributes[kSecValueData as String] = data }
        return attributes
    }

    private static func account(_ item: [String: Any]) -> String? {
        item[kSecAttrAccount as String] as? String
    }

    private func deleteLinks(to canonical: String) throws {
        for item in try Self.items() {
            guard let account = Self.account(item), LoginCredential.linkedMember(account) != nil else { continue }
            guard (item[kSecAttrLabel as String] as? String) == canonical else { continue }
            let status = SecItemDelete(Self.accountQuery(account) as CFDictionary)
            if status == errSecItemNotFound || status == errSecSuccess { continue }
            throw LoginKeychainFailure(operation: "remove", app: canonical, key: "", status: status)
        }
    }

    private static func corrupt(_ key: String) -> String {
        "the saved item for \(key) is not a username and password Offsider can type. Remove it and save it again."
    }

    private static func items() throws -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw LoginKeychainFailure(operation: "read", app: "", key: "", status: status)
        }
        return items
    }

    /// Security takes untyped dictionaries.
    private static func query(app: String, key: String) -> [String: Any] {
        accountQuery(LoginCredential.account(app: app, key: key))
    }

    private static func accountQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

struct LoginKeychainFailure: LocalizedError, UserFacingError, OffsiderFailure {
    let operation: String
    let app: String
    let key: String
    let detail: String

    init(operation: String, app: String, key: String, detail: String) {
        self.operation = operation
        self.app = app
        self.key = key
        self.detail = detail
    }

    init(operation: String, app: String, key: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        let detail = status == errSecUserCanceled || status == errSecAuthFailed
            ? "Keychain access was declined (\(message)); allow it when macOS asks"
            : message
        self.init(operation: operation, app: app, key: key, detail: detail)
    }

    var reason: FailureReason { .commandFailed }

    var failureMessage: String {
        if app.isEmpty, key.isEmpty {
            return "Could not \(operation) login credentials in the login Keychain: \(detail)."
        }
        let which = key.isEmpty ? app : "\(app) key \(key)"
        return "Could not \(operation) the login credential for \(which) in the login Keychain: \(detail)."
    }

    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
