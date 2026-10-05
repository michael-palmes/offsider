import Foundation

/// One HID surface the device registered, as `connectedServices` lists it.
public struct UniversalHIDSurface: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case touchscreen
        case keyboard
        case buttons
        case trackpad
        case other
    }

    public var id: UInt64
    public var product: String?
    public var typeHint: String?
    public var usagePage: UInt64?
    public var usage: UInt64?

    public init(id: UInt64, product: String? = nil, typeHint: String? = nil, usagePage: UInt64? = nil, usage: UInt64? = nil) {
        self.id = id
        self.product = product
        self.typeHint = typeHint
        self.usagePage = usagePage
        self.usage = usage
    }

    /// The digitizer page's touch screen usage, the keyboard hint, the consumer-buttons page, or the trackpad hint.
    public var role: Role {
        if usagePage == 0x0D && usage == 0x04 { return .touchscreen }
        if typeHint == "Keyboard" { return .keyboard }
        if typeHint == "Trackpad" { return .trackpad }
        if usagePage == 0x0B && usage == 0x01 { return .buttons }
        return .other
    }

    /// Each descriptor under the reply's `connectedServices`, in reply order; empty for any other reply.
    public static func parse(_ reply: UniversalHIDValue) -> [UniversalHIDSurface] {
        guard case let .array(descriptors)? = reply["connectedServices"] else { return [] }
        return descriptors.compactMap { descriptor in
            guard let id = descriptor["_ServiceID"]?.unsigned else { return nil }
            return UniversalHIDSurface(
                id: id,
                product: descriptor["Product"]?.text,
                typeHint: descriptor["DeviceTypeHint"]?.text,
                usagePage: descriptor["PrimaryUsagePage"]?.unsigned,
                usage: descriptor["PrimaryUsage"]?.unsigned
            )
        }
    }
}

extension Array where Element == UniversalHIDSurface {
    public func first(_ role: UniversalHIDSurface.Role) -> UniversalHIDSurface? {
        first { $0.role == role }
    }
}
