import CryptoKit
import Foundation
import OffsiderCore
import Security

/// Where the digest of `approved-prefixes` is kept, so a prefix written into that file by anything but `runner build` counts as unapproved.
public protocol RunnerPrefixSealing: Sendable {
    /// The stored digest, or nil when no seal exists.
    func storedDigest() throws -> Data?
    func store(digest: Data) throws
}

extension RunnerPrefixSealing {
    static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// True only when a seal exists and matches `data`.
    func seals(_ data: Data) -> Bool {
        guard let stored = try? storedDigest() else { return false }
        return stored == Self.digest(of: data)
    }

    func seal(_ data: Data) throws {
        try store(digest: Self.digest(of: data))
    }
}

/// A login-Keychain generic password, never synchronised, holding the digest in its generic attribute, which reads without a Keychain prompt.
public struct KeychainRunnerPrefixSeal: RunnerPrefixSealing {
    static let service = "com.mpalmes.offsider.runner"
    static let account = "approved-prefixes"

    public init() {}

    public func storedDigest() throws -> Data? {
        var query = Self.query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = item as? [String: Any] else { throw Self.failure("read", status) }
        return attributes[kSecAttrGeneric as String] as? Data
    }

    /// Deletes and adds rather than updating, since changing an item a different build created asks for the login password.
    public func store(digest: Data) throws {
        let deleted = SecItemDelete(Self.query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Self.failure("replace", deleted) }
        var item = Self.query
        item[kSecAttrGeneric as String] = digest
        item[kSecValueData as String] = Data()
        item[kSecAttrLabel as String] = "Offsider runner prefix approvals seal"
        item[kSecAttrDescription as String] = "SHA-256 of ~/Library/Caches/offsider/runner/approved-prefixes"
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

    private static func failure(_ operation: String, _ status: OSStatus) -> IOSDeviceError {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return IOSDeviceError(.runnerBuildFailed, "Offsider could not \(operation) the runner prefix approvals seal in the login Keychain: \(message).")
    }
}
