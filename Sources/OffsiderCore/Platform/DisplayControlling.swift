import Foundation

/// The neutral display names: `main` on a device with one display, `cover` and `inner` on a foldable.
public enum DisplayRole: String, CaseIterable, Sendable {
    case main
    case cover
    case inner
    case external
}

/// One built-in display as the device describes it, in its native orientation.
public struct DisplayDescriptor: Equatable, Sendable {
    public var role: DisplayRole
    /// The simulator screen ID or the Android display ID, as text.
    public var platformId: String
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    /// Degrees, from the device profile.
    public var nativeOrientation: Int

    public init(role: DisplayRole, platformId: String, name: String, pixelWidth: Int, pixelHeight: Int, scale: Double, nativeOrientation: Int) {
        self.role = role
        self.platformId = platformId
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.nativeOrientation = nativeOrientation
    }

    public var pointWidth: Double { Double(pixelWidth) / scale }
    public var pointHeight: Double { Double(pixelHeight) / scale }

    public var screenDisplay: ScreenDisplay { ScreenDisplay(id: role.rawValue, platformId: platformId) }

    /// One display is `main`; with two, the smaller is the `cover` and the larger the `inner`; any more are `external`.
    public static func assigningRoles(_ displays: [DisplayDescriptor]) -> [DisplayDescriptor] {
        guard displays.count > 1 else { return displays.map { $0.with(role: .main) } }
        let byArea = displays.indices.sorted { displays[$0].pixelWidth * displays[$0].pixelHeight < displays[$1].pixelWidth * displays[$1].pixelHeight }
        var result = displays
        for (rank, index) in byArea.enumerated() {
            result[index].role = rank == 0 ? .cover : rank == byArea.count - 1 ? .inner : .external
        }
        return result
    }

    func with(role: DisplayRole) -> DisplayDescriptor {
        var copy = self
        copy.role = role
        return copy
    }
}

public struct DisplayInfo: Equatable, Sendable {
    public var descriptor: DisplayDescriptor
    /// In the display's current orientation when it is active, else its native one.
    public var pointWidth: Double
    public var pointHeight: Double
    /// The device's anticlockwise turn from portrait; nil for an inactive display.
    public var rotationDegrees: Int?
    public var active: Bool

    public init(descriptor: DisplayDescriptor, pointWidth: Double, pointHeight: Double, rotationDegrees: Int?, active: Bool) {
        self.descriptor = descriptor
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.rotationDegrees = rotationDegrees
        self.active = active
    }
}

public struct DisplayList: Equatable, Sendable {
    public var displays: [DisplayInfo]
    /// Nil on a device with one display.
    public var posture: Posture?

    public init(displays: [DisplayInfo], posture: Posture?) {
        self.displays = displays
        self.posture = posture
    }

    public var active: DisplayInfo? { displays.first(where: \.active) }

    /// A display by role (`cover`) or platform id (`3`), case-insensitively.
    public func resolve(_ text: String, device: String) throws -> DisplayInfo {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = displays.first(where: { $0.descriptor.role.rawValue == wanted })
            ?? displays.first(where: { $0.descriptor.platformId.lowercased() == wanted }) {
            return match
        }
        let names = displays.map { "\($0.descriptor.role.rawValue) (\($0.descriptor.platformId))" }.joined(separator: ", ")
        let foldable = displays.contains { $0.descriptor.role == .inner }
        let reason = wanted == DisplayRole.main.rawValue && foldable ? ": main is the display of a device with one, and a foldable has cover and inner" : ""
        throw DeviceSettingsError("Unknown display '\(text)' on \(device)\(reason). Use one of: \(names).")
    }
}

extension Posture {
    /// devicectl's hinge angle: 0 is closed, 180 fully open.
    public init(hingeAngle: Double) {
        switch hingeAngle {
        case ..<15: self = .closed
        case ..<165: self = .halfOpened
        default: self = .open
        }
    }
}

/// Optional capability: the device's displays and which one is active.
@MainActor
public protocol DisplayControlling: DeviceBackend {
    func displays(of id: DeviceID) async throws -> DisplayList
}

/// Optional capability: a foldable's posture.
@MainActor
public protocol PostureControlling: DeviceBackend {
    /// Nil when the device has one display.
    func posture(of id: DeviceID) async throws -> Posture?
    /// Dispatch only; poll `posture(of:)` to see it take effect. Throws an actionable error where the platform cannot fold.
    func requestPosture(_ posture: Posture, on id: DeviceID) async throws
}

/// Optional capability: moving a foldable's hinge to an angle.
@MainActor
public protocol HingeControlling: PostureControlling {
    /// Degrees from 0 (closed) to 180 (open); nil when the device cannot say.
    func hingeAngle(of id: DeviceID) async throws -> Double?
    /// Dispatch only; poll `hingeAngle(of:)` to see it take effect.
    func requestHingeAngle(_ degrees: Int, on id: DeviceID) async throws
}

/// Optional capability: capturing a chosen display.
@MainActor
public protocol DisplayCapturing: DeviceBackend {
    /// `display` is a platform id from `displays(of:)`; nil captures the active display.
    func screenshotPNG(for id: DeviceID, display: String?) async throws -> Data
}
