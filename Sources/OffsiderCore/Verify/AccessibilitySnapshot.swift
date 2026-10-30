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
        /// The describe-ui role, which a cached tree keeps when it drops the native type.
        public var uiRole: String?
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
            uiRole: String? = nil,
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
            self.uiRole = uiRole
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

    /// With `native` false, only the fields a cached tree keeps, so a live read compares alike with one.
    public init(tree: UITree, native: Bool = true) {
        roots = tree.roots.map { Node(node: $0, native: native) }
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

    /// Without each element at least half inside one of `regions` and no bigger than it, and everything under it: a moving group that pokes out still counts as left out, the page holding it does not.
    public func leavingOut(_ regions: [PointRegion]) -> AccessibilitySnapshot {
        guard !regions.isEmpty else { return self }
        return AccessibilitySnapshot(roots: roots.compactMap { $0.leavingOut(regions) })
    }
}

extension AccessibilitySnapshot.Frame {
    /// True when at least half of this frame's area is inside `region` and it has no more area than `region`; a frame with no area is in none.
    func isHalfInside(_ region: PointRegion) -> Bool {
        let area = width * height
        guard area > 0, area <= region.width * region.height else { return false }
        let overlapWidth = min(x + width, region.x + region.width) - max(x, region.x)
        let overlapHeight = min(y + height, region.y + region.height) - max(y, region.y)
        guard overlapWidth > 0, overlapHeight > 0 else { return false }
        return overlapWidth * overlapHeight * 2 >= area
    }
}

extension AccessibilitySnapshot.Node {
    fileprivate func leavingOut(_ regions: [PointRegion]) -> AccessibilitySnapshot.Node? {
        if let frame, regions.contains(where: frame.isHalfInside) { return nil }
        var kept = self
        kept.children = children.compactMap { $0.leavingOut(regions) }
        return kept
    }
}

extension AccessibilitySnapshot.Node {
    /// Keys stay `type#identifier` with the native type, so iOS results match the JSON path.
    init(node: UINode, native: Bool = true) {
        let ios: IOSNativeAttributes?
        if native, case .ios(let attributes) = node.native {
            ios = attributes
        } else {
            ios = nil
        }
        self.init(
            type: (native ? node.native.typeName : nil) ?? node.role.rawValue,
            identifier: node.id,
            uiRole: node.role.rawValue,
            role: ios?.role ?? node.role.rawValue,
            subrole: ios?.subrole,
            label: node.label,
            value: node.value,
            title: ios?.title,
            enabled: node.enabled,
            frame: node.frame.map { AccessibilitySnapshot.Frame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
            state: node.state,
            isSecure: node.isSecure,
            children: node.children.map { Self(node: $0, native: native) }
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
        let uiRole = IOSAccessibilityMapping.role(
            type: Self.text(dictionary["type"]), role: Self.text(dictionary["role"]),
            subrole: Self.text(dictionary["subrole"]), roleDescription: Self.text(dictionary["role_description"])
        )
        let secure = uiRole == .secureTextField
        let value = Self.text(dictionary["AXValue"])
        self.init(
            type: Self.text(dictionary["type"]) ?? "",
            identifier: Self.text(dictionary["AXUniqueId"]) ?? Self.text(dictionary["AXIdentifier"]),
            uiRole: uiRole.rawValue,
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
