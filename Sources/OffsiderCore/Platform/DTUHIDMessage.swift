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

/// The plain-XPC dictionaries `dtuhidd` decodes on a simulator or a device, as idb's DTUHID transport sends them.
public enum DTUHIDMessage {
    public static let digitizerService = "com.apple.coredevice.feature.remote.hid.digitizer"
    public static let keyboardService = "com.apple.coredevice.feature.remote.hid.keyboard"
    public static let buttonService = "com.apple.coredevice.feature.remote.hid.button"
    public static let vendorDefinedService = "com.apple.coredevice.feature.remote.hid.vendordefined"

    /// `dtuhidd` opens the services it creates for a new peer 560 to 770 ms after the peer's first message, and drops events sent before then.
    public static let activationFloor: Duration = .seconds(1)

    /// `HIDButtonState` for keys and buttons; `dtuhidd` rejects 0.
    public enum ButtonState: UInt64, Sendable {
        case down = 1
        case up = 2
    }

    /// The HID consumer page, where the home, lock and Siri buttons live.
    public static let consumerUsagePage: UInt64 = 0x0C

    public enum TouchPhase: UInt64, Sendable {
        case start = 0
        case position = 1
        case end = 2
    }

    /// `isBarrier` travels only on a barrier: a device's `dtuhidd` drops the connection on an event that carries the key.
    public static func envelope(_ type: String, service: String, isBarrier: Bool = false, payload: [String: DTUHIDValue]) -> DTUHIDValue {
        var fields: [String: DTUHIDValue] = [
            "messageType": .string(type),
            "featureIdentifier": .string(service),
            "payload": .dictionary(payload),
        ]
        if isBarrier { fields["isBarrier"] = .bool(true) }
        return .dictionary(fields)
    }

    /// Keyboard usage 0, which `dtuhidd` answers without the guest seeing a key.
    public static func barrier(service: String) -> DTUHIDValue {
        envelope("IndigoKeyboardButtonEvent", service: service, isBarrier: true, payload: ["usageCode": .uint(0), "state": .uint(2)])
    }

    /// One contact at fractions of the panel; `target` is the touchscreen's simulator screen ID, 0 for the main screen.
    public static func touch(x: Double, y: Double, phase: TouchPhase, target: UInt64, service: String = digitizerService) -> DTUHIDValue {
        envelope("IndigoDigitizerEvent", service: service, payload: [
            "pointOne": .dictionary(["x": .double(x), "y": .double(y)]),
            "eventType": .uint(phase.rawValue),
            "edge": .uint(0),
            "target": .uint(target),
        ])
    }

    /// A USB HID keyboard usage, the same code the simulator's key events carry.
    public static func keyboard(usage: UInt64, state: ButtonState, service: String = keyboardService) -> DTUHIDValue {
        envelope("IndigoKeyboardButtonEvent", service: service, payload: ["usageCode": .uint(usage), "state": .uint(state.rawValue)])
    }

    public static func button(usagePage: UInt64, usage: UInt64, state: ButtonState, service: String = buttonService) -> DTUHIDValue {
        envelope("IndigoButtonEvent", service: service, payload: [
            "usagePage": .uint(usagePage),
            "usageCode": .uint(usage),
            "state": .uint(state.rawValue),
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
