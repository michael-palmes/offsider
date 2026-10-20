import Foundation
import OffsiderCore
import Security

/// Where `login` finds a test username and password, keyed by the app and a short key.
protocol LoginCredentialStoring {
    /// The decrypted data: the credential and the settings only a person may loosen.
    func loadStored(app: String, key: String) throws -> StoredLogin?
    /// Every saved credential for one app, username included, password dropped before return.
    /// `isDefault` is the stored mark only. A sole unmarked login is still the default at login time.
    func list(app: String) throws -> [LoginCredentialSummary]
    /// Keys for one app, from the item attributes, so the password is not decrypted.
    func keys(app: String) throws -> [String]
    /// The stored default mark, from item attributes. Nil when none is marked.
    func defaultKey(app: String) throws -> String?
    /// Every saved login for one app from the item attributes alone, so no password is decrypted. Default first, then by key.
    func entries(app: String) throws -> [LoginEntry]
    /// Writes version 2 data. A nil `context` keeps the stored one.
    func saveStored(_ stored: StoredLogin, app: String, key: String, isDefault: Bool, context: LoginContext?) throws
    /// Replaces the context without reading the password. False when no login is saved under `key`.
    func setContext(_ context: LoginContext, app: String, key: String) throws -> Bool
    /// Marks one saved login as the default without reading its password.
    func markDefault(app: String, key: String) throws
    /// False when no credential was saved.
    func remove(app: String, key: String) throws -> Bool
    /// The app id whose logins this id uses. An id that was not joined returns itself.
    func canonical(of app: String) throws -> String
    /// Apps that have at least one saved login, with the other ids joined to each.
    func groups() throws -> [LoginAppGroup]
    /// Records that `member` uses the logins saved for `canonical`, in the link index and in every login's encrypted `links`.
    func join(member: String, canonical: String) throws
    /// Stops `member` using them: each login's encrypted `links` first, so a failure part way still types nothing, then the index.
    func unjoin(member: String, canonical: String) throws
}

extension LoginCredentialStoring {
    func load(app: String, key: String) throws -> LoginCredential? {
        try loadStored(app: app, key: key)?.credential
    }

    /// A fresh login with default settings. Use `saveStored` to keep a login's settings.
    func save(_ credential: LoginCredential, app: String, key: String, isDefault: Bool, context: LoginContext? = nil) throws {
        try saveStored(StoredLogin(credential: credential), app: app, key: key, isDefault: isDefault, context: context)
    }
}

/// The login Keychain's generic passwords, one per app and key, never synchronised. The context sits in the unencrypted generic attribute.
struct KeychainLoginCredentialStore: LoginCredentialStoring {
    static let defaultService = "com.mpalmes.offsider.login"

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func loadStored(app: String, key: String) throws -> StoredLogin? {
        var request = query(app: app, key: key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LoginKeychainFailure(operation: "read", app: app, key: key, status: status)
        }
        guard let stored = StoredLogin(storageData: data) else {
            throw LoginKeychainFailure(operation: "read", app: app, key: key, detail: Self.corrupt(key))
        }
        return stored
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
        try items().compactMap { item in
            guard let account = Self.account(item), let parsed = LoginCredential.parseAccount(account), parsed.app == app else {
                return nil
            }
            return parsed.key
        }.sorted()
    }

    func defaultKey(app: String) throws -> String? {
        try items().compactMap { item in
            guard Self.isDefaultLabel(item[kSecAttrLabel as String] as? String), let account = Self.account(item), let parsed = LoginCredential.parseAccount(account), parsed.app == app else {
                return nil
            }
            return parsed.key
        }.sorted().first
    }

    func entries(app: String) throws -> [LoginEntry] {
        try items().compactMap { item -> LoginEntry? in
            guard let account = Self.account(item), let parsed = LoginCredential.parseAccount(account), parsed.app == app else {
                return nil
            }
            let marked = Self.isDefaultLabel(item[kSecAttrLabel as String] as? String)
            return LoginEntry(key: parsed.key, isDefault: marked, stored: LoginContext.read(item[kSecAttrGeneric as String] as? Data))
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.key < rhs.key
        }
    }

