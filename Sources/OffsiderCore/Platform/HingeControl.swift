import Foundation

/// The hinge angle Device Hub's slider sends a foldable simulator: a vendor-defined HID event that the guest's locationd turns into the device state.
public enum HingeControl {
    public static let usagePage: UInt64 = 0xff61
    public static let usage: UInt64 = 0x5b
    public static let range = 0...180
    public static let sweepDuration: TimeInterval = 0.5
    public static let sweepInterval: TimeInterval = 0.016

    /// IOKit XML, as locationd reads it with `IOCFUnserialize`: whole degrees, as it rejects binary plists and a full XML plist is over its size limit.
    public static func payload(degrees: Int) -> Data {
        let value = String(min(max(degrees, range.lowerBound), range.upperBound), radix: 16)
        let xml = "<dict><key>provider</key><string>com.apple.Virtualization.VirtualMachines</string>"
            + "<key>source</key><string>hinge-slider-control</string>"
            + "<key>type</key><string>range</string>"
            + "<key>value</key><integer size=\"64\">0x\(value)</integer></dict>"
        return Data(xml.utf8) + Data([0])
    }

    public static func event(degrees: Int) -> DTUHIDValue {
        DTUHIDMessage.vendorDefined(usagePage: usagePage, usage: usage, data: payload(degrees: degrees))
    }

    /// The angle a posture is set with; nil for `unknown`.
    public static func angle(for posture: Posture) -> Int? {
        switch posture {
        case .closed: return 0
        case .halfOpened: return 120
        case .open: return 180
        case .unknown: return nil
        }
    }

    /// Where a sweep to `target` starts: the current posture's angle, else the far end, so the hinge always moves.
    public static func start(from current: Posture?, to target: Int) -> Int {
        if let current, let angle = angle(for: current), angle != target { return angle }
        return target > 90 ? range.lowerBound : range.upperBound
    }

    /// Whole degrees from `start` to `end`, one every `interval` across `duration`, ending on `end`; consecutive repeats dropped.
    public static func sweep(from start: Int, to end: Int, duration: TimeInterval = sweepDuration, interval: TimeInterval = sweepInterval) -> [Int] {
        let steps = max(1, Int((duration / interval).rounded()))
        var angles: [Int] = []
        for step in 0...steps {
            let angle = Int((Double(start) + Double(end - start) * Double(step) / Double(steps)).rounded())
            if angles.last != angle { angles.append(angle) }
        }
        return angles
    }
}
