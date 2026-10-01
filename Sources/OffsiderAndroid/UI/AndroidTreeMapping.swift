import Foundation
import OffsiderCore

/// `uiautomator` nodes to the neutral tree, frames in dp (pixels over density / 160).
enum AndroidTreeMapping {
    /// The dump's first node is the app window: role `application`, so gesture presets and verify see its frame.
    static func roots(from hierarchy: UIAutomatorHierarchy, scale: Double) -> [UINode] {
        guard let root = hierarchy.nodes.first else { return [] }
        return [node(from: root, scale: scale, isRoot: true)]
    }

    static func node(from raw: RawAndroidNode, scale: Double, isRoot: Bool = false) -> UINode {
        let role = isRoot ? .application : self.role(for: raw)
        let pixels = pixelFrame(raw["bounds"])
        let checkable = raw.flag("checkable")
        return UINode(
            role: role,
            id: nonEmpty(raw["resource-id"]),
            label: isRoot ? nil : label(for: raw),
            value: value(for: raw, role: role),
            frame: pixels.map { dp($0, scale: scale) },
            enabled: raw.flag("enabled"),
            state: UIState(
                checked: checkable ? raw.flag("checked") : nil,
                selected: raw.flag("selected"),
                focused: raw.flag("focused")
            ),
            native: .android(AndroidNativeAttributes(
                className: nonEmpty(raw["class"]),
                resourceId: nonEmpty(raw["resource-id"]),
                package: nonEmpty(raw["package"]),
                pixelFrame: pixels,
                text: nonEmpty(raw["text"]),
                contentDescription: nonEmpty(raw["content-desc"]),
                hint: nonEmpty(raw["hint"])
            )),
            children: raw.children.map { node(from: $0, scale: scale) }
        )
    }

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
        guard !raw.flag("clickable") else { return [] }
        let own = nonEmpty(raw["content-desc"]) ?? nonEmpty(raw["text"])
        return (own.map { [$0] } ?? []) + raw.children.flatMap(descendantLabels)
    }

    static func value(for raw: RawAndroidNode, role: UIRole) -> String? {
        switch role {
        case .textField, .secureTextField:
            return nonEmpty(raw["text"])
        case .switch, .checkbox, .radioButton:
            return raw.flag("checkable") ? (raw.flag("checked") ? "1" : "0") : nil
        default:
            return nil
        }
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