    func saveStored(_ stored: StoredLogin, app: String, key: String, isDefault: Bool, context: LoginContext?) throws {
        let data = stored.storageData()
        guard StoredLogin(storageData: data) == stored else {
            throw LoginKeychainFailure(operation: "save", app: app, key: key, detail: Self.corrupt(key))
        }
        var attributes = Self.secretAttributes(data, app: app, key: key, isDefault: isDefault)
        if let context { attributes[kSecAttrGeneric as String] = context.storageData() }
        let status = SecItemUpdate(query(app: app, key: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LoginKeychainFailure(operation: "save", app: app, key: key, status: status) }
        var item = query(app: app, key: key)
        attributes.forEach { item[$0.key] = $0.value }
        item[kSecAttrDescription as String] = "Test sign-in credential"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw LoginKeychainFailure(operation: "save", app: app, key: key, status: added) }
    }

    func setContext(_ context: LoginContext, app: String, key: String) throws -> Bool {
        let status = SecItemUpdate(query(app: app, key: key) as CFDictionary, [kSecAttrGeneric as String: context.storageData()] as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "update", app: app, key: key, status: status) }
        return true
    }

    func markDefault(app: String, key: String) throws {
        let status = SecItemUpdate(
            query(app: app, key: key) as CFDictionary,
            Self.secretAttributes(Data(), app: app, key: key, isDefault: true).filter { $0.key != kSecValueData as String } as CFDictionary
        )
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "save", app: app, key: key, status: status) }
    }

    func remove(app: String, key: String) throws -> Bool {
        let status = SecItemDelete(query(app: app, key: key) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "remove", app: app, key: key, status: status) }
        if try keys(app: app).isEmpty { try deleteLinks(to: app) }
        return true
    }

    func canonical(of app: String) throws -> String {
        for item in try items() {
            guard let account = Self.account(item), LoginCredential.linkedMember(account) == app else { continue }
            if let label = item[kSecAttrLabel as String] as? String, !label.isEmpty { return label }
        }
        return app
    }

    func groups() throws -> [LoginAppGroup] {
        var canonicals = Set<String>()
        var members: [String: [String]] = [:]
        for item in try items() {
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
        for key in try keys(app: canonical) {
            guard var stored = try loadStored(app: canonical, key: key) else { continue }
            stored.link(member)
            let status = SecItemUpdate(query(app: canonical, key: key) as CFDictionary, [kSecValueData as String: stored.storageData()] as CFDictionary)
            guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "link", app: canonical, key: key, status: status) }
        }
        let account = LoginCredential.linkAccount(member: member)
        let query = accountQuery(account)
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

    func unjoin(member: String, canonical: String) throws {
        for key in try keys(app: canonical) {
            guard var stored = try loadStored(app: canonical, key: key), stored.links.contains(member) else { continue }
            stored.unlink(member)
            let status = SecItemUpdate(query(app: canonical, key: key) as CFDictionary, [kSecValueData as String: stored.storageData()] as CFDictionary)
            guard status == errSecSuccess else { throw LoginKeychainFailure(operation: "unlink", app: canonical, key: key, status: status) }
        }
        let status = SecItemDelete(accountQuery(LoginCredential.linkAccount(member: member)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LoginKeychainFailure(operation: "unlink", app: member, key: "", status: status) }
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
        for item in try items() {
            guard let account = Self.account(item), LoginCredential.linkedMember(account) != nil else { continue }
            guard (item[kSecAttrLabel as String] as? String) == canonical else { continue }
            let status = SecItemDelete(accountQuery(account) as CFDictionary)
            if status == errSecItemNotFound || status == errSecSuccess { continue }
            throw LoginKeychainFailure(operation: "remove", app: canonical, key: "", status: status)
        }
    }

    private static func corrupt(_ key: String) -> String {
        "the saved item for \(key) is not a username and password Offsider can type. Remove it and save it again."
    }

    private func items() throws -> [[String: Any]] {
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
    private func query(app: String, key: String) -> [String: Any] {
        accountQuery(LoginCredential.account(app: app, key: key))
    }

    private func accountQuery(_ account: String) -> [String: Any] {
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
        let detail = Self.declined.contains(status)
            ? "Keychain access was declined (\(message)); allow it when macOS asks"
            : message
        self.init(operation: operation, app: app, key: key, detail: detail)
    }

    /// errAuthorizationInternal (-60008) arrives while another Keychain prompt is still waiting.
    static let declined: Set<OSStatus> = [errSecUserCanceled, errSecAuthFailed, -60008]

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
