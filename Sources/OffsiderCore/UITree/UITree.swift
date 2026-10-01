import Foundation

public struct UIScreenInfo: Equatable, Sendable {
    /// Points on iOS, dp on Android, in the current orientation.
    public var width: Double
    public var height: Double
    public var scale: Double?
    public var orientation: OrientationCoordinateMath.Orientation?

    public init(width: Double, height: Double, scale: Double? = nil, orientation: OrientationCoordinateMath.Orientation? = nil) {
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
    }
}

/// The `describe-ui` envelope, shared by every platform.
public struct UITree: Equatable, Sendable {
    public static let schemaVersion = 1

    public var platform: DevicePlatform
    public var device: String
    public var screen: UIScreenInfo?
    public var roots: [UINode]

    public init(platform: DevicePlatform, device: String, screen: UIScreenInfo? = nil, roots: [UINode]) {
        self.platform = platform
        self.device = device
        self.screen = screen
        self.roots = roots
    }

    public var applicationFrame: UIFrame? {
        Self.applicationFrame(in: roots)
    }

    /// The application root's frame, else the first root's.
    public static func applicationFrame(in roots: [UINode]) -> UIFrame? {
        roots.first { $0.role == .application }?.frame ?? roots.first?.frame
    }

    /// Pretty-printed JSON with every key in schema order and explicit nulls.
    public func jsonData() -> Data {
        Data((jsonValue.rendered() + "\n").utf8)
    }

    var jsonValue: OrderedJSON {
        .object([
            ("version", .integer(Self.schemaVersion)),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("screen", screen.map(\.jsonValue) ?? .null),
            ("roots", .array(roots.map(\.jsonValue))),
        ])
    }
}

extension UIScreenInfo {
    var jsonValue: OrderedJSON {
        .object([
            ("width", .number(width)),
            ("height", .number(height)),
            ("scale", .optional(scale, OrderedJSON.number)),
            ("orientation", .optional(orientation?.rawValue, OrderedJSON.string)),
        ])
    }
}

extension UIFrame {
    var jsonValue: OrderedJSON {
        .object([
            ("x", .number(x)),
            ("y", .number(y)),
            ("width", .number(width)),
            ("height", .number(height)),
        ])
    }
}

extension UINode {
    var jsonValue: OrderedJSON {
        .object([
            ("role", .string(role.rawValue)),
            ("id", .optional(id, OrderedJSON.string)),
            ("label", .optional(label, OrderedJSON.string)),
            ("value", .optional(value, OrderedJSON.string)),
            ("frame", frame.map(\.jsonValue) ?? .null),
            ("enabled", .optional(enabled, OrderedJSON.bool)),
            ("state", .object([
                ("checked", .optional(state.checked, OrderedJSON.bool)),
                ("selected", .optional(state.selected, OrderedJSON.bool)),
                ("focused", .optional(state.focused, OrderedJSON.bool)),
            ])),
            ("native", native.jsonValue),
            ("children", .array(children.map(\.jsonValue))),
        ])
    }
}

extension UINative {
    var jsonValue: OrderedJSON {
        switch self {
        case .ios(let native):
            return .object([
                ("type", .optional(native.type, OrderedJSON.string)),
                ("role", .optional(native.role, OrderedJSON.string)),
                ("subrole", .optional(native.subrole, OrderedJSON.string)),
                ("roleDescription", .optional(native.roleDescription, OrderedJSON.string)),
                ("title", .optional(native.title, OrderedJSON.string)),
                ("help", .optional(native.help, OrderedJSON.string)),
                ("customActions", .array(native.customActions.map(OrderedJSON.string))),
                ("contentRequired", .optional(native.contentRequired, OrderedJSON.bool)),
                ("pid", .optional(native.pid, OrderedJSON.integer)),
                ("axFrame", .optional(native.axFrame, OrderedJSON.string)),
            ])
        case .android(let native):
            return .object([
                ("className", .optional(native.className, OrderedJSON.string)),
                ("resourceId", .optional(native.resourceId, OrderedJSON.string)),
                ("package", .optional(native.package, OrderedJSON.string)),
                ("pixelFrame", native.pixelFrame.map(\.jsonValue) ?? .null),
                ("text", .optional(native.text, OrderedJSON.string)),
                ("contentDescription", .optional(native.contentDescription, OrderedJSON.string)),
                ("hint", .optional(native.hint, OrderedJSON.string)),
                ("stateDescription", .optional(native.stateDescription, OrderedJSON.string)),
                ("roleDescription", .optional(native.roleDescription, OrderedJSON.string)),
                ("testTag", .optional(native.testTag, OrderedJSON.string)),
            ])
        }
    }
}
