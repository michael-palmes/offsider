import Foundation

/// React Native on iOS writes the role and state words into an `Other`'s accessibility value, such as `checkbox, unchecked`.
public enum ReactNativeAXValue {
    public struct Parsed: Equatable, Sendable {
        public let role: UIRole
        /// From a `checked` or `unchecked` word; nil when neither was written.
        public let checked: Bool?
        public let mixed: Bool
        /// Loose state words and the app's own value, joined with ", ".
        public let value: String?
    }

    /// Every head React Native writes; nil marks a head with no Offsider role, left as an `other` with its value.
    static let heads: [String: UIRole?] = [
        "checkbox": .checkbox,
        "radio button": .radioButton,
        "switch": .switch,
        "tab": .tab,
        "tab list": .tabBar,
        "menu item": .menuItem,
        "combo box": .picker,
        "progress bar": .progress,
        "radio group": .group,
        "alert": nil,
        "menu": nil,
        "menu bar": nil,
        "scroll bar": nil,
        "spin button": nil,
        "timer": nil,
        "tool bar": nil,
    ]

    private static let looseWords: Set<String> = ["mixed", "expanded", "collapsed", "busy"]

    public static func parse(_ value: String?) -> Parsed? {
        guard let value else { return nil }
        let parts = value.components(separatedBy: ", ")
        guard let head = heads[parts[0].lowercased()], let role = head else { return nil }
        var checked: Bool?
        var mixed = false
        var kept: [String] = []
        var position = 1
        while position < parts.count {
            let word = parts[position].lowercased()
            if word == "checked" {
                checked = true
            } else if word == "unchecked" {
                checked = false
            } else if looseWords.contains(word) {
                if word == "mixed" { mixed = true }
                kept.append(parts[position])
            } else {
                break
            }
            position += 1
        }
        let rest = Array(parts[position...])
        if role == .group {
            return Parsed(role: role, checked: nil, mixed: false, value: nil)
        }
        if role.isToggle {
            let text = rest.joined(separator: ", ")
            if !text.isEmpty {
                return Parsed(role: role, checked: checked, mixed: mixed, value: text)
            }
            return Parsed(role: role, checked: checked, mixed: mixed, value: toggleValue(checked: checked, mixed: mixed))
        }
        let text = (kept + rest).joined(separator: ", ")
        return Parsed(role: role, checked: checked, mixed: mixed, value: text.isEmpty ? nil : text)
    }
}

extension ReactNativeAXValue {
    /// `2` for mixed, else `1` or `0`, as Android reports toggles.
    static func toggleValue(checked: Bool?, mixed: Bool) -> String? {
        mixed ? "2" : checked.map { $0 ? "1" : "0" }
    }
}

extension UIRole {
    /// Roles whose value Android reports as `1`, `0` or `2`.
    var isToggle: Bool { self == .checkbox || self == .radioButton || self == .switch }
}
