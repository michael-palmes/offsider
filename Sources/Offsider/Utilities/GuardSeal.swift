import CryptoKit
import Foundation
import OffsiderCore
import Security

/// What `guard approve` keeps beside `guards.json`: its SHA-256 and the apps it covered, so an edit or a deletion made outside Offsider is noticed.
struct GuardSealRecord: Equatable, Sendable {
    var digest: Data
    var apps: [String]

    init(data: Data, apps: [String]) {
        self.digest = Data(SHA256.hash(data: data))
        self.apps = apps.sorted()
    }

    init?(encoded: Data) {
        guard let fields = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
              let digest = (fields["digest"] as? String).flatMap({ Data(base64Encoded: $0) }), let apps = fields["apps"] as? [String] else {
            return nil
        }
        self.digest = digest
        self.apps = apps
    }

    var encoded: Data {
        (try? JSONSerialization.data(withJSONObject: ["digest": digest.base64EncodedString(), "apps": apps], options: .sortedKeys)) ?? Data()
    }
}

protocol GuardSealing: Sendable {
    /// The stored record, or nil when no seal exists.
    func stored() throws -> GuardSealRecord?
    func store(_ record: GuardSealRecord) throws
}

extension GuardSealing {
    /// Intact when the file matches the seal, or when there is neither. `apps` are those a broken seal still covers.
    func check(_ snapshot: GuardApprovalsSnapshot) -> (intact: Bool, apps: [String]) {
        guard let record = try? stored() else { return (snapshot.approvals.isEmpty, snapshot.approvals.apps) }
        if record.digest == GuardSealRecord(data: snapshot.data, apps: []).digest { return (true, []) }
        return (false, Array(Set(record.apps + snapshot.approvals.apps)).sorted())
    }
}

/// A login-Keychain generic password, never synchronised, as `KeychainDeviceAllowListSeal`: the record sits in its generic attribute, which reads without a prompt.
struct KeychainGuardSeal: GuardSealing {
    static let service = "com.mpalmes.offsider.guards"
    static let account = "guards"

    func stored() throws -> GuardSealRecord? {
        var query = Self.query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = item as? [String: Any] else { throw Self.failure("read", status) }
        return (attributes[kSecAttrGeneric as String] as? Data).flatMap(GuardSealRecord.init(encoded:))
    }

    func store(_ record: GuardSealRecord) throws {
        let deleted = SecItemDelete(Self.query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Self.failure("replace", deleted) }
        var item = Self.query
        item[kSecAttrGeneric as String] = record.encoded
        item[kSecValueData as String] = Data()
        item[kSecAttrLabel as String] = "Offsider app guard seal"
        item[kSecAttrDescription as String] = "SHA-256 of ~/.config/offsider/guards.json"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.failure("save", added) }
    }

    /// Security takes untyped dictionaries.
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static func failure(_ operation: String, _ status: OSStatus) -> CLIError {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return CLIError(errorDescription: "Could not \(operation) the app guard seal in the login Keychain: \(message).", reason: .commandFailed)
    }
}
