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
    init(dictionary: [String: Any]) {
        let frame = (dictionary["frame"] as? [String: Any]).flatMap { frame -> AccessibilitySnapshot.Frame? in
            guard let x = Self.number(frame["x"]), let y = Self.number(frame["y"]),
                  let width = Self.number(frame["width"]), let height = Self.number(frame["height"]) else {
                return nil
            }
            return AccessibilitySnapshot.Frame(x: x, y: y, width: width, height: height)
        }
        self.init(
            type: Self.text(dictionary["type"]) ?? "",
            identifier: Self.text(dictionary["AXUniqueId"]) ?? Self.text(dictionary["AXIdentifier"]),
            role: Self.text(dictionary["role"]),
            subrole: Self.text(dictionary["subrole"]),
            label: Self.text(dictionary["AXLabel"]),
            value: Self.text(dictionary["AXValue"]),
            title: Self.text(dictionary["title"]),
            enabled: dictionary["enabled"] as? Bool,
            frame: frame,
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
