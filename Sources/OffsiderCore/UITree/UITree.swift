import Foundation

/// The screen's shape now: portrait when it is at least as tall as it is wide.
public enum ScreenShape: String, Sendable {
    case portrait
    case landscape
}

/// A foldable's posture; `unknown` when the device has two displays but could not say which is active.
public enum Posture: String, CaseIterable, Sendable {
    case closed
    case halfOpened = "half-opened"
    case open
    case unknown
}

/// Which display a screen belongs to: `id` is `main`, `cover`, `inner` or `external`; `platformId` is the platform's own (the simulator screen ID, the Android display ID).
public struct ScreenDisplay: Equatable, Sendable {
    public var id: String
    public var platformId: String

    public init(id: String, platformId: String) {
        self.id = id
        self.platformId = platformId
    }

    /// The display a backend that names none is on: simulator screen 1, Android display 0.
    public static func main(on platform: DevicePlatform) -> ScreenDisplay {
        ScreenDisplay(id: DisplayRole.main.rawValue, platformId: platform == .ios ? "1" : "0")
    }
}

public struct UIScreenInfo: Equatable, Sendable {
    /// Points on iOS, dp on Android, in the current orientation.
    public var width: Double
    public var height: Double
    public var scale: Double?
    /// The coordinate orientation input and capture follow; nil when the device could not report it.
    public var rotation: OrientationCoordinateMath.Orientation?
    /// Anticlockwise degrees from the display's natural orientation, when the backend reads them directly.
    public var rotationDegrees: Int?
    /// Nil means the platform's main display.
    public var display: ScreenDisplay?
    /// Nil on a device with one display.
    public var posture: Posture?
    /// The display's native orientation in degrees, which its framebuffer arrives in; not printed.
    public var nativeOrientationDegrees: Int

    public init(
        width: Double,
        height: Double,
        scale: Double? = nil,
        rotation: OrientationCoordinateMath.Orientation? = nil,
        rotationDegrees: Int? = nil,
        display: ScreenDisplay? = nil,
        posture: Posture? = nil,
        nativeOrientationDegrees: Int = 0
    ) {
        self.width = width
        self.height = height
        self.scale = scale
        self.rotation = rotation
        self.rotationDegrees = rotationDegrees
        self.display = display
        self.posture = posture
        self.nativeOrientationDegrees = nativeOrientationDegrees
    }

    public var shape: ScreenShape { height >= width ? .portrait : .landscape }

    /// The backend's degrees, else the coordinate orientation's.
    public var resolvedRotationDegrees: Int? { rotationDegrees ?? rotation?.rotationDegrees }

    public func resolvedDisplay(on platform: DevicePlatform) -> ScreenDisplay {
        display ?? .main(on: platform)
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
            ("screen", screen.map { $0.jsonValue(on: platform) } ?? .null),
            ("roots", .array(roots.map(\.jsonValue))),
        ])
    }
}

extension UIScreenInfo {
    func jsonValue(on platform: DevicePlatform) -> OrderedJSON {
        .object([
            ("width", .number(width)),
            ("height", .number(height)),
            ("scale", .optional(scale, OrderedJSON.number)),
            ("orientation", .string(shape.rawValue)),
            ("rotation", .optional(resolvedRotationDegrees, OrderedJSON.integer)),
            ("display", resolvedDisplay(on: platform).jsonValue),
            ("posture", .optional(posture?.rawValue, OrderedJSON.string)),
        ])
    }
}

extension ScreenDisplay {
    var jsonValue: OrderedJSON {
        .object([("id", .string(id)), ("platformId", .string(platformId))])
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
        .object(jsonFields + [("children", .array(children.map(\.jsonValue)))])
    }

    /// Every neutral key except `children`, in schema order.
    var jsonFields: [(String, OrderedJSON)] {
        [
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
        ]
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
