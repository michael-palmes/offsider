import Foundation

public struct AccessibilitySnapshot: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Node: Equatable, Sendable {
        public var type: String
        public var identifier: String?
        public var role: String?
        public var subrole: String?
        public var label: String?
        public var value: String?
        public var title: String?
        public var enabled: Bool?
        public var frame: Frame?
        public var state: UIState
        public var isSecure: Bool
        public var children: [Node]

        public init(
            type: String,
            identifier: String? = nil,
            role: String? = nil,
            subrole: String? = nil,
            label: String? = nil,
            value: String? = nil,
            title: String? = nil,
            enabled: Bool? = nil,
            frame: Frame? = nil,
            state: UIState = UIState(),
            isSecure: Bool = false,
            children: [Node] = []
        ) {
            self.type = type
            self.identifier = identifier
            self.role = role
            self.subrole = subrole
            self.label = label
            self.value = value
            self.title = title
            self.enabled = enabled
            self.frame = frame
            self.state = state
            self.isSecure = isSecure
            self.children = children
        }
    }

    public enum DecodingFailure: Error, Equatable, Sendable {
        case notAnAccessibilityTree
    }

    public let roots: [Node]

    public init(roots: [Node]) {
        self.roots = roots
    }

    public init(tree: UITree) {
        roots = tree.roots.map(Node.init(node:))
    }

    public init(jsonData: Data) throws {
        let object = try JSONSerialization.jsonObject(with: jsonData)
        if let array = object as? [[String: Any]] {
            roots = array.map(Node.init(dictionary:))
        } else if let dictionary = object as? [String: Any] {
            roots = [Node(dictionary: dictionary)]
        } else {
            throw DecodingFailure.notAnAccessibilityTree
        }
    }

    public var isKnown: Bool {
        roots.contains { !$0.children.isEmpty }
    }

    public var screenWidth: Double? {
        for root in roots {
            if let frame = root.frame { return frame.width }
            if let frame = root.children.lazy.compactMap(\.frame).first { return frame.width }
        }
        return nil
    }
}

extension AccessibilitySnapshot.Node {
    /// Keys stay `type#identifier` with the native type, so iOS results match the JSON path.
    init(node: UINode) {
        let ios: IOSNativeAttributes?
        if case .ios(let attributes) = node.native {
            ios = attributes
        } else {
            ios = nil
        }
        self.init(
            type: node.native.typeName ?? node.role.rawValue,
            identifier: node.id,
            role: ios?.role ?? node.role.rawValue,
            subrole: ios?.subrole,
            label: node.label,
            value: node.value,
            title: ios?.title,
            enabled: node.enabled,
            frame: node.frame.map { AccessibilitySnapshot.Frame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
            state: node.state,
            isSecure: node.isSecure,
            children: node.children.map(Self.init(node:))
        )
    }

    init(dictionary: [String: Any]) {
        let frame = (dictionary["frame"] as? [String: Any]).flatMap { frame -> AccessibilitySnapshot.Frame? in
            guard let x = Self.number(frame["x"]), let y = Self.number(frame["y"]),
                  let width = Self.number(frame["width"]), let height = Self.number(frame["height"]) else {
                return nil
            }
            return AccessibilitySnapshot.Frame(x: x, y: y, width: width, height: height)
        }
        let secure = IOSAccessibilityMapping.role(
            type: Self.text(dictionary["type"]), role: Self.text(dictionary["role"]),
            subrole: Self.text(dictionary["subrole"]), roleDescription: Self.text(dictionary["role_description"])
        ) == .secureTextField
        let value = Self.text(dictionary["AXValue"])
        self.init(
            type: Self.text(dictionary["type"]) ?? "",
            identifier: Self.text(dictionary["AXUniqueId"]) ?? Self.text(dictionary["AXIdentifier"]),
            role: Self.text(dictionary["role"]),
            subrole: Self.text(dictionary["subrole"]),
            label: Self.text(dictionary["AXLabel"]),
            value: secure ? SecureText.masked(value) : value,
            title: Self.text(dictionary["title"]),
            enabled: dictionary["enabled"] as? Bool,
            frame: frame,
            isSecure: secure,
            children: (dictionary["children"] as? [[String: Any]] ?? []).map(Self.init(dictionary:))
        )
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
