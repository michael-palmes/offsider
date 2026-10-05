import XCTest

/// An `XCUIElementSnapshot` tree in the key set idb's accessibility JSON uses, so Offsider maps both the same way.
struct SnapshotEncoder {
    static let maximumDepth = 60
    static let maximumNodes = 8000

    let deadline: Date
    private(set) var count = 0
    private(set) var truncated = false

    init(budget: TimeInterval) {
        deadline = Date().addingTimeInterval(budget)
    }

    mutating func encode(_ snapshot: XCUIElementSnapshot, depth: Int = 0) -> [String: Any] {
        count += 1
        let frame = snapshot.frame
        let parts = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        let finite = parts.allSatisfy(\.isFinite)
        var node: [String: Any] = [
            "type": Self.typeName(snapshot.elementType),
            "frame": [
                "x": finite ? parts[0] : 0, "y": finite ? parts[1] : 0,
                "width": finite ? parts[2] : 0, "height": finite ? parts[3] : 0,
            ],
            "enabled": snapshot.isEnabled,
            "traits": snapshot.isSelected ? ["Selected"] : [String](),
        ]
        // JSONSerialization raises an uncatchable exception on inf or NaN.
        if !finite { node["frameInvalid"] = true }
        if !snapshot.label.isEmpty { node["AXLabel"] = snapshot.label }
        if !snapshot.identifier.isEmpty { node["AXUniqueId"] = snapshot.identifier }
        if !snapshot.title.isEmpty { node["title"] = snapshot.title }
        if let value = Self.text(snapshot.value), !value.isEmpty { node["AXValue"] = value }
        if let placeholder = snapshot.placeholderValue, !placeholder.isEmpty { node["placeholder"] = placeholder }
        if snapshot.hasFocus { node["focused"] = true }
        var children: [[String: Any]] = []
        if depth < Self.maximumDepth {
            for child in snapshot.children {
                guard count < Self.maximumNodes, Date() < deadline else {
                    truncated = true
                    break
                }
                children.append(encode(child, depth: depth + 1))
            }
        } else if !snapshot.children.isEmpty {
            truncated = true
        }
        node["children"] = children
        return node
    }

    static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "Application"
        case .window: return "Window"
        case .group: return "Group"
        case .sheet: return "Sheet"
        case .alert: return "Alert"
        case .dialog: return "Dialog"
        case .button: return "Button"
        case .radioButton: return "RadioButton"
        case .checkBox: return "CheckBox"
        case .popUpButton: return "PopUpButton"
        case .menuButton: return "MenuButton"
        case .toolbarButton: return "Button"
        case .popover: return "Popover"
        case .keyboard: return "Keyboard"
        case .key: return "Key"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .tab: return "Tab"
        case .toolbar: return "Toolbar"
        case .statusBar: return "StatusBar"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .cell: return "Cell"
        case .slider: return "Slider"
        case .pageIndicator: return "PageIndicator"
        case .progressIndicator: return "ProgressIndicator"
        case .activityIndicator: return "ActivityIndicator"
        case .segmentedControl: return "SegmentedControl"
        case .picker: return "Picker"
        case .pickerWheel: return "PickerWheel"
        case .switch: return "Switch"
        case .toggle: return "Toggle"
        case .link: return "Link"
        case .image: return "Image"
        case .icon: return "Icon"
        case .searchField: return "SearchField"
        case .scrollView: return "ScrollView"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .datePicker: return "DatePicker"
        case .textView: return "TextView"
        case .menu: return "Menu"
        case .menuItem: return "MenuItem"
        case .map: return "Map"
        case .webView: return "WebView"
        case .stepper: return "Stepper"
        default: return "Other"
        }
    }
}
