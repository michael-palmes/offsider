import Foundation

/// Secure field values as bullets, one per character, so length survives and nothing else does.
public enum SecureText {
    public static let bullet: Character = "•"

    /// Nil or empty stays nil; otherwise one bullet per grapheme cluster.
    public static func masked(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(repeating: bullet, count: value.count)
    }

    /// A value made only of a mask's dots, as XCTest reports a React Native password field it calls a text field.
    public static func isMaskDots(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { $0 == "\u{2022}" || $0 == "\u{25CF}" }
    }
}

/// Whether a secure field may hold input focus: exact on Android, a proxy on iOS (keyboard plus secure field).
public enum SecureFocus: Equatable, Sendable {
    case none
    case secureFocused
    case securePossible
}

extension UINode {
    public var isSecure: Bool { role == .secureTextField }

    /// An iPhone text field's placeholder, its only name when it has no label or id.
    public var placeholderName: String? {
        guard role.isTextInput, label?.isEmpty != false, id?.isEmpty != false, case .ios(let native) = native else { return nil }
        return native.hint.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension UITree {
    public var secureFocus: SecureFocus {
        let nodes = roots.flatMap { $0.flattened() }
        let secure = nodes.filter(\.isSecure)
        guard !secure.isEmpty else { return .none }
        switch platform {
        case .android:
            return secure.contains { $0.state.focused == true } ? .secureFocused : .none
        case .ios:
            if secure.contains(where: { $0.state.focused == true }) { return .secureFocused }
            return nodes.contains { $0.role == .keyboard } ? .securePossible : .none
        }
    }

    /// Every secure node's frame in every root; nil entries are kept so a caller can refuse to guess.
    public var secureFrames: [UIFrame?] {
        roots.flatMap { $0.flattened() }.filter(\.isSecure).map(\.frame)
    }
}
