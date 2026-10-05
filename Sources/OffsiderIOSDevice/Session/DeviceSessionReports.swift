import Foundation
import OffsiderCore

/// The UniversalHID reports, and the pauses between them, that the broker sends for touch and key steps.
enum DeviceSessionReport: Equatable {
    case touch(x: UInt16, y: UInt16, state: UniversalHIDReport.TouchState)
    /// Every key held down after this report; empty releases them all.
    case keyboard([UInt8])
    case sleep(Double)
}

enum DeviceSessionReports {
    /// A held contact is sent again this often, so the device sees a long press or a slow drag as one live touch.
    static let holdInterval = 0.02

    /// Checked whole before anything is sent; a contact left down at the end is released.
    static func touch(_ steps: [DeviceSessionStep], panel: IOSDevicePanel) throws -> [DeviceSessionReport] {
        var reports: [DeviceSessionReport] = []
        var held: (x: UInt16, y: UInt16)?
        for step in steps {
            switch step.kind {
            case .down, .move, .up:
                guard let x = step.x, let y = step.y, x.isFinite, y.isFinite else {
                    throw IOSDeviceError(.sessionFailed, "A touch step has no point.")
                }
                let point = panel.touchscreenPoint(x: x, y: y)
                let lifting = step.kind == .up
                reports.append(.touch(x: point.x, y: point.y, state: lifting ? .release : .contact))
                held = lifting ? nil : point
            case .wait:
                reports += pause(step.seconds ?? 0, holding: held)
            case .keyDown, .keyUp:
                throw IOSDeviceError(.sessionFailed, "A key step cannot go in a touch request.")
            }
        }
        if let held { reports.append(.touch(x: held.x, y: held.y, state: .release)) }
        return reports
    }

    private static func pause(_ seconds: Double, holding held: (x: UInt16, y: UInt16)?) -> [DeviceSessionReport] {
        guard seconds > 0 else { return [] }
        guard let held else { return [.sleep(seconds)] }
        var reports: [DeviceSessionReport] = []
        var remaining = seconds
        while remaining > 1e-9 {
            let slice = min(remaining, holdInterval)
            reports += [.sleep(slice), .touch(x: held.x, y: held.y, state: .contact)]
            remaining -= slice
        }
        return reports
    }

    /// Each press sets its usage in the held set and each release clears it; keys still held at the end are released.
    static func keys(_ steps: [DeviceSessionStep]) throws -> [DeviceSessionReport] {
        var reports: [DeviceSessionReport] = []
        var pressed: [UInt8] = []
        for step in steps {
            switch step.kind {
            case .keyDown, .keyUp:
                guard let usage = step.usage, usage < UniversalHIDReport.keyboardUsageLimit else {
                    throw IOSDeviceError(.sessionFailed, "A key step has no keyboard usage below \(UniversalHIDReport.keyboardUsageLimit).")
                }
                let key = UInt8(usage)
                if step.kind == .keyDown {
                    if !pressed.contains(key) { pressed.append(key) }
                } else {
                    pressed.removeAll { $0 == key }
                }
                reports.append(.keyboard(pressed))
            case .wait:
                if let seconds = step.seconds, seconds > 0 { reports.append(.sleep(seconds)) }
            case .down, .move, .up:
                throw IOSDeviceError(.sessionFailed, "A touch step cannot go in a key request.")
            }
        }
        if !pressed.isEmpty { reports.append(.keyboard([])) }
        return reports
    }
}
