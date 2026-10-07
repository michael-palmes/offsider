import Foundation

/// Maps the iOS accessibility JSON from idb onto neutral `UINode`s.
public enum IOSAccessibilityMapping {
    public enum MappingError: Error, Equatable, Sendable {
        case notAnAccessibilityTree
    }

    private static let rolesByType: [String: UIRole] = [
        "Application": .application,
        "Window": .window,
        "Button": .button,
        "PopUpButton": .button,
        "Link": .link,
        "MenuItem": .menuItem,
        "Tab": .tab,
        "TabBarButton": .tab,
        "TabBar": .tabBar,
        "SegmentedControl": .segmentedControl,
        "CheckBox": .checkbox,
        "RadioButton": .radioButton,
        "TextField": .textField,
        "SecureTextField": .secureTextField,
        "SearchField": .searchField,
        "TextView": .textArea,
        "TextEditor": .textArea,
        "StaticText": .text,
        "Image": .image,
        "Cell": .cell,
        "Table": .list,
        "CollectionView": .list,
        "ScrollView": .scrollView,
        "ScrollArea": .scrollView,
        "NavigationBar": .header,
        "Heading": .header,
        "Picker": .picker,
        "PickerWheel": .picker,
        "ProgressIndicator": .progress,
        "ActivityIndicator": .progress,
        "Keyboard": .keyboard,
        "Key": .keyboard,
        "Group": .group,
    ]

    /// iOS 27 simulators list no Keyboard element; the software keyboard's keys sit in a group with this id prefix (`UIKeyboardLayoutStar Preview`).
    static let keyboardLayoutPrefix = "UIKeyboardLayout"

    public static func roots(fromJSON data: Data) throws -> [UINode] {
        try tree(fromJSON: data).roots
    }

    /// The roots, and whether the source cut its tree short (a root's `truncated: true`, as the device runner sends).
    public static func tree(fromJSON data: Data) throws -> (roots: [UINode], truncated: Bool) {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let dictionaries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            dictionaries = array
        } else if let dictionary = object as? [String: Any] {
            dictionaries = [dictionary]
        } else {
            throw MappingError.notAnAccessibilityTree
        }
        return (dictionaries.map(node(from:)), dictionaries.contains { $0["truncated"] as? Bool == true })
    }

    public static func node(from dictionary: [String: Any]) -> UINode {
        let type = text(dictionary["type"])
        let nativeRole = text(dictionary["role"])
        let subrole = text(dictionary["subrole"])
        let roleDescription = text(dictionary["role_description"])
        let id = text(dictionary["AXUniqueId"]) ?? text(dictionary["AXIdentifier"])
        var role = role(type: type, role: nativeRole, subrole: subrole, roleDescription: roleDescription)
        if role == .group, id?.hasPrefix(keyboardLayoutPrefix) == true {
            role = .keyboard
        }
        let raw = text(dictionary["AXValue"])
        var value = role == .secureTextField ? SecureText.masked(raw) : raw
        let traits = (dictionary["traits"] as? [Any] ?? []).compactMap(text)
        let selected: Bool? = traits.contains("Selected") ? true : nil
        var checked: Bool?
        if role == .other, let parsed = ReactNativeAXValue.parse(raw) {
            role = parsed.role
            checked = parsed.mixed ? nil : parsed.checked ?? (role == .radioButton ? selected : nil)
            value = parsed.value ?? (role.isToggle ? ReactNativeAXValue.toggleValue(checked: checked, mixed: false) : nil)
        } else {
            checked = self.checked(role: role, value: value)
        }

        return UINode(
            role: role,
            id: id,
            label: text(dictionary["AXLabel"]),
            value: value,
            frame: frame(dictionary["frame"]),
            enabled: dictionary["enabled"] as? Bool,
            state: UIState(checked: checked, selected: selected, focused: dictionary["focused"] as? Bool == true ? true : nil),
            native: .ios(IOSNativeAttributes(
                type: type,
                role: nativeRole,
                subrole: subrole,
                roleDescription: roleDescription,
                title: text(dictionary["title"]),
                help: text(dictionary["help"]),
                customActions: (dictionary["custom_actions"] as? [Any] ?? []).compactMap(text),
                contentRequired: dictionary["content_required"] as? Bool,
                pid: (dictionary["pid"] as? NSNumber)?.intValue,
                axFrame: text(dictionary["AXFrame"])
            )),
            children: (dictionary["children"] as? [[String: Any]] ?? []).map(node(from:))
        )
    }

    /// Switch, slider and secure checks run first: SwiftUI reports some switches as CheckBox or Other, and a SecureField as a TextField with the AXSecureTextField subrole.
    public static func role(type: String?, role: String?, subrole: String?, roleDescription: String?) -> UIRole {
        let description = roleDescription?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type == "Switch" || type == "Toggle" || role == "AXSwitch" || subrole == "AXSwitch"
            || description.contains("switch") || description.contains("toggle") {
            return .switch
        }
        if type == "Slider" || role == "AXSlider" || subrole == "AXSlider" || description.contains("slider") {
            return .slider
        }
        if type == "SecureTextField" || role == "AXSecureTextField" || subrole == "AXSecureTextField" || description == "secure text field" {
            return .secureTextField
        }
        let typeKey = type ?? role.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
        return typeKey.flatMap { rolesByType[$0] } ?? .other
    }

    private static func checked(role: UIRole, value: String?) -> Bool? {
        guard role == .switch || role == .checkbox else { return nil }
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    private static func frame(_ value: Any?) -> UIFrame? {
        guard let frame = value as? [String: Any],
              let x = number(frame["x"]), let y = number(frame["y"]),
              let width = number(frame["width"]), let height = number(frame["height"]) else {
            return nil
        }
        return UIFrame(x: x, y: y, width: width, height: height)
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
