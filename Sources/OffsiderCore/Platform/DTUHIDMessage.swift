import Foundation

/// A value in a `dtuhidd` message, kept apart from XPC so the shapes can be tested.
public indirect enum DTUHIDValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case uint(UInt64)
    case double(Double)
    case data(Data)
    case dictionary([String: DTUHIDValue])
}

/// The plain-XPC dictionaries a simulator's `dtuhidd` decodes, as idb's DTUHID transport sends them for the digitizer.
public enum DTUHIDMessage {
    public static let digitizerService = "com.apple.coredevice.feature.remote.hid.digitizer"
    public static let vendorDefinedService = "com.apple.coredevice.feature.remote.hid.vendordefined"

    public enum TouchPhase: UInt64, Sendable {
        case start = 0
        case position = 1
        case end = 2
    }

    public static func envelope(_ type: String, service: String, isBarrier: Bool = false, payload: [String: DTUHIDValue]) -> DTUHIDValue {
        .dictionary([
            "messageType": .string(type),
            "isBarrier": .bool(isBarrier),
            "featureIdentifier": .string(service),
            "payload": .dictionary(payload),
        ])
    }

    /// Keyboard usage 0, which `dtuhidd` answers without the guest seeing a key.
    public static func barrier(service: String) -> DTUHIDValue {
        envelope("IndigoKeyboardButtonEvent", service: service, isBarrier: true, payload: ["usageCode": .uint(0), "state": .uint(2)])
    }

    /// One contact at fractions of the panel; `target` is the touchscreen's simulator screen ID, 0 for the main screen.
    public static func touch(x: Double, y: Double, phase: TouchPhase, target: UInt64) -> DTUHIDValue {
        envelope("IndigoDigitizerEvent", service: digitizerService, payload: [
            "pointOne": .dictionary(["x": .double(x), "y": .double(y)]),
            "eventType": .uint(phase.rawValue),
            "edge": .uint(0),
            "target": .uint(target),
        ])
    }

    public static func vendorDefined(usagePage: UInt64, usage: UInt64, data: Data) -> DTUHIDValue {
        envelope("IndigoVendorDefinedEvent", service: vendorDefinedService, payload: [
            "usagePage": .uint(usagePage),
            "usage": .uint(usage),
            "version": .uint(0),
            "data": .data(data),
        ])
    }
}

/// Start, then position while the finger stays down, then end, as `dtuhidd` tracks one contact.
public struct DTUHIDContact: Sendable {
    private var down = false

    public init() {}

    public mutating func phase(touchingDown: Bool) -> DTUHIDMessage.TouchPhase {
        guard touchingDown else {
            down = false
            return .end
        }
        defer { down = true }
        return down ? .position : .start
    }
}
