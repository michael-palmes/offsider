import Foundation

/// The turn Device Hub's orientation picker sends a foldable simulator: its UI follows this, not the plain orientation event.
public enum OrientationPicker {
    public static func payload(_ orientation: DeviceOrientation) -> Data {
        HingeControl.avpPayload(source: "orientation-picker-control", type: "enum", value: "<string>\(name(orientation))</string>")
    }

    public static func event(_ orientation: DeviceOrientation) -> DTUHIDValue {
        DTUHIDMessage.vendorDefined(usagePage: HingeControl.usagePage, usage: HingeControl.usage, data: payload(orientation))
    }

    /// locationd's names for the picker's values.
    static func name(_ orientation: DeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .portraitUpsideDown: return "pud"
        }
    }
}
