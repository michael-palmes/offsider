import CryptoKit
import Foundation
import OffsiderCore
import Security

/// Where `device-access` keeps the SHA-256 of the allow-list, so an edit made outside Offsider is noticed.
protocol DeviceAllowListSealing: Sendable {
    /// The stored digest, or nil when no seal exists.
    func storedDigest() throws -> Data?
    func store(digest: Data) throws
}

extension DeviceAllowListSealing {
    static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Intact when the file matches the seal; a file with no devices needs none.
    func isIntact(_ snapshot: DeviceAllowListSnapshot) -> Bool {
        guard let stored = try? storedDigest() else { return snapshot.list.entries.isEmpty }
        return stored == Self.digest(of: snapshot.data) || snapshot.list.entries.isEmpty
    }

    func seal(_ data: Data) throws {
        try store(digest: Self.digest(of: data))
    }
}

/// A login-Keychain generic password, never synchronised. The digest sits in its generic attribute, which reads without a Keychain prompt.
struct KeychainDeviceAllowListSeal: DeviceAllowListSealing {
    static let service = "com.mpalmes.offsider.devices"
    static let account = "allowed-devices"

    func storedDigest() throws -> Data? {
        var query = Self.query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = item as? [String: Any] else { throw Self.failure("read", status) }
        return attributes[kSecAttrGeneric as String] as? Data
    }

    /// Deletes and adds rather than updating, since changing an item a different build created asks for the login password.
    func store(digest: Data) throws {
        let deleted = SecItemDelete(Self.query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Self.failure("replace", deleted) }
        var item = Self.query
        item[kSecAttrGeneric as String] = digest
        item[kSecValueData as String] = Data()
        item[kSecAttrLabel as String] = "Offsider device allow-list seal"
        item[kSecAttrDescription as String] = "SHA-256 of ~/.config/offsider/allowed-devices.json"
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
        return CLIError(errorDescription: "Could not \(operation) the device allow-list seal in the login Keychain: \(message).", reason: .commandFailed)
    }
}
