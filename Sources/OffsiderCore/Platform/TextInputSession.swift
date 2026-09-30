import Foundation

/// Optional session capability: the backend picks key events or a paste, and accepts any Unicode.
@MainActor
public protocol TextInputSession: InputSession {
    func typeText(_ text: String) async throws
}
