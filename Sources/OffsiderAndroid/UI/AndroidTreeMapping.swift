import Foundation
import OffsiderCore

/// `uiautomator` nodes to the neutral tree, frames in dp (pixels over density / 160).
enum AndroidTreeMapping {
    /// The dump's first node is the app window: role `application`, so gesture presets and verify see its frame.
    static func roots(from hierarchy: UIAutomatorHierarchy, scale: Double) -> [UINode] {
        guard let root = hierarchy.nodes.first else { return [] }
        return [node(from: root, scale: scale, rootRole: .application, rootLabel: nil)]
    }

    /// A root takes `rootRole` and `rootLabel` (a window and its title); other nodes map from their attributes.
    static func node(from raw: RawAndroidNode, scale: Double, rootRole: UIRole? = nil, rootLabel: String? = nil) -> UINode {
        let role = rootRole ?? self.role(for: raw)
        let pixels = pixelFrame(raw["bounds"])
        let secure = role == .secureTextField || raw.flag("password")
        var nodeLabel = rootRole == nil ? label(for: raw) : rootLabel.flatMap(nonEmpty)
        let reactNativeMixed = rootRole == nil && role == .checkbox && nodeLabel?.hasSuffix(mixedSuffix) == true
        if reactNativeMixed, let full = nodeLabel {
            nodeLabel = nonEmpty(String(full.dropLast(mixedSuffix.count)))
        }
        let partial = raw["checked-state"] == "partial" || reactNativeMixed
        return UINode(
            role: role,
            id: nonEmpty(raw["resource-id"]) ?? nonEmpty(raw["test-tag"]),
            label: nodeLabel,
            value: reactNativeMixed ? "2" : value(for: raw, role: role),
            frame: pixels.map { dp($0, scale: scale) },
            enabled: raw.flag("enabled"),
            state: UIState(
                checked: raw.flag("checkable") && !partial ? raw.flag("checked") : nil,
                selected: raw.flag("selected"),
                focused: raw.flag("focused")
            ),
            native: .android(AndroidNativeAttributes(
                className: nonEmpty(raw["class"]),
                resourceId: nonEmpty(raw["resource-id"]),
                package: nonEmpty(raw["package"]),
                pixelFrame: pixels,
                text: secure ? SecureText.masked(secureText(raw)) : nonEmpty(raw["text"]),
                contentDescription: nonEmpty(raw["content-desc"]),
                hint: nonEmpty(raw["hint"]),
                stateDescription: nonEmpty(raw["state-description"]),
                roleDescription: nonEmpty(raw["role-description"]),
                testTag: nonEmpty(raw["test-tag"]),
                visibleToUser: nonEmpty(raw["visible-to-user"]).map { $0 == "true" }
            )),
            children: raw.children.map { node(from: $0, scale: scale) }
        )
    }

    /// React Native marks a mixed checkbox only with this suffix on its description, and drops `checkable`.
    private static let mixedSuffix = ", mixed"

    /// `content-desc`, else `text` unless editable; a clickable node with neither takes its non-clickable descendants' text.
    static func label(for raw: RawAndroidNode) -> String? {
        if let description = nonEmpty(raw["content-desc"]) {
            return description
        }
        if !isEditable(raw), let text = nonEmpty(raw["text"]) {
            return text
        }
        guard raw.flag("clickable") else { return nil }
        let parts = raw.children.flatMap(descendantLabels)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func descendantLabels(_ raw: RawAndroidNode) -> [String] {
        guard !raw.flag("clickable"), !raw.flag("password") else { return [] }
        let own = nonEmpty(raw["content-desc"]) ?? nonEmpty(raw["text"])
        return (own.map { [$0] } ?? []) + raw.children.flatMap(descendantLabels)
    }

    /// Text for fields, `1`, `0` or `2` (partial) for toggles, and the range position as a percentage for sliders.
    static func value(for raw: RawAndroidNode, role: UIRole) -> String? {
        switch role {
        case .textField:
            return nonEmpty(raw["text"])
        case .secureTextField:
            return SecureText.masked(secureText(raw))
        case .switch, .checkbox, .radioButton:
            if raw["checked-state"] == "partial" {
                return "2"
            }
            return raw.flag("checkable") ? (raw.flag("checked") ? "1" : "0") : nil
        case .slider, .progress:
            return rangePercent(raw)
        default:
            return nil
        }
    }

    /// A password field's text, nil when it only repeats the hint (some framework versions report an empty field that way).
    private static func secureText(_ raw: RawAndroidNode) -> String? {
        let text = nonEmpty(raw["text"])
        return text == nonEmpty(raw["hint"]) ? nil : text
    }

    /// (current - min) / (max - min) with up to two decimals: "25%", "39.95%"; nil when indeterminate or empty.
    static func rangePercent(_ raw: RawAndroidNode) -> String? {
        guard raw["range-type"] != "indeterminate",
              let min = Double(raw["range-min"]), let max = Double(raw["range-max"]), let current = Double(raw["range-current"]),
              min.isFinite, max.isFinite, current.isFinite, max != min else {
            return nil
        }
        var text = String(format: "%.2f", (current - min) / (max - min) * 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return (text == "-0" ? "0" : text) + "%"
    }

    private static let classRoles: [(suffix: String, role: UIRole)] = [
        ("EditText", .textField), ("AutoCompleteTextView", .textField), ("SearchView$SearchAutoComplete", .textField),
        ("ToggleButton", .switch), ("SwitchCompat", .switch), ("Switch", .switch),
        ("CheckBox", .checkbox),
        ("RadioButton", .radioButton),
        ("Button", .button),
        ("SeekBar", .slider), ("Slider", .slider),
        ("ProgressBar", .progress),
        ("ImageView", .image),
        ("TextView", .text),
        ("ScrollView", .scrollView),
        ("ListView", .list), ("GridView", .list), ("RecyclerView", .list),
        ("Spinner", .picker),
        ("TabWidget", .tabBar),
        ("WebView", .other),
    ]

    /// `password="true"` first, then the class by simple-name suffix, then clickable, scrollable or a plain group.
    static func role(for raw: RawAndroidNode) -> UIRole {
        if raw.flag("password") {
            return .secureTextField
        }
        let simpleName = raw["class"].split(separator: ".").last.map(String.init) ?? ""
        if let match = classRoles.first(where: { simpleName.hasSuffix($0.suffix) }) {
            return match.role
        }
        if raw.flag("clickable") {
            return .button
        }
        return raw.flag("scrollable") ? .scrollView : .group
    }

    private static func isEditable(_ raw: RawAndroidNode) -> Bool {
        raw.flag("password") || role(for: raw) == .textField
    }

    /// `[l,t][r,b]` in pixels; inverted bounds (clipped rows) become zero width or height.
    static func pixelFrame(_ bounds: String) -> UIFrame? {
        let numbers = bounds.split { $0 == "[" || $0 == "]" || $0 == "," }.compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return UIFrame(x: numbers[0], y: numbers[1], width: max(0, numbers[2] - numbers[0]), height: max(0, numbers[3] - numbers[1]))
    }

    private static func dp(_ frame: UIFrame, scale: Double) -> UIFrame {
        UIFrame(x: rounded(frame.x / scale), y: rounded(frame.y / scale), width: rounded(frame.width / scale), height: rounded(frame.height / scale))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }
}
