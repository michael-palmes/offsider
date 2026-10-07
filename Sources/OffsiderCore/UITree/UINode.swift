import Foundation

public struct UIFrame: Equatable, Sendable {
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

public struct UIPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Points on iOS, dp on Android, in the current orientation.
public struct UISize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Toggle, selection and focus state; `nil` when the platform does not report it.
public struct UIState: Equatable, Sendable {
    public var checked: Bool?
    public var selected: Bool?
    public var focused: Bool?

    public init(checked: Bool? = nil, selected: Bool? = nil, focused: Bool? = nil) {
        self.checked = checked
        self.selected = selected
        self.focused = focused
    }
}

public struct IOSNativeAttributes: Equatable, Sendable {
    public var type: String?
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var help: String?
    public var customActions: [String]
    public var contentRequired: Bool?
    public var pid: Int?
    public var axFrame: String?

    public init(
        type: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        roleDescription: String? = nil,
        title: String? = nil,
        help: String? = nil,
        customActions: [String] = [],
        contentRequired: Bool? = nil,
        pid: Int? = nil,
        axFrame: String? = nil
    ) {
        self.type = type
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.title = title
        self.help = help
        self.customActions = customActions
        self.contentRequired = contentRequired
        self.pid = pid
        self.axFrame = axFrame
    }
}

public struct AndroidNativeAttributes: Equatable, Sendable {
    public var className: String?
    public var resourceId: String?
    public var package: String?
    public var pixelFrame: UIFrame?
    public var text: String?
    public var contentDescription: String?
    public var hint: String?
    public var stateDescription: String?
    public var roleDescription: String?
    public var testTag: String?
    /// Android's own visible-to-user flag; describe-ui JSON does not carry it, and equality ignores it.
    public var visibleToUser: Bool?
    /// The z-order among its siblings, higher drawn later; nil when the dump gave none. Not in JSON or equality.
    public var drawingOrder: Int?
    /// The window's layer, on a window's root only; higher is in front. Not in JSON or equality.
    public var windowLayer: Int?

    public init(
        className: String? = nil,
        resourceId: String? = nil,
        package: String? = nil,
        pixelFrame: UIFrame? = nil,
        text: String? = nil,
        contentDescription: String? = nil,
        hint: String? = nil,
        stateDescription: String? = nil,
        roleDescription: String? = nil,
        testTag: String? = nil,
        visibleToUser: Bool? = nil,
        drawingOrder: Int? = nil,
        windowLayer: Int? = nil
    ) {
        self.className = className
        self.resourceId = resourceId
        self.package = package
        self.pixelFrame = pixelFrame
        self.text = text
        self.contentDescription = contentDescription
        self.hint = hint
        self.stateDescription = stateDescription
        self.roleDescription = roleDescription
        self.testTag = testTag
        self.visibleToUser = visibleToUser
        self.drawingOrder = drawingOrder
        self.windowLayer = windowLayer
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.className == rhs.className && lhs.resourceId == rhs.resourceId && lhs.package == rhs.package
            && lhs.pixelFrame == rhs.pixelFrame && lhs.text == rhs.text && lhs.contentDescription == rhs.contentDescription
            && lhs.hint == rhs.hint && lhs.stateDescription == rhs.stateDescription && lhs.roleDescription == rhs.roleDescription
            && lhs.testTag == rhs.testTag
    }
}

/// Platform attributes kept verbatim beside the neutral fields; encoded flat under `native`.
public enum UINative: Equatable, Sendable {
    case ios(IOSNativeAttributes)
    case android(AndroidNativeAttributes)

    /// iOS `type`, or the Android class name without its package.
    public var typeName: String? {
        switch self {
        case .ios(let attributes):
            return attributes.type
        case .android(let attributes):
            return attributes.className?.split(separator: ".").last.map(String.init)
        }
    }
}

public struct UINode: Equatable, Sendable {
    public var role: UIRole
    public var id: String?
    public var label: String?
    public var value: String?
    public var frame: UIFrame?
    public var enabled: Bool?
    public var state: UIState
    public var native: UINative
    public var children: [UINode]

    public init(
        role: UIRole,
        id: String? = nil,
        label: String? = nil,
        value: String? = nil,
        frame: UIFrame? = nil,
        enabled: Bool? = nil,
        state: UIState = UIState(),
        native: UINative,
        children: [UINode] = []
    ) {
        self.role = role
        self.id = id
        self.label = label
        self.value = value
        self.frame = frame
        self.enabled = enabled
        self.state = state
        self.native = native
        self.children = children
    }

    /// This node, then its descendants depth first.
    public func flattened() -> [UINode] {
        [self] + children.flatMap { $0.flattened() }
    }

    /// The id trimmed of white space; nil when nothing is left.
    public var normalizedID: String? { Self.trimmed(id) }
    /// The label trimmed of white space; nil when nothing is left.
    public var normalizedLabel: String? { Self.trimmed(label) }
    /// The value trimmed of white space; nil when nothing is left.
    public var normalizedValue: String? { Self.trimmed(value) }

    private static func trimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
