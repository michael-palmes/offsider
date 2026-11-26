import CryptoKit
import Foundation
import OffsiderCore
import Security

/// Where `devices add` and `remove` keep the SHA-256 of the allow-list, so an edit made outside Offsider is noticed.
protocol DeviceAllowListSealing: Sendable {
    /// The stored digest, or nil when no seal exists.
    func storedDigest() throws -> Data?
    func store(digest: Data) throws
}

extension DeviceAllowListSealing {
    static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Intact when the file matches the seal; a file with no devices needs none. A seal that cannot be read is never intact.
    func isIntact(_ snapshot: DeviceAllowListSnapshot) -> Bool {
        reading(snapshot) == .intact
    }

    /// Tells a seal that cannot be read from one that no longer matches; both refuse.
    func reading(_ snapshot: DeviceAllowListSnapshot) -> SealReading {
        guard !snapshot.list.isEmpty else { return .intact }
        do {
            guard let stored = try storedDigest() else { return .changed }
            return stored == Self.digest(of: snapshot.data) ? .intact : .changed
        } catch {
            return .unreadable(SealReading.detail(of: error))
        }
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

    private static func failure(_ operation: String, _ status: OSStatus) -> SealKeychainFailure {
        SealKeychainFailure(what: "the device allow-list seal", operation: operation, status: status)
    }
}

/// What a seal read found.
enum SealReading: Equatable {
    case intact
    case changed
    /// The Keychain did not answer; the detail says why, such as `the login Keychain is locked`.
    case unreadable(String)

    static func detail(of error: any Error) -> String {
        (error as? SealKeychainFailure)?.detail ?? OffsiderCommand.message(for: error)
    }
}

/// A seal the login Keychain would not read or write, named when it is locked or needs a person.
struct SealKeychainFailure: LocalizedError, UserFacingError, OffsiderFailure {
    let what: String
    let operation: String
    let detail: String
    let reason: FailureReason
    let ask: String?

    init(what: String, operation: String, status: OSStatus) {
        self.what = what
        self.operation = operation
        if let block = KeychainAccess.block(for: status) {
            detail = KeychainAccess.clause(block)
            reason = KeychainAccess.reason(block)
            ask = KeychainAccess.ask(block)
        } else {
            detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            reason = .commandFailed
            ask = nil
        }
    }

    var failureMessage: String { "Could not \(operation) \(what) in the login Keychain: \(detail)." }
    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
