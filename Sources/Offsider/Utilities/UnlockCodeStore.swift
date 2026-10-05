import Foundation
import OffsiderCore
import Security

/// Where `wake --unlock` finds a device's PIN or password, keyed by phone serial or AVD name.
protocol UnlockCodeStoring {
    func code(for device: String) throws -> UnlockCode?
    /// Whether a code is saved, without reading it.
    func hasCode(for device: String) throws -> Bool
    func save(_ code: UnlockCode, for device: String) throws
    /// False when no code was saved.
    func remove(for device: String) throws -> Bool
}

/// The login Keychain's generic passwords, one per device, never synchronised.
struct KeychainUnlockCodeStore: UnlockCodeStoring {
    static let service = "com.mpalmes.offsider.unlock-code"

    func code(for device: String) throws -> UnlockCode? {
        var query = Self.query(device)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainFailure(operation: "read", device: device, status: status) }
        guard let code = UnlockCode(String(decoding: data, as: UTF8.self)) else {
            throw KeychainFailure(operation: "read", device: device, detail: "the saved item is not a PIN or password Offsider can type; save it again with `offsider unlock-code set --device \(device)`")
        }
        return code
    }

    /// Asks for the item's attributes only, so the code is never decrypted.
    func hasCode(for device: String) throws -> Bool {
        var query = Self.query(device)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainFailure(operation: "check", device: device, status: status) }
        return true
    }

    func save(_ code: UnlockCode, for device: String) throws {
        let data = Data(code.text.utf8)
        let status = SecItemUpdate(Self.query(device) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure(operation: "save", device: device, status: status) }
        var item = Self.query(device)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Offsider unlock code (\(device))"
        item[kSecAttrDescription as String] = "Android lock screen PIN or password"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainFailure(operation: "save", device: device, status: added) }
    }

    func remove(for device: String) throws -> Bool {
        let status = SecItemDelete(Self.query(device) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainFailure(operation: "remove", device: device, status: status) }
        return true
    }

    /// Security takes untyped dictionaries.
    private static func query(_ device: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: device,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

struct KeychainFailure: LocalizedError, UserFacingError, OffsiderFailure {
    let operation: String
    let device: String
    let detail: String

    init(operation: String, device: String, detail: String) {
        self.operation = operation
        self.device = device
        self.detail = detail
    }

    init(operation: String, device: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        let detail = status == errSecUserCanceled || status == errSecAuthFailed
            ? "Keychain access was declined (\(message)); allow it when macOS asks"
            : message
        self.init(operation: operation, device: device, detail: detail)
    }

    var reason: FailureReason { .commandFailed }
    var failureMessage: String { "Could not \(operation) the unlock code for \(device) in the login Keychain: \(detail)." }
    var userFacingDescription: String { failureMessage }
    var errorDescription: String? { failureMessage }
}
